defmodule Sismo.Pets.Report do
  @moduledoc """
  kind: :perdida | :encontrada
  size: :pequeno | :mediano | :grande
  status: :activa | :posible_coincidencia | :resuelta
  history: lista de {estado, fecha}, la más reciente primero.
  """
  @enforce_keys [:id, :seq, :kind, :species, :color, :size, :zone, :contact, :reporter, :created_at]
  defstruct [
    :id, :seq, :kind, :species, :name, :color, :size, :zone, :contact, :reporter, :created_at,
    traits: "",
    status: :activa,
    matched_with: nil,
    history: []
  ]
end
