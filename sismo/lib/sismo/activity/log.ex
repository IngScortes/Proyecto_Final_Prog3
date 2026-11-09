defmodule Sismo.Activity.Log do
  use GenServer
  alias Sismo.Persistence.{Codec, Writer}

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Registro asíncrono: no bloquea al llamador."
  def record(username, action, detail \\ "", server \\ __MODULE__),
    do: GenServer.cast(server, {:record, username, action, detail})

  @doc "Actividad del usuario, la más reciente primero."
  def for_user(username, server \\ __MODULE__), do: GenServer.call(server, {:for_user, username})

  @impl true
  def init(opts) do
    path = opts |> Keyword.fetch!(:data_dir) |> Path.join("activity.log")
    {:ok, %{path: path, writer: Keyword.get(opts, :writer, Writer), by_user: load(path)}}
  end

  @impl true
  def handle_cast({:record, username, action, detail}, state) do
    entry = new_entry(DateTime.utc_now() |> DateTime.to_iso8601(), username, action, detail)
    Writer.append(state.path, Codec.encode_line([entry.at, username, action, detail]), state.writer)
    {:noreply, %{state | by_user: Map.update(state.by_user, username, [entry], &[entry | &1])}}
  end

  @impl true
  def handle_call({:for_user, username}, _from, state),
    do: {:reply, Map.get(state.by_user, username, []), state}

  defp new_entry(at, username, action, detail),
    do: %{at: at, username: username, action: action, detail: detail}

  defp load(path) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.map(&Codec.decode_line/1)
        |> Enum.reduce(%{}, fn
          [at, user, action, detail], acc ->
            Map.update(acc, user, [new_entry(at, user, action, detail)], &[new_entry(at, user, action, detail) | &1])

          _malformed, acc ->
            acc
        end)

      {:error, _} ->
        %{}
    end
  end
end
