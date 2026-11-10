defmodule Sismo.Resources.Resource do
  @enforce_keys [:code, :name, :category, :unit, :center_id]
  defstruct [:code, :name, :category, :unit, :center_id, :zone, available: 0]
end
