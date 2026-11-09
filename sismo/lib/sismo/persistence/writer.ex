defmodule Sismo.Persistence.Writer do
  @moduledoc """
  Único proceso que escribe en disco: serializa el acceso a los archivos.
  `append/3` y `snapshot/3` son asíncronos (cast); `append_sync/3` confirma
  la escritura antes de responder.
  """
  use GenServer
  require Logger

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))

  def append(path, line, server \\ __MODULE__), do: GenServer.cast(server, {:append, path, line})
  def snapshot(path, lines, server \\ __MODULE__), do: GenServer.cast(server, {:snapshot, path, lines})

  def append_sync(path, line, server \\ __MODULE__),
    do: GenServer.call(server, {:append, path, line})

  @doc "Barrera: retorna cuando todo lo encolado antes ya se escribió."
  def flush(server \\ __MODULE__), do: GenServer.call(server, :flush)

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:append, path, line}, _from, state), do: {:reply, do_append(path, line), state}
  def handle_call(:flush, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_cast({:append, path, line}, state) do
    path |> do_append(line) |> log_failure(path)
    {:noreply, state}
  end

  def handle_cast({:snapshot, path, lines}, state) do
    path |> do_snapshot(lines) |> log_failure(path)
    {:noreply, state}
  end

  defp do_append(path, line) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, [line, "\n"], [:append])
    end
  end

  # Escritura atómica: tmp + rename, para no dejar archivos a medias.
  defp do_snapshot(path, lines) do
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, Enum.map(lines, &[&1, "\n"])),
         :ok <- File.rename(tmp, path) do
      :ok
    end
  end

  defp log_failure(:ok, _path), do: :ok
  defp log_failure({:error, reason}, path), do: Logger.error("Persistencia fallida en #{path}: #{inspect(reason)}")
end
