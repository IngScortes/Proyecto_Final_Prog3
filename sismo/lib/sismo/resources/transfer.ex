# lib/sismo/resources/transfer.ex
defmodule Sismo.Resources.Transfer do
  @moduledoc """
  Transferencia entre dos centros como saga:
    1. asegurar el recurso en el destino (stock 0 si no existe),
    2. retirar del origen,
    3. depositar en el destino,
    4. si falla el paso 3, compensar devolviendo la cantidad al origen.
  Nunca se hace una llamada de un centro a otro, así que no hay deadlock.
  """
  require Logger
  alias Sismo.Resources.Center

  def transfer(from, to, code, qty), do: transfer(from, to, code, qty, new_id())

  def transfer(same, same, _code, _qty, _id), do: {:error, :same_center}

  def transfer(_from, _to, _code, qty, _id) when not (is_integer(qty) and qty > 0),
    do: {:error, :invalid_quantity}

  def transfer(from, to, code, qty, transfer_id) do
    with {:ok, resource} <- Center.get_resource(from, code),
         :ok <- ensure_in_destination(to, resource),
         {:ok, _out} <- Center.move(from, :transferencia_salida, code, qty, transfer_id) do
      deposit_or_compensate(from, to, code, qty, transfer_id)
    end
  end

  defp deposit_or_compensate(from, to, code, qty, transfer_id) do
    case safe_move(to, :transferencia_entrada, code, qty, transfer_id) do
      {:ok, _} ->
        {:ok, %{transfer_id: transfer_id, from: from, to: to, code: code, quantity: qty}}

      {:error, reason} ->
        case safe_move(from, :compensacion, code, qty, transfer_id) do
          {:ok, _} ->
            {:error, {:transfer_failed, reason}}

          {:error, comp_reason} ->
            Logger.error("Compensación fallida en #{transfer_id}: #{inspect(comp_reason)}")
            {:error, {:compensation_failed, reason, comp_reason}}
        end
    end
  end

  defp ensure_in_destination(to, resource) do
    case Center.register_resource(to, resource.code, resource.name, resource.category, resource.unit, 0) do
      {:ok, _} -> :ok
      {:error, :duplicate_code} -> :ok
      {:error, _} = error -> error
    end
  end

  defp safe_move(id, kind, code, qty, ref) do
    Center.move(id, kind, code, qty, ref)
  catch
    :exit, reason -> {:error, {:center_down, reason}}
  end

  defp new_id, do: "T#{System.os_time(:millisecond)}_#{System.unique_integer([:positive])}"
end
