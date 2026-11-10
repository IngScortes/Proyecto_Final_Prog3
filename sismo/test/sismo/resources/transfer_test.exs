# test/sismo/resources/transfer_test.exs
defmodule Sismo.Resources.TransferTest do
  use ExUnit.Case, async: true
  alias Sismo.Resources.{Center, Transfer}

  setup do
    dir = Path.join(System.tmp_dir!(), "sismo_transfer_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    n = System.unique_integer([:positive])
    a = "a_#{n}"
    b = "b_#{n}"

    for id <- [a, b] do
      start_supervised!(Supervisor.child_spec({Center, id: id, zone: "centro", data_dir: dir}, id: id))
    end

    {:ok, _} = Center.register_resource(a, "R001", "agua", "agua", "litros", 50)
    {:ok, a: a, b: b}
  end

  test "mueve stock y crea el recurso en el destino", ctx do
    assert {:ok, %{quantity: 30}} = Transfer.transfer(ctx.a, ctx.b, "R001", 30)

    assert {:ok, %{available: 20}} = Center.get_resource(ctx.a, "R001")
    assert {:ok, %{available: 30, name: "agua", unit: "litros"}} = Center.get_resource(ctx.b, "R001")
  end

  test "errores esperados no modifican ningún centro", ctx do
    assert {:error, {:insufficient_stock, 50}} = Transfer.transfer(ctx.a, ctx.b, "R001", 51)
    assert {:error, :center_not_found} = Transfer.transfer(ctx.a, "no_existe", "R001", 5)
    assert {:error, :resource_not_found} = Transfer.transfer(ctx.a, ctx.b, "NOPE", 5)
    assert {:error, :same_center} = Transfer.transfer(ctx.a, ctx.a, "R001", 5)
    assert {:error, :invalid_quantity} = Transfer.transfer(ctx.a, ctx.b, "R001", -5)

    assert {:ok, %{available: 50}} = Center.get_resource(ctx.a, "R001")
  end

  test "10 transferencias de 10 sobre 50 disponibles: solo 5 se confirman", ctx do
    results =
      1..10
      |> Enum.map(fn _ -> Task.async(fn -> Transfer.transfer(ctx.a, ctx.b, "R001", 10) end) end)
      |> Task.await_many(15_000)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 5
    assert {:ok, %{available: 0}} = Center.get_resource(ctx.a, "R001")
    assert {:ok, %{available: 50}} = Center.get_resource(ctx.b, "R001")
  end

  test "transferencias cruzadas simultáneas no se bloquean y conservan el total", ctx do
    {:ok, _} = Center.register_resource(ctx.b, "R001", "agua", "agua", "litros", 50)

    results =
      1..40
      |> Enum.map(fn i ->
        Task.async(fn ->
          if rem(i, 2) == 0,
            do: Transfer.transfer(ctx.a, ctx.b, "R001", 1),
            else: Transfer.transfer(ctx.b, ctx.a, "R001", 1)
        end)
      end)
      |> Task.await_many(15_000)

    assert Enum.all?(results, &match?({:ok, _}, &1))
    {:ok, ra} = Center.get_resource(ctx.a, "R001")
    {:ok, rb} = Center.get_resource(ctx.b, "R001")
    assert ra.available + rb.available == 100
  end
end
