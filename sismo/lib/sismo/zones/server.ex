defmodule Sismo.Zones.Server do
  @moduledoc """
  Dueño del estado de las zonas. Cada comando se valida contra el estado actual,
  se escribe en disco y solo entonces se aplica en memoria. Como todo pasa por
  el mailbox, "crear si no existe" y "id único" son atómicos.
  """
  use GenServer
  require Logger

  alias Sismo.Persistence.{Codec, Writer}
  alias Sismo.Zones.{Book, Tree}

  @commands ~w(create_zone add_sector add_point set_level set_affected link)a

  defstruct [:path, :writer, book: %Book{}]

  ## API (el servidor es el último argumento opcional)

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def create_zone(code, name, level, affected \\ 0, server \\ __MODULE__),
    do: run(server, :create_zone, [code, name, level, affected])

  def add_sector(zone, parent, id, name, affected \\ 0, server \\ __MODULE__),
    do: run(server, :add_sector, [zone, parent, id, name, affected])

  def add_point(zone, sector_id, id, name, kind, server \\ __MODULE__),
    do: run(server, :add_point, [zone, sector_id, id, name, kind])

  def set_level(zone, level, server \\ __MODULE__), do: run(server, :set_level, [zone, level])

  def set_affected(zone, n, server \\ __MODULE__), do: run(server, :set_affected, [zone, n])

  def link(zone, kind, ref, server \\ __MODULE__), do: run(server, :link, [zone, kind, ref])

  def get(code, server \\ __MODULE__), do: GenServer.call(server, {:get, code})
  def exists?(code, server \\ __MODULE__), do: match?({:ok, _}, get(code, server))
  def list(server \\ __MODULE__), do: GenServer.call(server, :list)
  def stats(code, server \\ __MODULE__), do: GenServer.call(server, {:stats, code})

  @doc "Estadísticas de todas las zonas, las más críticas primero."
  def overview(server \\ __MODULE__), do: GenServer.call(server, :overview)

  defp run(server, name, args), do: GenServer.call(server, {:cmd, name, args})

  ## Callbacks

  @impl true
  def init(opts) do
    path = opts |> Keyword.fetch!(:data_dir) |> Path.join("zones.log")

    case load(path) do
      {:ok, book} ->
        {:ok, %__MODULE__{path: path, writer: Keyword.get(opts, :writer, Writer), book: book}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:cmd, name, args}, _from, state) when name in @commands do
    with {:ok, event} <- apply(Book, name, [state.book | args]),
         :ok <- persist(state, event) do
      book = Book.apply_event(state.book, event)
      {:reply, {:ok, Map.fetch!(book.zones, elem(event, 1))}, %{state | book: book}}
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:get, code}, _from, state),
    do: {:reply, Book.fetch_zone(state.book, code), state}

  def handle_call(:list, _from, state),
    do: {:reply, state.book.zones |> Map.values() |> Enum.sort_by(& &1.code), state}

  def handle_call({:stats, code}, _from, state) do
    reply =
      with {:ok, zone} <- Book.fetch_zone(state.book, code), do: {:ok, Tree.zone_stats(zone)}

    {:reply, reply, state}
  end

  def handle_call(:overview, _from, state) do
    overview =
      state.book.zones
      |> Map.values()
      |> Enum.map(&Tree.zone_stats/1)
      |> Enum.sort_by(&{Book.level_rank(&1.level), -&1.total_affected, &1.code})

    {:reply, overview, state}
  end

  ## Privado

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
        Logger.warning("zones.log: línea ignorada (#{inspect(reason)})")
        []
    end
  end
end
