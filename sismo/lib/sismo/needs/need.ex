defmodule Sismo.Needs.Need do
  @moduledoc """
  allocations: lista de %{center, code, quantity, ref}.
  history: lista de {estado, fecha}, la más reciente primero.
  """
  @enforce_keys [:id, :seq, :type, :description, :quantity, :zone, :priority, :reporter, :created_at]
  defstruct [
    :id, :seq, :type, :description, :quantity, :zone, :priority, :reporter, :created_at,
    status: :pendiente,
    allocations: [],
    history: []
  ]

  def assigned(%__MODULE__{allocations: allocations}),
    do: Enum.reduce(allocations, 0, &(&1.quantity + &2))

  def remaining(%__MODULE__{} = need), do: need.quantity - assigned(need)
end
