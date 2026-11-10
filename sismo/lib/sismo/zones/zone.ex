defmodule Sismo.Zones.AttentionPoint do
  @enforce_keys [:id, :name, :kind]
  defstruct [:id, :name, :kind]
end

defmodule Sismo.Zones.Sector do
  # Recursivo: un sector contiene puntos de atención y subsectores.
  @enforce_keys [:id, :name]
  defstruct [:id, :name, estimated_affected: 0, points: [], subsectors: []]
end

defmodule Sismo.Zones.Zone do
  # level: :critico | :alto | :medio | :bajo
  @enforce_keys [:code, :name]
  defstruct [
    :code,
    :name,
    level: :medio,
    estimated_affected: 0,
    sectors: [],
    shelter_codes: MapSet.new(),
    need_ids: MapSet.new(),
    report_ids: MapSet.new()
  ]
end
