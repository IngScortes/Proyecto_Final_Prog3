defmodule Sismo.People.Server do
  @moduledoc """
  Dueño del estado de personas y mensajes. Cada comando se valida contra el estado
  actual, se escribe en disco y solo entonces se aplica. Como todo pasa por el mailbox,
  "registrar si no existe" y "cambiar de estado una sola vez" son atómicos.

  Paso de mensajes: `watch/3` suscribe un proceso a un documento y recibe
  `{:family_message, mensaje}` cuando llega un mensaje para ese documento.
  """
  use GenServer
  require Logger

  alias Sismo.People.Book
  alias Sismo.Persistence.{Codec, Writer}
  alias Sismo.Zones.Server, as: Zones

  # subscribers: %{documento => %{pid => monitor_ref}}
  defstruct [:path, :writer, :zones, book: %Book{}, subscribers: %{}]

  ## API (el servidor es el último argumento opcional)

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def report(document, name, age, zone, status, by, server \\ __MODULE__),
    do: GenServer.call(server, {:report, document, name, age, zone, status, by})

  def set_status(document, status, by, server \\ __MODULE__),
    do: GenServer.call(server, {:set_status, document, status, by})

  def get(document, server \\ __MODULE__), do: GenServer.call(server, {:get, document})
  def search(filters \\ [], server \\ __MODULE__), do: GenServer.call(server, {:search, filters})
  def history(document, server \\ __MODULE__), do: GenServer.call(server, {:history, document})
  def counts(server \\ __MODULE__), do: GenServer.call(server, :counts)
  def message_counts(server \\ __MODULE__), do: GenServer.call(server, :message_counts)

  def send_message(from, to_document, content, server \\ __MODULE__),
    do: GenServer.call(server, {:send_message, from, to_document, content})

  def messages_for(document, server \\ __MODULE__), do: GenServer.call(server, {:messages_for, document})
  def mark_delivered(id, server \\ __MODULE__), do: GenServer.call(server, {:mark, id, :entregado})
  def mark_pending(id, server \\ __MODULE__), do: GenServer.call(server, {:mark, id, :pendiente})

  @doc "Suscribe `pid` a los mensajes nuevos para `document`."
  def watch(document, pid \\ self(), server \\ __MODULE__) when is_pid(pid),
    do: GenServer.call(server, {:watch, document, pid})

  ## Callbacks

  @impl true
  def init(opts) do
    path = opts |> Keyword.fetch!(:data_dir) |> Path.join("people.log")

    case load(path) do
      {:ok, book} ->
        {:ok,
         %__MODULE__{
           path: path,
           book: book,
           writer: Keyword.get(opts, :writer, Writer),
           zones: Keyword.get(opts, :zones, Zones)
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:report, document, name, age, zone, status, by}, _from, state) do
    with {:ok, event} <- Book.report(state.book, document, name, age, zone, status, by, now()),
         :ok <- check_zone(state, Book.event_zone(event)) do
      commit(state, {:ok, event}, fn book, {:person_reported, _, _, doc, _, _, _, _, _, _} ->
        Map.fetch!(book.persons, doc)
      end)
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:set_status, document, status, by}, _from, state) do
    decision = Book.change_status(state.book, document, status, by, now())

    commit(state, decision, fn book, {:status_changed, doc, _, _, _} ->
      Map.fetch!(book.persons, doc)
    end)
  end

  def handle_call({:send_message, from, to, content}, _from, state) do
    decision = Book.send_message(state.book, from, to, content, now())

    commit(state, decision, fn book, {:message_sent, id, _, _, _, _, _} ->
      Map.fetch!(book.messages, id)
    end)
  end

  def handle_call({:mark, id, status}, _from, state) do
    decision = Book.set_message_status(state.book, id, status, now())

    commit(state, decision, fn book, {:message_status, id, _, _} ->
      Map.fetch!(book.messages, id)
    end)
  end

  def handle_call({:get, document}, _from, state),
    do: {:reply, Book.fetch_person(state.book, document), state}

  def handle_call({:search, filters}, _from, state),
    do: {:reply, Book.search(state.book, filters), state}

  def handle_call({:history, document}, _from, state),
    do: {:reply, Book.history(state.book, document), state}

  def handle_call({:messages_for, document}, _from, state),
    do: {:reply, Book.messages_for(state.book, document), state}

  def handle_call(:counts, _from, state), do: {:reply, Book.counts(state.book), state}
  
  def handle_call(:message_counts, _from, state), do: {:reply, Book.message_counts(state.book), state}

  def handle_call({:watch, document, pid}, _from, state) do
    case String.trim(to_string(document)) do
      "" ->
        {:reply, {:error, {:invalid_field, :document}}, state}

      doc ->
        subs = Map.get(state.subscribers, doc, %{})

        if Map.has_key?(subs, pid) do
          {:reply, :ok, state}
        else
          subs = Map.put(subs, pid, Process.monitor(pid))
          {:reply, :ok, %{state | subscribers: Map.put(state.subscribers, doc, subs)}}
        end
    end
  end

  # Si un suscriptor muere, se limpian sus suscripciones.
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    subscribers =
      state.subscribers
      |> Enum.map(fn {doc, subs} -> {doc, Map.reject(subs, fn {_pid, r} -> r == ref end)} end)
      |> Enum.reject(fn {_doc, subs} -> map_size(subs) == 0 end)
      |> Map.new()

    {:noreply, %{state | subscribers: subscribers}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## Privado

  # Primero disco, después memoria: si la escritura falla, el estado no cambia.
  defp commit(state, {:ok, event}, build_reply) do
    case persist(state, event) do
      :ok ->
        book = Book.apply_event(state.book, event)
        notify(state, event, book)
        {:reply, {:ok, build_reply.(book, event)}, %{state | book: book}}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  defp commit(state, {:error, _} = error, _build), do: {:reply, error, state}

  defp notify(state, {:message_sent, id, _seq, _from, to, _content, _at}, book) do
    message = Map.fetch!(book.messages, id)

    state.subscribers
    |> Map.get(to, %{})
    |> Enum.each(fn {pid, _ref} -> send(pid, {:family_message, message}) end)
  end

  defp notify(_state, _event, _book), do: :ok

  defp check_zone(state, zone) do
    if Zones.exists?(zone, state.zones), do: :ok, else: {:error, :zone_not_found}
  catch
    :exit, _ -> {:error, :zones_unavailable}
  end

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp persist(state, event) do
    line = event |> Book.to_fields() |> Codec.encode_line()

    case Writer.append_sync(state.path, line, state.writer) do
      :ok -> :ok
      {:error, reason} -> {:error, {:persist_failed, reason}}
    end
  end

  defp load(path) do
    case File.read(path) do
      {:ok, content} ->
        events = content |> String.split("\n", trim: true) |> Enum.flat_map(&parse_line/1)
        {:ok, Book.replay(%Book{}, events)}

      {:error, :enoent} ->
        {:ok, %Book{}}

      {:error, reason} ->
        Logger.error("No se pudo leer #{path}: #{inspect(reason)}")
        {:error, {:read_failed, reason}}
    end
  end

  defp parse_line(line) do
    case line |> Codec.decode_line() |> Book.from_fields() do
      {:ok, event} ->
        [event]

      {:error, reason} ->
        Logger.warning("people.log: línea ignorada (#{inspect(reason)})")
        []
    end
  end
end
