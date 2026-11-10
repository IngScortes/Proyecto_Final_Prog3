defmodule Sismo.Resources.Movement do
  @moduledoc """
  Un movimiento de inventario. `:centro` es el encabezado del archivo (guarda la zona)
  y `:alta` registra un recurso nuevo (en `extra`: nombre, categoría y unidad).
  """
  @enforce_keys [:id, :kind, :code, :quantity, :at]
  defstruct [:id, :kind, :code, :quantity, :at, ref: nil, extra: []]

  @kinds ~w(centro alta entrada salida reserva transferencia_salida
            transferencia_entrada compensacion)a
  @by_name Map.new(@kinds, &{Atom.to_string(&1), &1})

  def to_fields(%__MODULE__{} = m),
    do: [m.id, m.at, Atom.to_string(m.kind), m.code, m.quantity, m.ref || ""] ++ m.extra

  def from_fields([id, at, kind, code, qty, ref | extra]) do
    with {id, ""} <- Integer.parse(id),
         {qty, ""} <- Integer.parse(qty),
         {:ok, kind} <- Map.fetch(@by_name, kind) do
      {:ok,
       %__MODULE__{
         id: id, at: at, kind: kind, code: code, quantity: qty,
         ref: if(ref == "", do: nil, else: ref), extra: extra
       }}
    else
      _ -> {:error, :malformed_record}
    end
  end

  def from_fields(_), do: {:error, :malformed_record}
end
