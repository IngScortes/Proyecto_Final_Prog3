defmodule Sismo.Resources.CenterSupervisor do
  use DynamicSupervisor
  alias Sismo.Resources.Center

  @id_regex ~r/^[a-z0-9_]{1,40}$/

  def start_link(opts \\ []),
    do: DynamicSupervisor.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc "Abre un centro nuevo. Un fallo en un centro no afecta a los demás."
  def open_center(id, zone, opts \\ []) do
    supervisor = Keyword.get(opts, :supervisor, __MODULE__)
    data_dir = Keyword.get(opts, :data_dir, default_dir())

    with {:ok, id} <- validate_id(id),
         {:ok, zone} <- validate_zone(zone),
         {:ok, _pid} <-
           start_center(supervisor, Keyword.merge(opts, id: id, zone: zone, data_dir: data_dir)) do
      {:ok, id}
    end
  end

  @doc "Levanta los centros que ya tienen archivo en disco (se llama al arrancar la aplicación)."
  def restore_all(data_dir \\ default_dir(), supervisor \\ __MODULE__) do
    data_dir
    |> Path.join("centers")
    |> Path.join("*.log")
    |> Path.wildcard()
    |> Enum.map(&Path.basename(&1, ".log"))
    |> Enum.map(fn id -> {id, start_center(supervisor, id: id, data_dir: data_dir)} end)
  end

  defp start_center(supervisor, child_opts) do
    case DynamicSupervisor.start_child(supervisor, {Center, child_opts}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, _pid}} -> {:error, :already_exists}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_id(id) when is_binary(id) do
    id = id |> String.trim() |> String.downcase()
    if Regex.match?(@id_regex, id), do: {:ok, id}, else: {:error, {:invalid_field, :id}}
  end

  defp validate_id(_), do: {:error, {:invalid_field, :id}}

  defp validate_zone(zone) when is_binary(zone) do
    case zone |> String.trim() |> String.downcase() do
      "" -> {:error, {:invalid_field, :zone}}
      zone -> {:ok, zone}
    end
  end

  defp validate_zone(_), do: {:error, {:invalid_field, :zone}}

  defp default_dir, do: Application.get_env(:sismo, :data_dir, "data")
end
