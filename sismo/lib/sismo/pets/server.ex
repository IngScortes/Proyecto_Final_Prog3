defmodule Sismo.Pets.Server do
  @moduledoc """
  Dueño del estado de los reportes de mascotas. Cada comando se valida contra el estado
  actual, se escribe en disco y solo entonces se aplica. Como todo pasa por el mailbox,
  proponer o confirmar una coincidencia es atómico: un reporte no se cierra dos veces.
  """
  use GenServer
  require Logger

  alias Sismo.Persistence.{Codec, Writer}
  alias Sismo.Pets.Book
  alias Sismo.Zones.Server, as: Zones

  @pair_ops [:propose, :reject, :confirm]

  defstruct [:path, :writer, :zones, book: %Book{}]

  ## API (el servidor es el último argumento opcional)

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "`attrs`: kind, species, name, color, size, traits (opcional), zone, contact."
  def report(attrs, by, server \\ __MODULE__) when is_map(attrs),
    do: GenServer.call(server, {:report, attrs, by})

  def propose(a, b, server \\ __MODULE__), do: GenServer.call(server, {:pair, :propose, a, b})
  def reject(a, b, server \\ __MODULE__), do: GenServer.call(server, {:pair, :reject, a, b})
  def confirm(a, b, server \\ __MODULE__), do: GenServer.call(server, {:pair, :confirm, a, b})

  def get(id, server \\ __MODULE__), do: GenServer.call(server, {:get, id})
  def list(filters \\ [], server \\ __MODULE__), do: GenServer.call(server, {:list, filters})
  def counts(server \\ __MODULE__), do: GenServer.call(server, :counts)

  @doc "Foto de los reportes activos: `{perdidas, encontradas}`. La usa `Matcher`."
  def open_reports(server \\ __MODULE__), do: GenServer.call(server, :open_reports)

  @doc "Repara asociaciones zona-reporte que hubieran quedado pendientes."
  def reconcile_links(server \\ __MODULE__), do: GenServer.call(server, :reconcile)

  ## Callbacks

  @impl true
  def init(opts) do
    path = opts |> Keyword.fetch!(:data_dir) |> Path.join("pets.log")

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
  def handle_call({:report, attrs, by}, _from, state) do
    with {:ok, event} <- Book.report(state.book, attrs, by, now()),
         :ok <- check_zone(state, Book.event_zone(event)),
         :ok <- persist(state, event) do
      book = Book.apply_event(state.book, event)
      report = Map.fetch!(book.reports, elem(event, 1))
      link_zone(state, report)
      {:reply, {:ok, report}, %{state | book: book}}
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:pair, op, a, b}, _from, state) when op in @pair_ops do
    with {:ok, event} <- apply(Book, op, [state.book, a, b, now()]),
         :ok <- persist(state, event) do
      book = Book.apply_event(state.book, event)
      reply = %{lost: Map.fetch!(book.reports, elem(event, 1)), found: Map.fetch!(book.reports, elem(event, 2))}
      {:reply, {:ok, reply}, %{state | book: book}}
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:get, id}, _from, state), do: {:reply, Book.fetch(state.book, id), state}
  def handle_call({:list, filters}, _from, state), do: {:reply, Book.search(state.book, filters), state}
  def handle_call(:counts, _from, state), do: {:reply, Book.counts(state.book), state}
  def handle_call(:open_reports, _from, state), do: {:reply, Book.open_reports(state.book), state}

  def handle_call(:reconcile, _from, state) do
    state.book.reports |> Map.values() |> Enum.each(&link_zone(state, &1))
    {:reply, :ok, state}
  end

  ## Privado

  defp check_zone(state, zone) do
    if Zones.exists?(zone, state.zones), do: :ok, else: {:error, :zone_not_found}
  catch
    :exit, _ -> {:error, :zones_unavailable}
  end

  # El reporte ya existe; si el enlace falla queda pendiente y `reconcile_links/1` lo repara.
  defp link_zone(state, report) do
    case Zones.link(report.zone, :report, report.id, state.zones) do
      {:ok, _} -> :ok
      {:error, :already_linked} -> :ok
      {:error, reason} -> warn_link(report, reason)
    end
  catch
    :exit, reason -> warn_link(report, reason)
  end

  defp warn_link(report, reason) do
    Logger.warning("No se pudo asociar #{report.id} a la zona #{report.zone}: #{inspect(reason)}")
    :error
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
        Logger.warning("pets.log: línea ignorada (#{inspect(reason)})")
        []
    end
  end
end
