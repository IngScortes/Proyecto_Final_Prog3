defmodule Sismo.Resources.Center do
  @moduledoc """
  Un proceso por centro de acopio. Su mailbox serializa las operaciones del centro,
  por lo que la cantidad reservada nunca supera el inventario real.
  """
  use GenServer
  require Logger

  alias Sismo.Persistence.{Codec, Writer}
  alias Sismo.Resources.{Ledger, Movement}

  defstruct [:ledger, :path, :writer]

  ## API

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via(id))
  end

  def via(id), do: {:via, Registry, {Sismo.Registry, {:center, id}}}
  def exists?(id), do: Registry.lookup(Sismo.Registry, {:center, id}) != []

  def register_resource(id, code, name, category, unit, qty \\ 0),
    do: call(id, {:register, code, name, category, unit, qty})

  def deposit(id, code, qty, ref \\ nil), do: move(id, :entrada, code, qty, ref)
  def withdraw(id, code, qty, ref \\ nil), do: move(id, :salida, code, qty, ref)
  def reserve(id, code, qty, need_id), do: move(id, :reserva, code, qty, need_id)
  def release(id, code, need_ref), do: call(id, {:release, code, need_ref})

  def move(id, kind, code, qty, ref), do: call(id, {:move, kind, code, qty, ref})

  def get_resource(id, code), do: call(id, {:get_resource, code})
  def snapshot(id), do: call(id, :snapshot)
  def history(id), do: call(id, :history)

  defp call(id, msg) do
    GenServer.call(via(id), msg)
  catch
    :exit, {:noproc, _} -> {:error, :center_not_found}
  end

  ## Callbacks

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    writer = Keyword.get(opts, :writer, Writer)
    path = opts |> Keyword.fetch!(:data_dir) |> Path.join("centers") |> Path.join(id <> ".log")

    with {:ok, movements} <- load(path),
         ledger = Ledger.replay(Ledger.new(id, nil), movements),
         {:ok, ledger} <- ensure_header(ledger, Keyword.get(opts, :zone), path, writer) do
      {:ok, %__MODULE__{ledger: ledger, path: path, writer: writer}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:register, code, name, category, unit, qty}, _from, state) do
    decision = Ledger.register(state.ledger, code, name, category, unit, qty)
    commit(state, decision, fn ledger, mov -> Map.fetch!(ledger.resources, mov.code) end)
  end

  def handle_call({:move, kind, code, qty, ref}, _from, state) do
    decision = Ledger.decide(state.ledger, kind, code, qty, ref)
    commit(state, decision, fn _ledger, mov -> mov end)
  end

    def handle_call({:release, code, ref}, _from, state) do
    case Ledger.release(state.ledger, code, ref) do
      {:ok, mov} -> commit(state, {:ok, mov}, fn _ledger, m -> m end)
      :none -> {:reply, {:ok, :nothing_reserved}, state}
    end
  end

  def handle_call({:get_resource, code}, _from, state) do
    case Map.fetch(state.ledger.resources, code) do
      {:ok, resource} -> {:reply, {:ok, resource}, state}
      :error -> {:reply, {:error, :resource_not_found}, state}
    end
  end

  def handle_call(:snapshot, _from, %{ledger: l} = state) do
    resources = l.resources |> Map.values() |> Enum.sort_by(& &1.code)
    {:reply, %{id: l.id, zone: l.zone, resources: resources}, state}
  end

  def handle_call(:history, _from, state),
    do: {:reply, Enum.reverse(state.ledger.history), state}

  ## Privado

  # Primero disco, después memoria: si la escritura falla, el estado no cambia.
  defp commit(state, {:ok, %Movement{} = mov}, build_reply) do
    case persist(state.path, mov, state.writer) do
      :ok ->
        ledger = Ledger.apply_movement(state.ledger, mov)
        {:reply, {:ok, build_reply.(ledger, mov)}, %{state | ledger: ledger}}

      {:error, reason} ->
        {:reply, {:error, {:persist_failed, reason}}, state}
    end
  end

  defp commit(state, {:noop, reserved}, _build), do: {:reply, {:ok, {:already_reserved, reserved}}, state}
  defp commit(state, {:error, _} = error, _build), do: {:reply, error, state}

  defp persist(path, %Movement{} = mov, writer),
    do: Writer.append_sync(path, Codec.encode_line(Movement.to_fields(mov)), writer)

  defp ensure_header(%Ledger{zone: nil}, nil, _path, _writer), do: {:error, :unknown_zone}

  defp ensure_header(%Ledger{zone: nil} = ledger, zone, path, writer) do
    header = Ledger.header(ledger, zone)

    case persist(path, header, writer) do
      :ok -> {:ok, Ledger.apply_movement(ledger, header)}
      {:error, reason} -> {:error, {:persist_failed, reason}}
    end
  end

  defp ensure_header(ledger, _zone, _path, _writer), do: {:ok, ledger}

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
    case line |> Codec.decode_line() |> Movement.from_fields() do
      {:ok, movement} ->
        [movement]

      {:error, reason} ->
        Logger.warning("Movimiento ignorado (#{inspect(reason)})")
        []
    end
  end
end
