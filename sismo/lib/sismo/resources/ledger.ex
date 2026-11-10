defmodule Sismo.Resources.Ledger do
  @moduledoc """
  Estado de inventario de un centro y reglas de negocio, todo en funciones puras.
  `decide/5` y `register/6` validan y producen un movimiento; `apply_movement/2` lo aplica.
  """
  alias Sismo.Resources.{Movement, Resource}

  @credit_kinds [:entrada, :transferencia_entrada, :compensacion]
  @debit_kinds [:salida, :transferencia_salida, :reserva]
  @move_kinds @credit_kinds ++ @debit_kinds
  @code_regex ~r/^[A-Za-z0-9_-]{1,32}$/

  defstruct [:id, :zone, resources: %{}, reservations: %{}, history: [], seq: 0]

  def new(id, zone), do: %__MODULE__{id: id, zone: zone}

  ## Reconstrucción (recursión sobre la lista de movimientos)

  def replay(%__MODULE__{} = ledger, []), do: ledger
  def replay(%__MODULE__{} = ledger, [m | rest]), do: replay(apply_movement(ledger, m), rest)

  ## Aplicar movimientos ya validados

  def apply_movement(l, %Movement{kind: :centro, extra: [zone]} = m),
    do: record(%{l | zone: zone}, m)

  def apply_movement(l, %Movement{kind: :alta, extra: [name, category, unit]} = m) do
    resource = %Resource{
      code: m.code, name: name, category: category, unit: unit,
      center_id: l.id, zone: l.zone, available: m.quantity
    }

    record(%{l | resources: Map.put(l.resources, m.code, resource)}, m)
  end

    def apply_movement(l, %Movement{kind: :liberacion} = m) do
    l = adjust(l, m.code, m.quantity)
    record(%{l | reservations: Map.delete(l.reservations, {m.code, m.ref})}, m)
  end

  def apply_movement(l, %Movement{kind: kind} = m) when kind in @credit_kinds,
    do: record(adjust(l, m.code, m.quantity), m)

  def apply_movement(l, %Movement{kind: :reserva} = m) do
    l = adjust(l, m.code, -m.quantity)
    record(%{l | reservations: Map.put(l.reservations, {m.code, m.ref}, m.quantity)}, m)
  end

  def apply_movement(l, %Movement{kind: kind} = m) when kind in @debit_kinds,
    do: record(adjust(l, m.code, -m.quantity), m)

  # Registro que no corresponde a ningún movimiento conocido: se ignora al reconstruir.
  def apply_movement(l, _other), do: l

  ## Decisiones (validación)

  def header(%__MODULE__{} = l, zone), do: movement(l, :centro, "-", 0, nil, [zone])

  def register(%__MODULE__{} = l, code, name, category, unit, qty) do
    with {:ok, code} <- validate_code(code),
         {:ok, name} <- validate_text(name, :name),
         {:ok, category} <- validate_text(category, :category),
         {:ok, unit} <- validate_text(unit, :unit),
         :ok <- validate_non_negative(qty),
         :ok <- ensure_absent(l, code) do
      {:ok, movement(l, :alta, code, qty, nil, [name, category, unit])}
    end
  end

  @doc "Devuelve `{:ok, movimiento}`, `{:noop, cantidad_ya_reservada}` o `{:error, razón}`."
  def decide(%__MODULE__{} = l, :reserva, code, qty, ref) do
    with :ok <- validate_ref(ref) do
      case Map.fetch(l.reservations, {code, ref}) do
        {:ok, reserved} -> {:noop, reserved}
        :error -> do_decide(l, :reserva, code, qty, ref)
      end
    end
  end

  def decide(%__MODULE__{} = l, kind, code, qty, ref) when kind in @move_kinds,
    do: do_decide(l, kind, code, qty, ref)

  def decide(_l, _kind, _code, _qty, _ref), do: {:error, :invalid_kind}

  defp do_decide(l, kind, code, qty, ref) do
    with :ok <- validate_positive(qty),
         {:ok, resource} <- fetch_resource(l, code),
         :ok <- check_stock(kind, resource, qty) do
      {:ok, movement(l, kind, code, qty, ref, [])}
    end
  end
    @doc "Devuelve `{:ok, movimiento}` si hay una reserva con esa referencia, o `:none`."
  def release(%__MODULE__{} = l, code, ref) do
    case Map.fetch(l.reservations, {code, ref}) do
      {:ok, qty} -> {:ok, movement(l, :liberacion, code, qty, ref, [])}
      :error -> :none
    end
  end

  defp check_stock(kind, %Resource{available: available}, qty)
       when kind in @debit_kinds and qty > available,
       do: {:error, {:insufficient_stock, available}}

  defp check_stock(_kind, _resource, _qty), do: :ok

  ## Auxiliares

  defp movement(l, kind, code, qty, ref, extra) do
    %Movement{
      id: l.seq + 1, kind: kind, code: code, quantity: qty, ref: ref, extra: extra,
      at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp record(l, %Movement{id: id} = m), do: %{l | history: [m | l.history], seq: max(l.seq, id)}

  defp adjust(l, code, delta) do
    case Map.fetch(l.resources, code) do
      {:ok, r} -> %{l | resources: Map.put(l.resources, code, %{r | available: r.available + delta})}
      :error -> l
    end
  end

  defp fetch_resource(l, code) do
    case Map.fetch(l.resources, code) do
      {:ok, r} -> {:ok, r}
      :error -> {:error, :resource_not_found}
    end
  end

  defp ensure_absent(l, code),
    do: if(Map.has_key?(l.resources, code), do: {:error, :duplicate_code}, else: :ok)

  defp validate_code(code) when is_binary(code) do
    code = String.trim(code)
    if Regex.match?(@code_regex, code), do: {:ok, code}, else: {:error, {:invalid_field, :code}}
  end

  defp validate_code(_), do: {:error, {:invalid_field, :code}}

  defp validate_text(value, field) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, {:invalid_field, field}}
      text -> {:ok, text}
    end
  end

  defp validate_text(_, field), do: {:error, {:invalid_field, field}}

  defp validate_ref(ref) when is_binary(ref) and ref != "", do: :ok
  defp validate_ref(_), do: {:error, {:invalid_field, :ref}}

  defp validate_positive(q) when is_integer(q) and q > 0, do: :ok
  defp validate_positive(_), do: {:error, :invalid_quantity}

  defp validate_non_negative(q) when is_integer(q) and q >= 0, do: :ok
  defp validate_non_negative(_), do: {:error, :invalid_quantity}
end
