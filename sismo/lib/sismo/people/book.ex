defmodule Sismo.People.Book do
  @moduledoc """
  Estado de personas y mensajes familiares, en funciones puras.
  Las decisiones devuelven `{:ok, evento}` o `{:error, razón}`;
  `apply_event/2` aplica un evento ya validado; `replay/2` reconstruye el estado.
  """
  alias Sismo.People.{FamilyMessage, Person}

  defstruct persons: %{}, messages: %{}, seq: 0, mseq: 0

  @statuses ~w(sin_informacion reportada localizada trasladada en_albergue reunificada)a
  @status_names @statuses
                |> Map.new(&{Atom.to_string(&1), &1})
                |> Map.put("sin_información", :sin_informacion)

  @transitions %{
    sin_informacion: [:reportada, :localizada, :trasladada, :en_albergue, :reunificada],
    reportada: [:localizada, :trasladada, :en_albergue, :reunificada],
    localizada: [:trasladada, :en_albergue, :reunificada],
    trasladada: [:localizada, :en_albergue, :reunificada],
    en_albergue: [:localizada, :trasladada, :reunificada],
    reunificada: []
  }

  @message_statuses %{"pendiente" => :pendiente, "entregado" => :entregado}
  @max_document 40
  @max_content 500

  ## Consultas

  def fetch_person(%__MODULE__{} = book, document) do
    case Map.fetch(book.persons, canon(document)) do
      {:ok, person} -> {:ok, person}
      :error -> {:error, :person_not_found}
    end
  end

  def fetch_message(%__MODULE__{} = book, id) do
    case Map.fetch(book.messages, canon_id(id)) do
      {:ok, message} -> {:ok, message}
      :error -> {:error, :message_not_found}
    end
  end

  @doc "Filtros: `name` (subcadena, sin tildes ni mayúsculas), `document`, `zone` y `status`."
  def search(%__MODULE__{} = book, filters) when is_list(filters) do
    with {:ok, predicates} <- build_predicates(filters, []) do
      people =
        book.persons
        |> Map.values()
        |> Enum.filter(fn person -> Enum.all?(predicates, & &1.(person)) end)
        |> Enum.sort_by(& &1.seq)

      {:ok, people}
    end
  end

  @doc "Historial de estados en orden cronológico."
  def history(%__MODULE__{} = book, document) do
    with {:ok, person} <- fetch_person(book, document), do: {:ok, Enum.reverse(person.history)}
  end

  def messages_for(%__MODULE__{} = book, document) do
    doc = canon(document)

    book.messages
    |> Map.values()
    |> Enum.filter(&(&1.to_document == doc))
    |> Enum.sort_by(& &1.seq)
  end

  def counts(%__MODULE__{} = book) do
    zero = Map.new(@statuses, &{&1, 0})
    Enum.reduce(book.persons, zero, fn {_doc, p}, acc -> Map.update!(acc, p.status, &(&1 + 1)) end)
  end

  defp build_predicates([], acc), do: {:ok, acc}

  defp build_predicates([{key, value} | rest], acc) do
    case predicate(key, value) do
      {:ok, fun} -> build_predicates(rest, [fun | acc])
      {:error, _} = error -> error
    end
  end

  defp build_predicates([_bad | _], _acc), do: {:error, :invalid_filters}

  defp predicate(:name, value) when is_binary(value) do
    case fold(value) do
      "" -> {:error, {:invalid_field, :name}}
      needle -> {:ok, &String.contains?(fold(&1.name), needle)}
    end
  end

  defp predicate(:document, value) when is_binary(value) do
    doc = String.trim(value)
    {:ok, &(&1.document == doc)}
  end

  defp predicate(:zone, value) when is_binary(value) do
    zone = value |> String.trim() |> String.downcase()
    {:ok, &(&1.zone == zone)}
  end

  defp predicate(:status, value) do
    with {:ok, status} <- parse_status(value), do: {:ok, &(&1.status == status)}
  end

  defp predicate(key, _value), do: {:error, {:invalid_filter, key}}

  ## Decisiones

  def report(%__MODULE__{} = book, document, name, age, zone, status, by, at) do
    with {:ok, doc} <- validate_document(document),
         {:ok, name} <- validate_text(name, :name),
         {:ok, age} <- validate_age(age),
         {:ok, zone} <- validate_text(zone, :zone),
         {:ok, status} <- parse_status(status),
         {:ok, by} <- validate_text(by, :reporter),
         :ok <- ensure_absent(book, doc) do
      seq = book.seq + 1

      {:ok,
       {:person_reported, format_id("P", seq), seq, doc, name, age, String.downcase(zone), status,
        by, at}}
    end
  end

  def event_zone({:person_reported, _id, _seq, _doc, _name, _age, zone, _status, _by, _at}), do: zone

  def change_status(%__MODULE__{} = book, document, to, by, at) do
    with {:ok, person} <- fetch_person(book, document),
         {:ok, to} <- parse_status(to),
         {:ok, by} <- validate_text(by, :actor),
         :ok <- check_transition(person.status, to) do
      {:ok, {:status_changed, person.document, to, by, at}}
    end
  end

  def send_message(%__MODULE__{} = book, from, to_document, content, at) do
    with {:ok, from} <- validate_text(from, :sender),
         {:ok, to} <- validate_document(to_document),
         {:ok, content} <- validate_content(content) do
      seq = book.mseq + 1
      {:ok, {:message_sent, format_id("M", seq), seq, from, to, content, at}}
    end
  end

  def set_message_status(%__MODULE__{} = book, id, status, at) do
    with {:ok, message} <- fetch_message(book, id),
         {:ok, status} <- parse_message_status(status),
         :ok <- ensure_different(message, status) do
      {:ok, {:message_status, message.id, status, at}}
    end
  end

  ## Aplicar eventos (total: un evento inaplicable se ignora)

  def apply_event(book, {:person_reported, id, seq, doc, name, age, zone, status, by, at}) do
    person = %Person{
      id: id, seq: seq, document: doc, name: name, age: age, zone: zone, status: status,
      reporter: by, created_at: at, history: [{status, at, by}]
    }

    %{book | persons: Map.put(book.persons, doc, person), seq: max(book.seq, seq)}
  end

  def apply_event(book, {:status_changed, doc, status, by, at}) do
    update(book, :persons, doc, &%{&1 | status: status, history: [{status, at, by} | &1.history]})
  end

  def apply_event(book, {:message_sent, id, seq, from, to, content, at}) do
    message = %FamilyMessage{id: id, seq: seq, from: from, to_document: to, content: content, at: at}
    %{book | messages: Map.put(book.messages, id, message), mseq: max(book.mseq, seq)}
  end

  def apply_event(book, {:message_status, id, status, _at}),
    do: update(book, :messages, id, &%{&1 | status: status})

  def apply_event(book, _unknown), do: book

  @doc "Recursión de cola sobre la lista de eventos."
  def replay(%__MODULE__{} = book, []), do: book
  def replay(%__MODULE__{} = book, [event | rest]), do: replay(apply_event(book, event), rest)

  ## Texto plano

  def to_fields({:person_reported, id, seq, doc, name, age, zone, status, by, at}),
    do: ["person", id, seq, doc, name, age || "", zone, Atom.to_string(status), by, at]

  def to_fields({:status_changed, doc, status, by, at}),
    do: ["status", doc, Atom.to_string(status), by, at]

  def to_fields({:message_sent, id, seq, from, to, content, at}),
    do: ["message", id, seq, from, to, content, at]

  def to_fields({:message_status, id, status, at}),
    do: ["message_status", id, Atom.to_string(status), at]

  def from_fields(["person", id, seq, doc, name, age, zone, status, by, at]) do
    with {seq, ""} <- Integer.parse(seq),
         {:ok, age} <- parse_stored_age(age),
         {:ok, status} <- parse_status(status) do
      {:ok, {:person_reported, id, seq, doc, name, age, zone, status, by, at}}
    else
      _ -> {:error, :malformed_record}
    end
  end

  def from_fields(["status", doc, status, by, at]) do
    case parse_status(status) do
      {:ok, status} -> {:ok, {:status_changed, doc, status, by, at}}
      _ -> {:error, :malformed_record}
    end
  end

  def from_fields(["message", id, seq, from, to, content, at]) do
    case Integer.parse(seq) do
      {seq, ""} -> {:ok, {:message_sent, id, seq, from, to, content, at}}
      _ -> {:error, :malformed_record}
    end
  end

  def from_fields(["message_status", id, status, at]) do
    case parse_message_status(status) do
      {:ok, status} -> {:ok, {:message_status, id, status, at}}
      _ -> {:error, :malformed_record}
    end
  end

  def from_fields(_), do: {:error, :malformed_record}

  defp parse_stored_age(""), do: {:ok, nil}

  defp parse_stored_age(age) do
    case Integer.parse(age) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  ## Parseo y validaciones

  def parse_status(value) do
    case Map.fetch(@status_names, token(value)) do
      {:ok, status} -> {:ok, status}
      :error -> {:error, {:invalid_field, :status}}
    end
  end

  def parse_message_status(value) do
    case Map.fetch(@message_statuses, token(value)) do
      {:ok, status} -> {:ok, status}
      :error -> {:error, {:invalid_field, :message_status}}
    end
  end

  defp token(v) when is_binary(v), do: v |> String.trim() |> String.downcase() |> String.replace(" ", "_")
  defp token(v) when is_atom(v) and not is_nil(v), do: Atom.to_string(v)
  defp token(_), do: nil

  defp canon(v) when is_binary(v), do: String.trim(v)
  defp canon(_), do: nil

  defp canon_id(v) when is_binary(v), do: v |> String.trim() |> String.upcase()
  defp canon_id(_), do: nil

  # Sin mayúsculas ni tildes: "Andrés" -> "andres".
  defp fold(text) do
    text
    |> String.downcase()
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.trim()
  end

  defp format_id(prefix, seq), do: prefix <> String.pad_leading(Integer.to_string(seq), 3, "0")

  defp validate_document(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, {:invalid_field, :document}}
      doc when byte_size(doc) > @max_document -> {:error, {:invalid_field, :document}}
      doc -> {:ok, doc}
    end
  end

  defp validate_document(_), do: {:error, {:invalid_field, :document}}

  defp validate_text(value, field) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, {:invalid_field, field}}
      text -> {:ok, text}
    end
  end

  defp validate_text(_, field), do: {:error, {:invalid_field, field}}

  defp validate_content(value) do
    with {:ok, text} <- validate_text(value, :content) do
      if String.length(text) <= @max_content, do: {:ok, text}, else: {:error, {:invalid_field, :content}}
    end
  end

  defp validate_age(nil), do: {:ok, nil}
  defp validate_age(age) when is_integer(age) and age >= 0 and age <= 120, do: {:ok, age}
  defp validate_age(_), do: {:error, :invalid_age}

  defp ensure_absent(book, doc),
    do: if(Map.has_key?(book.persons, doc), do: {:error, :duplicate_document}, else: :ok)

  defp check_transition(from, to) do
    if to in Map.fetch!(@transitions, from), do: :ok, else: {:error, {:invalid_transition, from, to}}
  end

  defp ensure_different(%FamilyMessage{status: status}, status), do: {:error, {:already, status}}
  defp ensure_different(_message, _status), do: :ok

  defp update(book, field, key, fun) do
    items = Map.fetch!(book, field)

    case Map.fetch(items, key) do
      {:ok, item} -> Map.put(book, field, Map.put(items, key, fun.(item)))
      :error -> book
    end
  end
end
