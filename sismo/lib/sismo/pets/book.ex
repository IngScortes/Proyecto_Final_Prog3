defmodule Sismo.Pets.Book do
  @moduledoc """
  Estado de los reportes de mascotas y sus reglas, en funciones puras.
  Las decisiones devuelven `{:ok, evento}` o `{:error, razón}`;
  `apply_event/2` aplica un evento ya validado; `replay/2` reconstruye el estado.
  """
  alias Sismo.Pets.{Report, Similarity}

  defstruct reports: %{}, seq: 0

  @kinds %{
    "perdida" => :perdida, "lost" => :perdida,
    "encontrada" => :encontrada, "found" => :encontrada
  }
  @sizes %{
    "pequeno" => :pequeno, "pequena" => :pequeno,
    "mediano" => :mediano, "mediana" => :mediano,
    "grande" => :grande
  }
  @statuses %{
    "activa" => :activa,
    "posible_coincidencia" => :posible_coincidencia,
    "resuelta" => :resuelta
  }
  @unknown_names ["", "desconocido", "desconocida", "sin_nombre", "?"]

  ## Consultas

  def fetch(%__MODULE__{} = book, id) do
    case Map.fetch(book.reports, canon_id(id)) do
      {:ok, report} -> {:ok, report}
      :error -> {:error, :report_not_found}
    end
  end

  @doc "Filtros: `species`, `zone`, `status` y `kind`. Devuelve `{:ok, lista}`."
  def search(%__MODULE__{} = book, filters) when is_list(filters) do
    with {:ok, predicates} <- build_predicates(filters, []) do
      reports =
        book.reports
        |> Map.values()
        |> Enum.filter(fn report -> Enum.all?(predicates, & &1.(report)) end)
        |> Enum.sort_by(& &1.seq)

      {:ok, reports}
    end
  end

  @doc "Reportes activos (candidatos a coincidencia): `{perdidas, encontradas}`."
  def open_reports(%__MODULE__{} = book) do
    active =
      book.reports
      |> Map.values()
      |> Enum.filter(&(&1.status == :activa))
      |> Enum.sort_by(& &1.seq)

    {Enum.filter(active, &(&1.kind == :perdida)), Enum.filter(active, &(&1.kind == :encontrada))}
  end

  def counts(%__MODULE__{} = book) do
    zero = Map.new(Map.values(@statuses), &{&1, 0})
    Enum.reduce(book.reports, zero, fn {_id, r}, acc -> Map.update!(acc, r.status, &(&1 + 1)) end)
  end

  defp build_predicates([], acc), do: {:ok, acc}

  defp build_predicates([{key, value} | rest], acc) do
    case predicate(key, value) do
      {:ok, fun} -> build_predicates(rest, [fun | acc])
      {:error, _} = error -> error
    end
  end

  defp build_predicates([_bad | _], _acc), do: {:error, :invalid_filters}

  defp predicate(:species, value) do
    with {:ok, species} <- validate_folded(value, :species), do: {:ok, &(&1.species == species)}
  end

  defp predicate(:zone, value) when is_binary(value) do
    zone = value |> String.trim() |> String.downcase()
    {:ok, &(&1.zone == zone)}
  end

  defp predicate(:status, value), do: with({:ok, s} <- parse_status(value), do: {:ok, &(&1.status == s)})
  defp predicate(:kind, value), do: with({:ok, k} <- parse_kind(value), do: {:ok, &(&1.kind == k)})
  defp predicate(key, _value), do: {:error, {:invalid_filter, key}}

  ## Decisiones

  @doc "`attrs`: kind, species, name, color, size, traits (opcional), zone, contact."
  def report(%__MODULE__{} = book, attrs, by, at) when is_map(attrs) do
    with {:ok, kind} <- parse_kind(attrs[:kind]),
         {:ok, species} <- validate_folded(attrs[:species], :species),
         {:ok, name} <- normalize_name(attrs[:name]),
         {:ok, color} <- validate_folded(attrs[:color], :color),
         {:ok, size} <- parse_size(attrs[:size]),
         {:ok, traits} <- normalize_traits(attrs[:traits]),
         {:ok, zone} <- validate_text(attrs[:zone], :zone),
         {:ok, contact} <- validate_text(attrs[:contact], :contact),
         {:ok, by} <- validate_text(by, :reporter) do
      seq = book.seq + 1

      {:ok,
       {:pet_reported, format_id(seq), seq, kind, species, name, color, size, traits,
        String.downcase(zone), contact, by, at}}
    end
  end

  def event_zone(
        {:pet_reported, _id, _seq, _kind, _species, _name, _color, _size, _traits, zone, _contact,
         _by, _at}
      ),
      do: zone

  @doc "Marca ambos reportes como posible coincidencia."
  def propose(%__MODULE__{} = book, a, b, at) do
    with {:ok, lost, found} <- fetch_pair(book, a, b),
         :ok <- ensure_open(lost),
         :ok <- ensure_open(found),
         :ok <- ensure_active(lost),
         :ok <- ensure_active(found) do
      {:ok, {:pet_proposed, lost.id, found.id, at}}
    end
  end

  @doc "Descarta una coincidencia propuesta: ambos vuelven a activa."
  def reject(%__MODULE__{} = book, a, b, at) do
    with {:ok, lost, found} <- fetch_pair(book, a, b),
         :ok <- ensure_open(lost),
         :ok <- ensure_open(found),
         :ok <- ensure_proposed(lost, found.id),
         :ok <- ensure_proposed(found, lost.id) do
      {:ok, {:pet_rejected, lost.id, found.id, at}}
    end
  end

  @doc "Confirma la coincidencia y cierra ambos reportes."
  def confirm(%__MODULE__{} = book, a, b, at) do
    with {:ok, lost, found} <- fetch_pair(book, a, b),
         :ok <- ensure_open(lost),
         :ok <- ensure_open(found),
         :ok <- ensure_pairable(lost, found.id),
         :ok <- ensure_pairable(found, lost.id) do
      {:ok, {:pet_resolved, lost.id, found.id, at}}
    end
  end

  # Acepta los ids en cualquier orden y devuelve {perdida, encontrada}.
  defp fetch_pair(book, a, b) do
    with {:ok, ra} <- fetch(book, a),
         {:ok, rb} <- fetch(book, b) do
      case {ra.kind, rb.kind} do
        {:perdida, :encontrada} -> {:ok, ra, rb}
        {:encontrada, :perdida} -> {:ok, rb, ra}
        _ -> {:error, :invalid_pair}
      end
    end
  end

  defp ensure_open(%Report{status: :resuelta, id: id}), do: {:error, {:already_resolved, id}}
  defp ensure_open(_report), do: :ok

  defp ensure_active(%Report{status: :activa}), do: :ok
  defp ensure_active(%Report{id: id}), do: {:error, {:already_proposed, id}}

  defp ensure_proposed(%Report{status: :posible_coincidencia, matched_with: other}, other), do: :ok
  defp ensure_proposed(_report, _other), do: {:error, :not_proposed}

  defp ensure_pairable(%Report{status: :activa}, _other), do: :ok
  defp ensure_pairable(%Report{status: :posible_coincidencia, matched_with: other}, other), do: :ok
  defp ensure_pairable(%Report{id: id}, _other), do: {:error, {:matched_with_other, id}}

  ## Aplicar eventos (total: un evento inaplicable se ignora)

  def apply_event(
        book,
        {:pet_reported, id, seq, kind, species, name, color, size, traits, zone, contact, by, at}
      ) do
    report = %Report{
      id: id, seq: seq, kind: kind, species: species, name: name, color: color, size: size,
      traits: traits, zone: zone, contact: contact, reporter: by, created_at: at,
      history: [{:activa, at}]
    }

    %{book | reports: Map.put(book.reports, id, report), seq: max(book.seq, seq)}
  end

  def apply_event(book, {:pet_proposed, lost, found, at}) do
    book
    |> set(lost, :posible_coincidencia, found, at)
    |> set(found, :posible_coincidencia, lost, at)
  end

  def apply_event(book, {:pet_rejected, lost, found, at}) do
    book |> set(lost, :activa, nil, at) |> set(found, :activa, nil, at)
  end

  def apply_event(book, {:pet_resolved, lost, found, at}) do
    book |> set(lost, :resuelta, found, at) |> set(found, :resuelta, lost, at)
  end

  def apply_event(book, _unknown), do: book

  defp set(book, id, status, matched_with, at) do
    case Map.fetch(book.reports, id) do
      {:ok, r} ->
        updated = %{r | status: status, matched_with: matched_with, history: [{status, at} | r.history]}
        %{book | reports: Map.put(book.reports, id, updated)}

      :error ->
        book
    end
  end

  @doc "Recursión de cola sobre la lista de eventos."
  def replay(%__MODULE__{} = book, []), do: book
  def replay(%__MODULE__{} = book, [event | rest]), do: replay(apply_event(book, event), rest)

  ## Texto plano

  def to_fields(
        {:pet_reported, id, seq, kind, species, name, color, size, traits, zone, contact, by, at}
      ),
      do: [
        "pet", id, seq, Atom.to_string(kind), species, name || "", color, Atom.to_string(size),
        traits, zone, contact, by, at
      ]

  def to_fields({:pet_proposed, lost, found, at}), do: ["pet_proposed", lost, found, at]
  def to_fields({:pet_rejected, lost, found, at}), do: ["pet_rejected", lost, found, at]
  def to_fields({:pet_resolved, lost, found, at}), do: ["pet_resolved", lost, found, at]

  def from_fields(["pet", id, seq, kind, species, name, color, size, traits, zone, contact, by, at]) do
    with {seq, ""} <- Integer.parse(seq),
         {:ok, kind} <- parse_kind(kind),
         {:ok, size} <- parse_size(size) do
      name = if name == "", do: nil, else: name
      {:ok, {:pet_reported, id, seq, kind, species, name, color, size, traits, zone, contact, by, at}}
    else
      _ -> {:error, :malformed_record}
    end
  end

  def from_fields(["pet_proposed", lost, found, at]), do: {:ok, {:pet_proposed, lost, found, at}}
  def from_fields(["pet_rejected", lost, found, at]), do: {:ok, {:pet_rejected, lost, found, at}}
  def from_fields(["pet_resolved", lost, found, at]), do: {:ok, {:pet_resolved, lost, found, at}}
  def from_fields(_), do: {:error, :malformed_record}

  ## Parseo y validaciones

  def parse_kind(value), do: lookup(@kinds, value, :kind)
  def parse_size(value), do: lookup(@sizes, value, :size)
  def parse_status(value), do: lookup(@statuses, value, :status)

  defp lookup(names, value, field) do
    case Map.fetch(names, token(value)) do
      {:ok, parsed} -> {:ok, parsed}
      :error -> {:error, {:invalid_field, field}}
    end
  end

  defp token(v) when is_binary(v), do: v |> Similarity.fold() |> String.replace(" ", "_")
  defp token(v) when is_atom(v) and not is_nil(v), do: Atom.to_string(v)
  defp token(_), do: nil

  defp canon_id(v) when is_binary(v), do: v |> String.trim() |> String.upcase()
  defp canon_id(_), do: nil

  defp format_id(seq), do: "PT" <> String.pad_leading(Integer.to_string(seq), 3, "0")

  defp validate_folded(value, field) when is_binary(value) do
    case Similarity.fold(value) do
      "" -> {:error, {:invalid_field, field}}
      folded -> {:ok, folded}
    end
  end

  defp validate_folded(_, field), do: {:error, {:invalid_field, field}}

  defp validate_text(value, field) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, {:invalid_field, field}}
      text -> {:ok, text}
    end
  end

  defp validate_text(_, field), do: {:error, {:invalid_field, field}}

  # El nombre es opcional: "desconocido" y vacío se guardan como nil.
  defp normalize_name(nil), do: {:ok, nil}

  defp normalize_name(value) when is_binary(value) do
    if token(value) in @unknown_names, do: {:ok, nil}, else: {:ok, String.trim(value)}
  end

  defp normalize_name(_), do: {:error, {:invalid_field, :name}}

  defp normalize_traits(nil), do: {:ok, ""}
  defp normalize_traits(value) when is_binary(value), do: {:ok, String.trim(value)}
  defp normalize_traits(_), do: {:error, {:invalid_field, :traits}}
end
