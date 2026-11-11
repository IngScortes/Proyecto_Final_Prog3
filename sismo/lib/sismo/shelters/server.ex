defmodule Sismo.Shelters.Server do
  @moduledoc """
  Un proceso por albergue. Su mailbox serializa los ingresos y salidas, por lo que
  la ocupación nunca supera la capacidad. Primero disco, después memoria.
  """
  use GenServer
  require Logger

  alias Sismo.Persistence.{Codec, Writer}
  alias Sismo.Shelters.Shelter

  defstruct [:shelter, :path, :writer]

  ## API

  def start_link(opts) do
    opts = Keyword.update!(opts, :code, &canon/1)
    GenServer.start_link(__MODULE__, opts, name: via(Keyword.fetch!(opts, :code)))
  end

  def via(code), do: {:via, Registry, {Sismo.Registry, {:shelter, code}}}
  def exists?(code), do: Registry.lookup(Sismo.Registry, {:shelter, canon(code)}) != []

  def enter(code, document), do: call(code, {:enter, document})
  def leave(code, document), do: call(code, {:leave, document})
  def link(code, kind, ref), do: call(code, {:link, kind, ref})
  def info(code), do: call(code, :info)
  def occupants(code), do: call(code, :occupants)

  defp call(code, msg) do
    GenServer.call(via(canon(code)), msg)
  catch
    :exit, {:noproc, _} -> {:error, :shelter_not_found}
  end

  defp canon(code) when is_binary(code), do: code |> String.trim() |> String.downcase()
  defp canon(_), do: nil

  ## Callbacks

  @impl true
  def init(opts) do
    code = Keyword.fetch!(opts, :code)
    writer = Keyword.get(opts, :writer, Writer)
    path = opts |> Keyword.fetch!(:data_dir) |> Path.join("shelters") |> Path.join(code <> ".log")

    with {:ok, events} <- load(path),
         shelter = Shelter.replay(nil, events),
         {:ok, shelter} <- ensure_created(shelter, opts, path, writer) do
      {:ok, %__MODULE__{shelter: shelter, path: path, writer: writer}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:enter, document}, _from, state),
    do: transact(state, Shelter.enter(state.shelter, document, now()))

  def handle_call({:leave, document}, _from, state),
    do: transact(state, Shelter.leave(state.shelter, document, now()))

  def handle_call({:link, kind, ref}, _from, state),
    do: transact(state, Shelter.link(state.shelter, kind, ref))

  def handle_call(:info, _from, state),
    do: {:reply, {:ok, Shelter.summary(state.shelter)}, state}

  def handle_call(:occupants, _from, state),
    do: {:reply, {:ok, Enum.sort(state.shelter.occupants)}, state}

  ## Privado

  # Primero disco, después memoria: si la escritura falla, el estado no cambia.
  defp transact(state, {:ok, event}) do
    case persist(state.path, event, state.writer) do
      :ok ->
        shelter = Shelter.apply_event(state.shelter, event)
        {:reply, {:ok, Shelter.summary(shelter)}, %{state | shelter: shelter}}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  defp transact(state, {:error, _} = error), do: {:reply, error, state}

  # Si el archivo ya tiene el encabezado, manda el archivo (no se pisan nombre ni capacidad).
  defp ensure_created(%Shelter{} = shelter, _opts, _path, _writer), do: {:ok, shelter}

  defp ensure_created(nil, opts, path, writer) do
    with {:ok, event} <-
           Shelter.create(opts[:code], opts[:name], opts[:zone], opts[:capacity], now()),
         :ok <- persist(path, event, writer) do
      {:ok, Shelter.apply_event(nil, event)}
    end
  end

  defp persist(path, event, writer) do
    line = event |> Shelter.to_fields() |> Codec.encode_line()

    case Writer.append_sync(path, line, writer) do
      :ok -> :ok
      {:error, reason} -> {:error, {:persist_failed, reason}}
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp load(path) do
    case File.read(path) do
      {:ok, content} ->
        {:ok, content |> String.split("\n", trim: true) |> Enum.flat_map(&parse_line/1)}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        Logger.error("No se pudo leer #{path}: #{inspect(reason)}")
        {:error, {:read_failed, reason}}
    end
  end

  defp parse_line(line) do
    case line |> Codec.decode_line() |> Shelter.from_fields() do
      {:ok, event} ->
        [event]

      {:error, reason} ->
        Logger.warning("Evento de albergue ignorado (#{inspect(reason)})")
        []
    end
  end
end
