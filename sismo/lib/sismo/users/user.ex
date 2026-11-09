defmodule Sismo.Users.User do
  @derive {Inspect, except: [:password_hash, :salt]}
  @enforce_keys [:username, :password_hash, :salt, :full_name, :role, :zone, :created_at]
  defstruct @enforce_keys

  @roles %{
    "ciudadano" => :ciudadano,
    "voluntario" => :voluntario,
    "coordinador" => :coordinador,
    "coordinadora" => :coordinador,
    "administrador" => :administrador,
    "admin" => :administrador
  }
  @username_regex ~r/^[a-z0-9_]{3,32}$/
  @min_password 4
  # Compromiso: el hash corre dentro del GenServer. 10_000 iteraciones mantiene
  # la latencia baja en el curso; en producción serían ≥ 100_000.
  @iterations 10_000

  @type t :: %__MODULE__{}

  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(%{} = attrs) do
    with {:ok, username} <- normalize_username(attrs[:username]),
         {:ok, password} <- validate_password(attrs[:password]),
         {:ok, role} <- parse_role(attrs[:role]),
         {:ok, zone} <- validate_text(attrs[:zone], :zone),
         {:ok, full_name} <- validate_text(attrs[:full_name] || username, :full_name) do
      salt = 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

      {:ok,
       %__MODULE__{
         username: username,
         password_hash: hash_password(password, salt),
         salt: salt,
         full_name: full_name,
         role: role,
         zone: String.downcase(zone),
         created_at: DateTime.utc_now() |> DateTime.to_iso8601()
       }}
    end
  end

  def normalize_username(name) when is_binary(name) do
    name = name |> String.trim() |> String.downcase()

    if Regex.match?(@username_regex, name),
      do: {:ok, name},
      else: {:error, {:invalid_field, :username}}
  end

  def normalize_username(_), do: {:error, {:invalid_field, :username}}

  @doc "Para búsquedas: normaliza si es texto, deja pasar cualquier otra cosa."
  def canonical_username(name) when is_binary(name), do: name |> String.trim() |> String.downcase()
  def canonical_username(other), do: other

  def parse_role(role) when is_atom(role) and not is_nil(role),
    do: role |> Atom.to_string() |> parse_role()

  def parse_role(role) when is_binary(role) do
    case Map.fetch(@roles, role |> String.trim() |> String.downcase()) do
      {:ok, parsed} -> {:ok, parsed}
      :error -> {:error, {:invalid_field, :role}}
    end
  end

  def parse_role(_), do: {:error, {:invalid_field, :role}}

  @spec valid_password?(t(), term()) :: boolean()
  def valid_password?(%__MODULE__{} = user, password) when is_binary(password) do
    actual = hash_password(password, user.salt)
    byte_size(actual) == byte_size(user.password_hash) and :crypto.hash_equals(actual, user.password_hash)
  end

  def valid_password?(_user, _password), do: false

  @doc "Vista segura (sin hash ni sal) para devolver a los clientes."
  def public(%__MODULE__{} = u),
    do: %{username: u.username, full_name: u.full_name, role: u.role, zone: u.zone}

  def to_fields(%__MODULE__{} = u),
    do: [u.username, u.password_hash, u.salt, u.full_name, Atom.to_string(u.role), u.zone, u.created_at]

  def from_fields([username, hash, salt, full_name, role, zone, created_at]) do
    with {:ok, role} <- parse_role(role) do
      {:ok,
       %__MODULE__{
         username: username, password_hash: hash, salt: salt, full_name: full_name,
         role: role, zone: zone, created_at: created_at
       }}
    end
  end

  def from_fields(_), do: {:error, :malformed_record}

  defp validate_password(pw) when is_binary(pw) and byte_size(pw) >= @min_password, do: {:ok, pw}
  defp validate_password(_), do: {:error, {:invalid_field, :password}}

  defp validate_text(value, field) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, {:invalid_field, field}}
      text -> {:ok, text}
    end
  end

  defp validate_text(_, field), do: {:error, {:invalid_field, field}}

  defp hash_password(password, salt),
    do: :crypto.pbkdf2_hmac(:sha256, password, salt, @iterations, 32) |> Base.encode16(case: :lower)
end
