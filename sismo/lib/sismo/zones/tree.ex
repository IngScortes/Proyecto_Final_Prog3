defmodule Sismo.Zones.Tree do
  @moduledoc """
  Operaciones recursivas sobre la jerarquía de sectores.
  Cada función trata el caso base (lista vacía) y el caso recursivo
  (el sector actual, sus subsectores y los hermanos restantes).
  """
  alias Sismo.Zones.{Sector, Zone}

  ## Búsqueda y actualización

  def find_sector([], _id), do: :error
  def find_sector([%Sector{id: id} = sector | _rest], id), do: {:ok, sector}

  def find_sector([sector | rest], id) do
    case find_sector(sector.subsectors, id) do
      {:ok, _} = found -> found
      :error -> find_sector(rest, id)
    end
  end

  @doc "Aplica `fun` al sector con ese id, sin importar su profundidad. Conserva el orden."
  def update_sector([], _id, _fun), do: :error
  def update_sector([%Sector{id: id} = sector | rest], id, fun), do: {:ok, [fun.(sector) | rest]}

  def update_sector([sector | rest], id, fun) do
    case update_sector(sector.subsectors, id, fun) do
      {:ok, subsectors} ->
        {:ok, [%{sector | subsectors: subsectors} | rest]}

      :error ->
        with {:ok, rest} <- update_sector(rest, id, fun), do: {:ok, [sector | rest]}
    end
  end

  ## Identificadores de todo el árbol

  def sector_ids([]), do: []

  def sector_ids([sector | rest]),
    do: [sector.id | sector_ids(sector.subsectors)] ++ sector_ids(rest)

  def point_ids([]), do: []

  def point_ids([sector | rest]),
    do: Enum.map(sector.points, & &1.id) ++ point_ids(sector.subsectors) ++ point_ids(rest)

  ## Estadísticas acumuladas

  def sector_stats(%Sector{} = sector) do
    children = Enum.map(sector.subsectors, &sector_stats/1)

    %{
      id: sector.id,
      name: sector.name,
      own_affected: sector.estimated_affected,
      total_affected: sector.estimated_affected + sum(children, :total_affected),
      sectors: 1 + sum(children, :sectors),
      points: length(sector.points) + sum(children, :points),
      depth: 1 + max_of(children, :depth),
      children: children
    }
  end

  def zone_stats(%Zone{} = zone) do
    sectors = Enum.map(zone.sectors, &sector_stats/1)

    %{
      code: zone.code,
      name: zone.name,
      level: zone.level,
      own_affected: zone.estimated_affected,
      total_affected: zone.estimated_affected + sum(sectors, :total_affected),
      sectors: sum(sectors, :sectors),
      points: sum(sectors, :points),
      depth: max_of(sectors, :depth),
      shelters: MapSet.size(zone.shelter_codes),
      needs: MapSet.size(zone.need_ids),
      reports: MapSet.size(zone.report_ids),
      tree: sectors
    }
  end

  defp sum(list, key), do: Enum.reduce(list, 0, fn item, acc -> item[key] + acc end)
  defp max_of(list, key), do: Enum.reduce(list, 0, fn item, acc -> max(item[key], acc) end)
end
