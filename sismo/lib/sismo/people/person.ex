defmodule Sismo.People.Person do
  @moduledoc """
  status: :sin_informacion | :reportada | :localizada | :trasladada | :en_albergue | :reunificada
  history: lista de {estado, fecha, quién}, la más reciente primero.
  """
  @enforce_keys [:id, :seq, :document, :name, :zone, :status, :reporter, :created_at]
  defstruct [:id, :seq, :document, :name, :age, :zone, :status, :reporter, :created_at, history: []]
end

defmodule Sismo.People.FamilyMessage do
  # status: :pendiente | :entregado
  @enforce_keys [:id, :seq, :from, :to_document, :content, :at]
  defstruct [:id, :seq, :from, :to_document, :content, :at, status: :pendiente]
end
