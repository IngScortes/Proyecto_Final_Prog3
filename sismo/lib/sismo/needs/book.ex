defmodule Sismo.Needs.Book do
  @moduledoc """
  Estado de las necesidades y sus reglas, en funciones puras.
  Las decisiones devuelven `{:ok, evento}` o `{:error, razón}`;
  `apply_event/2` aplica un evento ya validado; `replay/2` reconstruye el estado.
  """
  alias Sismo.Needs.Need

  defstruct needs: %{}, seq: 0

  @types ~w(agua alimentos medicamentos primeros_auxilios refugio transporte rescate otra)a
  @type_names Map.new(@types, &{Atom.to_string(&1), &1})

  @priority_names %{
    "critica" => :critica, "crítica" => :critica,
    "alta" => :alta, "media" => :media, "baja" => :baja
  }
  @priority_rank %{critica: 0, alta: 1, media: 2, baja: 3}

  @statuses ~w(pendiente asignada en_atencion atendida cancelada)a
  @status_names @statuses
                |> Map.new(&{Atom.to_string(&1), &1})
                |> Map.put("en_atención", :en_atencion)

  @transitions %{
    pendiente: [:asignada, :cancelada],
    asignada: [:en_atencion, :cancelada],
    en_atencion: [:atendida, :cancelada],
    atendida: [],
    cancelada: []
  }
  # `asignada` solo se alcanza asignando recursos, nunca por transición manual.
  @manual_targets [:en_atencion, :atendida, :cancelada]
  @assignable [:pendiente, :asignada]

  ## Consultas

  def fetch(%__MODULE__{} = book, id) do
    case Map.fetch(book.needs, canon_id(id)) do
      {:ok, need} -> {:ok, need}
      :error -> {:error, :need_not_found}
    end
  end

  @doc "Necesidades que aún requieren atención, la más urgente primero."
  def queue(%__MODULE__{} = book) do
    book.needs
    |> Map.values()
    |> Enum.filter(&(&1.status == :pendiente or (&1.status == :asignada and Need.remaining(&1) > 0)))
    |> sort_queue()
  end

  @doc "Filtros: `zone`, `type`, `priority` y `status`. Devuelve `{:ok, lista}`."
  def query(%__MODULE__{} = book, filters) when is_list(filters) do
    with {:ok, predicates} <- build_predicates(filters, []) do
      needs =
        book.needs
        |> Map.values()
        |> Enum.filter(fn need -> Enum.all?(predicates, & &1.(need)) end)
        |> sort_queue()

      {:ok, needs}
    end
  end

  def counts(%__MODULE__{} = book) do
    zero = Map.new(@statuses, &{&1, 0})
    Enum.reduce(book.needs, zero, fn {_id, need}, acc -> Map.update!(acc, need.status, &(&1 + 1)) end)
  end

  defp sort_queue(needs), do: Enum.sort_by(needs, &{Map.fetch!(@priority_rank, &1.priority), &1.seq})

  defp build_predicates([], acc), do: {:ok, acc}

  defp build_predicates([{key, value} | rest], acc) do
    case predicate(key, value) do
      {:ok, fun} -> build_predicates(rest, [fun | acc])
      {:error, _} = error -> error
    end
  end

  defp build_predicates([_bad | _], _acc), do: {:error, :invalid_filters}

  defp predicate(:zone, value) when is_binary(value) do
    zone = value |> String.trim() |> String.downcase()
    {:ok, &(&1.zone == zone)}
  end

  defp predicate(:type, value), do: with({:ok, t} <- parse_type(value), do: {:ok, &(&1.type == t)})

  defp predicate(:priority, value),
    do: with({:ok, p} <- parse_priority(value), do: {:ok, &(&1.priority == p)})

  defp predicate(:status, value), do: with({:ok, s} <- parse_status(value), do: {:ok, &(&1.status == s)})
  defp predicate(key, _value), do: {:error, {:invalid_filter, key}}

  ## Decisiones

  def create(%__MODULE__{} = book, type, qty, priority, zone, description, reporter, at) do
    with {:ok, type} <- parse_type(type),
         :ok <- validate_positive(qty),
         {:ok, priority} <- parse_priority(priority),
         {:ok, zone} <- validate_text(zone, :zone),
         {:ok, description} <- validate_text(description, :description),
         {:ok, reporter} <- validate_text(reporter, :reporter) do
      seq = book.seq + 1

      {:ok,
       {:need_created, format_id(seq), seq, type, description, qty, String.downcase(zone),
        priority, reporter, at}}
    end
  end

  def event_zone({:need_created, _id, _seq, _type, _desc, _qty, zone, _prio, _rep, _at}), do: zone

  @doc """
  Valida una asignación y calcula su referencia única (`"N001:2"`).
  No modifica nada: el evento se crea después de reservar en el centro.
  """
  def check_assign(%__MODULE__{} = book, id, center, code, qty) do
    with {:ok, need} <- fetch(book, id),
         :ok <- ensure_assignable(need),
         :ok <- validate_positive(qty),
         {:ok, center} <- validate_text(center, :center),
         {:ok, code} <- validate_text(code, :code),
         :ok <- ensure_within(need, qty) do
      {:ok,
       %{
         need: need,
         center: String.downcase(center),
         code: code,
         ref: "#{need.id}:#{length(need.allocations) + 1}"
       }}
    end
  end

  def transition(%__MODULE__{} = book, id, to, at) when to in @manual_targets do
    with {:ok, need} <- fetch(book, id),
         :ok <- check_transition(need.status, to) do
      {:ok, {:status_changed, need.id, to, at}}
    end
  end

  def transition(_book, _id, _to, _at), do: {:error, :invalid_status}

  ## Aplicar eventos (total: un evento inaplicable se ignora)

  def apply_event(book, {:need_created, id, seq, type, desc, qty, zone, priority, reporter, at}) do
    need = %Need{
      id: id, seq: seq, type: type, description: desc, quantity: qty, zone: zone,
      priority: priority, reporter: reporter, created_at: at, history: [{:pendiente, at}]
    }

    %{book | needs: Map.put(book.needs, id, need), seq: max(book.seq, seq)}
  end

  def apply_event(book, {:assigned, id, center, code, qty, ref, at}) do
    update_need(book, id, fn need ->
      allocation = %{center: center, code: code, quantity: qty, ref: ref}
      status = if need.status == :pendiente, do: :asignada, else: need.status
      history = if status == need.status, do: need.history, else: [{status, at} | need.history]
      %{need | allocations: need.allocations ++ [allocation], status: status, history: history}
    end)
  end

  def apply_event(book, {:status_changed, id, status, at}),
    do: update_need(book, id, &%{&1 | status: status, history: [{status, at} | &1.history]})

  def apply_event(book, _unknown), do: book

  @doc "Recursión de cola sobre la lista de eventos."
  def replay(%__MODULE__{} = book, []), do: book
  def replay(%__MODULE__{} = book, [event | rest]), do: replay(apply_event(book, event), rest)

  ## Texto plano

  def to_fields({:need_created, id, seq, type, desc, qty, zone, priority, reporter, at}),
    do: ["need", id, seq, Atom.to_string(type), desc, qty, zone, Atom.to_string(priority), reporter, at]

  def to_fields({:assigned, id, center, code, qty, ref, at}),
    do: ["assign", id, center, code, qty, ref, at]

  def to_fields({:status_changed, id, status, at}),
    do: ["status", id, Atom.to_string(status), at]

  def from_fields(["need", id, seq, type, desc, qty, zone, priority, reporter, at]) do
    with {seq, ""} <- Integer.parse(seq),
         {qty, ""} <- Integer.parse(qty),
         {:ok, type} <- parse_type(type),
         {:ok, priority} <- parse_priority(priority) do
      {:ok, {:need_created, id, seq, type, desc, qty, zone, priority, reporter, at}}
    else
      _ -> {:error, :malformed_record}
    end
  end

  def from_fields(["assign", id, center, code, qty, ref, at]) do
    case Integer.parse(qty) do
      {qty, ""} -> {:ok, {:assigned, id, center, code, qty, ref, at}}
      _ -> {:error, :malformed_record}
    end
  end

  def from_fields(["status", id, status, at]) do
    case parse_status(status) do
      {:ok, status} -> {:ok, {:status_changed, id, status, at}}
      _ -> {:error, :malformed_record}
    end
  end

  def from_fields(_), do: {:error, :malformed_record}

  ## Parseo y validaciones

  def parse_type(value), do: lookup(@type_names, value, :type)
  def parse_priority(value), do: lookup(@priority_names, value, :priority)
  def parse_status(value), do: lookup(@status_names, value, :status)

  defp lookup(names, value, field) do
    case Map.fetch(names, token(value)) do
      {:ok, parsed} -> {:ok, parsed}
      :error -> {:error, {:invalid_field, field}}
    end
  end

  defp token(v) when is_binary(v), do: v |> String.trim() |> String.downcase() |> String.replace(" ", "_")
  defp token(v) when is_atom(v) and not is_nil(v), do: Atom.to_string(v)
  defp token(_), do: nil

  defp canon_id(v) when is_binary(v), do: v |> String.trim() |> String.upcase()
  defp canon_id(_), do: nil

  defp format_id(seq), do: "N" <> String.pad_leading(Integer.to_string(seq), 3, "0")

  defp validate_text(value, field) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, {:invalid_field, field}}
      text -> {:ok, text}
    end
  end

  defp validate_text(_, field), do: {:error, {:invalid_field, field}}

  defp validate_positive(q) when is_integer(q) and q > 0, do: :ok
  defp validate_positive(_), do: {:error, :invalid_quantity}

  defp ensure_assignable(%Need{status: status}) when status in @assignable, do: :ok
  defp ensure_assignable(%Need{status: status}), do: {:error, {:not_assignable, status}}

  defp ensure_within(need, qty) do
    remaining = Need.remaining(need)
    if qty <= remaining, do: :ok, else: {:error, {:exceeds_remaining, remaining}}
  end

  defp check_transition(from, to) do
    if to in Map.fetch!(@transitions, from), do: :ok, else: {:error, {:invalid_transition, from, to}}
  end

  defp update_need(book, id, fun) do
    case Map.fetch(book.needs, id) do
      {:ok, need} -> %{book | needs: Map.put(book.needs, id, fun.(need))}
      :error -> book
    end
  end
end
