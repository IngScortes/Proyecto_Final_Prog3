defmodule Sismo.Needs.Server do
  @moduledoc """
  Dueño del estado de las necesidades. Cada comando se valida contra el estado actual,
  actúa sobre los centros si hace falta, se escribe en disco y solo entonces se aplica.
  Como todo pasa por el mailbox, las asignaciones sobre una misma necesidad se serializan.
  """
  use GenServer
  require Logger

  alias Sismo.Needs.Book
  alias Sismo.Persistence.{Codec, Writer}
  alias Sismo.Resources.{Center, Movement}
  alias Sismo.Zones.Server, as: Zones

  defstruct [:path, :writer, :zones, book: %Book{}]

  ## API (el servidor es el último argumento opcional)

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def register(type, qty, priority, zone, description, reporter, server \\ __MODULE__),
    do: GenServer.call(server, {:register, type, qty, priority, zone, description, reporter})

  @doc "Reserva `qty` del recurso `code` del centro `center` para la necesidad."
  def assign(id, center, code, qty, server \\ __MODULE__),
    do: GenServer.call(server, {:assign, id, center, code, qty})

  def start_attention(id, server \\ __MODULE__), do: GenServer.call(server, {:transition, id, :en_atencion})
  def complete(id, server \\ __MODULE__), do: GenServer.call(server, {:transition, id, :atendida})
  def cancel(id, server \\ __MODULE__), do: GenServer.call(server, {:transition, id, :cancelada})

  def get(id, server \\ __MODULE__), do: GenServer.call(server, {:get, id})
  def list(filters \\ [], server \\ __MODULE__), do: GenServer.call(server, {:list, filters})
  def queue(server \\ __MODULE__), do: GenServer.call(server, :queue)
  def counts(server \\ __MODULE__), do: GenServer.call(server, :counts)

  @doc "Repara asociaciones zona-necesidad que hubieran quedado pendientes."
  def reconcile_links(server \\ __MODULE__), do: GenServer.call(server, :reconcile)

  ## Callbacks

  @impl true
  def init(opts) do
    path = opts |> Keyword.fetch!(:data_dir) |> Path.join("needs.log")

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
  def handle_call({:register, type, qty, priority, zone, description, reporter}, _from, state) do
    with {:ok, event} <-
           Book.create(state.book, type, qty, priority, zone, description, reporter, now()),
         :ok <- check_zone(state, Book.event_zone(event)),
         :ok <- persist(state, event) do
      {book, need} = apply_and_fetch(state.book, event)
      link_zone(state, need)
      {:reply, {:ok, need}, %{state | book: book}}
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:assign, id, center, code, qty}, _from, state) do
    with {:ok, plan} <- Book.check_assign(state.book, id, center, code, qty),
         :ok <- reserve(plan, qty),
         event = {:assigned, plan.need.id, plan.center, plan.code, qty, plan.ref, now()},
         :ok <- persist(state, event) do
      {book, need} = apply_and_fetch(state.book, event)
      {:reply, {:ok, need}, %{state | book: book}}
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:transition, id, to}, _from, state) do
    with {:ok, event} <- Book.transition(state.book, id, to, now()),
         {:ok, need} <- Book.fetch(state.book, id),
         :ok <- side_effects(to, need),
         :ok <- persist(state, event) do
      {book, need} = apply_and_fetch(state.book, event)
      {:reply, {:ok, need}, %{state | book: book}}
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:get, id}, _from, state), do: {:reply, Book.fetch(state.book, id), state}
  def handle_call({:list, filters}, _from, state), do: {:reply, Book.query(state.book, filters), state}
  def handle_call(:queue, _from, state), do: {:reply, Book.queue(state.book), state}
  def handle_call(:counts, _from, state), do: {:reply, Book.counts(state.book), state}

  def handle_call(:reconcile, _from, state) do
    state.book.needs |> Map.values() |> Enum.each(&link_zone(state, &1))
    {:reply, :ok, state}
  end

  ## Efectos sobre otros procesos

  defp reserve(%{center: center, code: code, ref: ref}, qty) do
    case Center.reserve(center, code, qty, ref) do
      {:ok, %Movement{}} -> :ok
      {:ok, {:already_reserved, ^qty}} -> :ok
      {:ok, {:already_reserved, other}} -> {:error, {:reservation_mismatch, other}}
      {:error, _} = error -> error
    end
  end

  # Solo cancelar devuelve stock. Atendida deja lo reservado como consumido.
  defp side_effects(:cancelada, need), do: release_all(need.allocations)
  defp side_effects(_to, _need), do: :ok

  defp release_all(allocations) do
    Enum.reduce_while(allocations, :ok, fn a, :ok ->
      case Center.release(a.center, a.code, a.ref) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:release_failed, a.center, reason}}}
      end
    end)
  end

  defp check_zone(state, zone) do
    if Zones.exists?(zone, state.zones), do: :ok, else: {:error, :zone_not_found}
  catch
    :exit, _ -> {:error, :zones_unavailable}
  end

  # La necesidad ya existe; si el enlace falla queda pendiente y `reconcile_links/1` lo repara.
  defp link_zone(state, need) do
    case Zones.link(need.zone, :need, need.id, state.zones) do
      {:ok, _} -> :ok
      {:error, :already_linked} -> :ok
      {:error, reason} -> warn_link(need, reason)
    end
  catch
    :exit, reason -> warn_link(need, reason)
  end

  defp warn_link(need, reason) do
    Logger.warning("No se pudo asociar #{need.id} a la zona #{need.zone}: #{inspect(reason)}")
    :error
  end

  ## Privado

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp apply_and_fetch(book, event) do
    book = Book.apply_event(book, event)
    {:ok, need} = Book.fetch(book, elem(event, 1))
    {book, need}
  end

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
        Logger.warning("needs.log: línea ignorada (#{inspect(reason)})")
        []
    end
  end
end
