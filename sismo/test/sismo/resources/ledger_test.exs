defmodule Sismo.Resources.LedgerTest do
  use ExUnit.Case, async: true
  alias Sismo.Resources.Ledger

  defp ledger_with_stock(qty) do
    l = Ledger.new("c1", "centro")
    {:ok, m} = Ledger.register(l, "R001", "agua", "agua", "litros", qty)
    Ledger.apply_movement(l, m)
  end

  test "rechaza códigos duplicados y datos inválidos" do
    l = ledger_with_stock(10)
    assert {:error, :duplicate_code} = Ledger.register(l, "R001", "x", "y", "z", 1)
    assert {:error, :invalid_quantity} = Ledger.register(l, "R002", "x", "y", "z", -1)
    assert {:error, {:invalid_field, :code}} = Ledger.register(l, "R 3", "x", "y", "z", 1)
    assert {:error, {:invalid_field, :unit}} = Ledger.register(l, "R004", "x", "y", " ", 1)
  end

  test "nunca permite stock negativo" do
    l = ledger_with_stock(10)
    assert {:error, {:insufficient_stock, 10}} = Ledger.decide(l, :salida, "R001", 11, nil)
    assert {:error, :invalid_quantity} = Ledger.decide(l, :salida, "R001", 0, nil)
    assert {:error, :invalid_quantity} = Ledger.decide(l, :entrada, "R001", -3, nil)
    assert {:error, :resource_not_found} = Ledger.decide(l, :salida, "NOPE", 1, nil)
  end

  test "la reserva es idempotente por need_id" do
    l = ledger_with_stock(50)
    {:ok, m} = Ledger.decide(l, :reserva, "R001", 30, "N001")
    l = Ledger.apply_movement(l, m)

    assert {:noop, 30} = Ledger.decide(l, :reserva, "R001", 30, "N001")
    assert l.resources["R001"].available == 20
    assert {:error, {:invalid_field, :ref}} = Ledger.decide(l, :reserva, "R001", 1, nil)
  end

  test "replay reconstruye el estado a partir de los movimientos" do
    l0 = ledger_with_stock(100)

    {l, _} =
      Enum.reduce([{:salida, 10}, {:entrada, 5}, {:reserva, 20}], {l0, 1}, fn {kind, q}, {acc, n} ->
        {:ok, m} = Ledger.decide(acc, kind, "R001", q, "ref#{n}")
        {Ledger.apply_movement(acc, m), n + 1}
      end)

    rebuilt = Ledger.replay(Ledger.new("c1", "centro"), Enum.reverse(l.history))

    assert l.resources["R001"].available == 75
    assert rebuilt.resources == l.resources
    assert rebuilt.reservations == l.reservations
  end
end
