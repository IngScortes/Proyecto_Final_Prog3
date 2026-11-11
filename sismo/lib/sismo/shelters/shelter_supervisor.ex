defmodule Sismo.Shelters.ShelterSupervisor do
  use DynamicSupervisor
  require Logger

  alias Sismo.Persistence.Writer
  alias Sismo.Shelters.{Server, Shelter}
  alias Sismo.Zones.Server, as: Zones

  def start_link(opts \\ []),
    do: DynamicSupervisor.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)

  @doc """
  Abre un albergue nuevo. Valida los datos y la zona ANTES de crear el proceso,
  y después lo asocia a la zona. Un fallo en un albergue no afecta a los demás.
  """
  def open_shelter(code, name, zone, capacity, opts \\ []) do
    supervisor = Keyword.get(opts, :supervisor, __MODULE__)
    zones = Keyword.get(opts, :zones, Zones)

    with {:ok, {:created, code, name, zone, capacity, _at}} <-
           Shelter.create(code, name, zone, capacity, now()),
         :ok <- check_zone(zone, zones),
         {:ok, _pid} <-
           start_shelter(supervisor,
             code: code,
             name: name,
             zone: zone,
             capacity: capacity,
             data_dir: Keyword.get(opts, :data_dir, default_dir()),
             writer: Keyword.get(opts, :writer, Writer)
           ) do
      link_zone(zone, code, zones)
      {:ok, code}
    end
  end

   @doc "Levanta los albergues que ya tienen archivo en disco (se llama al arrancar)."
  def restore_all(data_dir \\ default_dir(), supervisor \\ __MODULE__) do
    case File.ls(Path.join(data_dir, "shelters")) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".log"))
        |> Enum.sort()
        |> Enum.map(&Path.rootname(&1, ".log"))
        |> Enum.map(fn code -> {code, start_shelter(supervisor, code: code, data_dir: data_dir)} end)

      {:error, _} ->
        []
    end
  end

  @doc "Códigos de los albergues vivos, ordenados."
  def codes do
    Sismo.Registry
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.flat_map(fn
      {:shelter, code} -> [code]
      _other -> []
    end)
    |> Enum.sort()
  end

  @doc "Repara asociaciones albergue-zona pendientes. `only` limita los códigos revisados."
  def reconcile_links(zones \\ Zones, only \\ nil) do
    for code <- only || codes(), {:ok, info} <- [Server.info(code)] do
      link_zone(info.zone, code, zones)
    end

    :ok
  end

  ## Privado

  defp start_shelter(supervisor, child_opts) do
    case DynamicSupervisor.start_child(supervisor, {Server, child_opts}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, _pid}} -> {:error, :already_exists}
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_zone(zone, zones) do
    if Zones.exists?(zone, zones), do: :ok, else: {:error, :zone_not_found}
  catch
    :exit, _ -> {:error, :zones_unavailable}
  end

  defp link_zone(zone, code, zones) do
    case Zones.link(zone, :shelter, code, zones) do
      {:ok, _} -> :ok
      {:error, :already_linked} -> :ok
      {:error, reason} -> warn_link(code, zone, reason)
    end
  catch
    :exit, reason -> warn_link(code, zone, reason)
  end

  defp warn_link(code, zone, reason) do
    Logger.warning("No se pudo asociar el albergue #{code} a la zona #{zone}: #{inspect(reason)}")
    :error
  end

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
  defp default_dir, do: Application.get_env(:sismo, :data_dir, "data")
end
