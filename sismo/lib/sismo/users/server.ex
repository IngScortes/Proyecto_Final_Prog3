defmodule Sismo.Users.Server do
  @moduledoc """
  Dueño del estado de usuarios y sesiones. Todas las operaciones se serializan
  en su mailbox, por lo que el registro automático concurrente del mismo
  usuario es seguro: exactamente una llamada registra, el resto autentica.
  """
  use GenServer
  require Logger

  alias Sismo.Activity.Log
  alias Sismo.Persistence.{Codec, Writer}
  alias Sismo.Users.{Permissions, User}

  # El rol administrador no se obtiene por auto-registro.
  @self_registrable [:ciudadano, :voluntario, :coordinador]

  defstruct users: %{}, sessions: %{}, path: nil, writer: Writer, activity: Log

  ## API pública (el servidor es el último argumento opcional)

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @spec connect(String.t(), String.t(), map(), GenServer.server()) ::
          {:ok, :registered | :authenticated, map()} | {:error, term()}
  def connect(username, password, attrs \\ %{}, server \\ __MODULE__) when is_map(attrs),
    do: GenServer.call(server, {:connect, username, password, attrs})

  @spec disconnect(String.t(), GenServer.server()) :: :ok | {:error, :not_connected}
  def disconnect(username, server \\ __MODULE__), do: GenServer.call(server, {:disconnect, username})

  @spec authorize(String.t(), atom(), GenServer.server()) ::
          {:ok, map()} | {:error, :not_connected | :forbidden}
  def authorize(username, action, server \\ __MODULE__) when is_atom(action),
    do: GenServer.call(server, {:authorize, username, action})

  def connected?(username, server \\ __MODULE__), do: GenServer.call(server, {:connected?, username})
  def user_count(server \\ __MODULE__), do: GenServer.call(server, :user_count)

  ## Callbacks

  @impl true
  def init(opts) do
    path = opts |> Keyword.fetch!(:data_dir) |> Path.join("users.db")

    {:ok,
     %__MODULE__{
       path: path,
       users: load_users(path),
       writer: Keyword.get(opts, :writer, Writer),
       activity: Keyword.get(opts, :activity, Log)
     }}
  end

  @impl true
  def handle_call({:connect, username, password, attrs}, {caller, _tag}, state) do
    with {:ok, username} <- User.normalize_username(username),
         {:ok, kind, user} <- authenticate_or_register(state, username, password, attrs),
         :ok <- ensure_disconnected(state, username),
         :ok <- persist_if_new(state, kind, user) do
      session = %{pid: caller, ref: Process.monitor(caller), connected_at: DateTime.utc_now()}

      state = %{
        state
        | users: Map.put(state.users, username, user),
          sessions: Map.put(state.sessions, username, session)
      }

      Log.record(username, "connect", Atom.to_string(kind), state.activity)
      {:reply, {:ok, kind, User.public(user)}, state}
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:disconnect, username}, _from, state) do
    username = User.canonical_username(username)

    case Map.pop(state.sessions, username) do
      {nil, _sessions} ->
        {:reply, {:error, :not_connected}, state}

      {%{ref: ref}, sessions} ->
        Process.demonitor(ref, [:flush])
        Log.record(username, "disconnect", "", state.activity)
        {:reply, :ok, %{state | sessions: sessions}}
    end
  end

  def handle_call({:authorize, username, action}, _from, state) do
    case fetch_connected(state, username) do
      {:ok, user} ->
        if Permissions.can?(user.role, action) do
          {:reply, {:ok, User.public(user)}, state}
        else
          Log.record(user.username, "forbidden", Atom.to_string(action), state.activity)
          {:reply, {:error, :forbidden}, state}
        end

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:connected?, username}, _from, state),
    do: {:reply, Map.has_key?(state.sessions, User.canonical_username(username)), state}

  def handle_call(:user_count, _from, state), do: {:reply, map_size(state.users), state}

  # Si el proceso cliente muere, su sesión se libera sola.
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    sessions = state.sessions |> Enum.reject(fn {_user, s} -> s.ref == ref end) |> Map.new()
    {:noreply, %{state | sessions: sessions}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## Lógica privada

  defp authenticate_or_register(state, username, password, attrs) do
    case Map.fetch(state.users, username) do
      {:ok, user} ->
        if User.valid_password?(user, password),
          do: {:ok, :authenticated, user},
          else: {:error, :invalid_credentials}

      :error ->
        register(username, password, attrs)
    end
  end

  defp register(username, password, attrs) do
    with {:ok, user} <- User.new(Map.merge(attrs, %{username: username, password: password})),
         :ok <- check_self_registrable(user.role) do
      {:ok, :registered, user}
    end
  end

  defp check_self_registrable(role) when role in @self_registrable, do: :ok
  defp check_self_registrable(_role), do: {:error, :role_not_self_registrable}

  defp ensure_disconnected(state, username) do
    if Map.has_key?(state.sessions, username), do: {:error, :already_connected}, else: :ok
  end

  # Escritura previa a la confirmación: si el disco falla, el estado NO cambia.
  defp persist_if_new(state, :registered, user) do
    case Writer.append_sync(state.path, Codec.encode_line(User.to_fields(user)), state.writer) do
      :ok -> :ok
      {:error, reason} -> {:error, {:persist_failed, reason}}
    end
  end

  defp persist_if_new(_state, :authenticated, _user), do: :ok

  defp fetch_connected(state, username) do
    username = User.canonical_username(username)

    with true <- Map.has_key?(state.sessions, username),
         {:ok, user} <- Map.fetch(state.users, username) do
      {:ok, user}
    else
      _ -> {:error, :not_connected}
    end
  end

  defp load_users(path) do
    case File.read(path) do
      {:ok, content} -> content |> String.split("\n", trim: true) |> Enum.reduce(%{}, &load_line/2)
      {:error, :enoent} -> %{}
      {:error, reason} -> Logger.error("No se pudo leer #{path}: #{inspect(reason)}") && %{}
    end
  end

  defp load_line(line, acc) do
    with {:ok, user} <- line |> Codec.decode_line() |> User.from_fields() do
      Map.put(acc, user.username, user)
    else
      {:error, reason} ->
        Logger.warning("users.db: línea ignorada (#{inspect(reason)})")
        acc
    end
  end
end
