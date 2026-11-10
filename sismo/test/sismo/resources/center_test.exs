defmodule Sismo.Resources.CenterTest do
  use ExUnit.Case, async: true
  alias Sismo.Resources.{Center, Movement}

  setup do
    dir = Path.join(System.tmp_dir!(), "sismo_center_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    id = "c_#{System.unique_integer([:positive])}"
    start_supervised!(Supervisor.child_spec({Center, id: id, zone: "centro", data_dir: dir}, id: id))
    {:ok, id: id, dir: dir}
  end

  test "55 litros solicitados contra 50 disponibles: solo se confirma lo que alcanza", ctx do
    {:ok, _} = Center.register_resource(ctx.id, "R001", "agua", "agua", "litros", 50)

    results =
      [{"N001", 30}, {"N002", 25}]
      |> Enum.map(fn {need, qty} -> Task.async(fn -> Center.reserve(ctx.id, "R001", qty, need) end) end)
      |> Task.await_many(5_000)

    assert Enum.count(results, &match?({:ok, %Movement{}}, &1)) == 1
    assert Enum.count(results, &match?({:error, {:insufficient_stock, _}}, &1)) == 1

    {:ok, resource} = Center.get_resource(ctx.id, "R001")
    assert resource.available in [20, 25]
  end

  test "200 reservas simultáneas de 1 unidad sobre 100 disponibles: exactamente 100 pasan", ctx do
    {:ok, _} = Center.register_resource(ctx.id, "R001", "agua", "agua", "litros", 100)

    results =
      1..200
      |> Enum.map(fn i -> Task.async(fn -> Center.reserve(ctx.id, "R001", 1, "N#{i}") end) end)
      |> Task.await_many(30_000)

    assert Enum.count(results, &match?({:ok, %Movement{}}, &1)) == 100
    assert Enum.count(results, &match?({:error, {:insufficient_stock, 0}}, &1)) == 100
    assert {:ok, %{available: 0}} = Center.get_resource(ctx.id, "R001")
  end

  test "la misma necesidad no consume recursos dos veces aunque llegue en paralelo", ctx do
    {:ok, _} = Center.register_resource(ctx.id, "R001", "agua", "agua", "litros", 50)

    results =
      1..20
      |> Enum.map(fn _ -> Task.async(fn -> Center.reserve(ctx.id, "R001", 10, "N001") end) end)
      |> Task.await_many(10_000)

    assert Enum.count(results, &match?({:ok, %Movement{}}, &1)) == 1
    assert Enum.count(results, &match?({:ok, {:already_reserved, 10}}, &1)) == 19
    assert {:ok, %{available: 40}} = Center.get_resource(ctx.id, "R001")
  end

  test "valida entradas y salidas", ctx do
    {:ok, _} = Center.register_resource(ctx.id, "R001", "agua", "agua", "litros", 10)

    assert {:error, :invalid_quantity} = Center.deposit(ctx.id, "R001", -5)
    assert {:error, {:insufficient_stock, 10}} = Center.withdraw(ctx.id, "R001", 11)
    assert {:error, :duplicate_code} = Center.register_resource(ctx.id, "R001", "x", "y", "z", 1)
    assert {:ok, %Movement{}} = Center.withdraw(ctx.id, "R001", 10)
    assert {:ok, %{available: 0}} = Center.get_resource(ctx.id, "R001")
    assert {:error, :center_not_found} = Center.deposit("no_existe", "R001", 1)
  end

  test "el estado y las reservas se reconstruyen desde disco tras reiniciar", ctx do
    {:ok, _} = Center.register_resource(ctx.id, "R001", "agua", "agua", "litros", 50)
    {:ok, %Movement{}} = Center.reserve(ctx.id, "R001", 30, "N001")
    {:ok, _} = Center.deposit(ctx.id, "R001", 5, "donacion")

    stop_supervised!(ctx.id)
    assert eventually(fn -> not Center.exists?(ctx.id) end)

    # Sin :zone: debe leerla del encabezado del archivo.
    start_supervised!(Supervisor.child_spec({Center, id: ctx.id, data_dir: ctx.dir}, id: :restarted))

    assert {:ok, %{available: 25, zone: "centro"}} = Center.get_resource(ctx.id, "R001")
    assert {:ok, {:already_reserved, 30}} = Center.reserve(ctx.id, "R001", 30, "N001")
    assert length(Center.history(ctx.id)) == 4
  end

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(10) && eventually(fun, tries - 1)
    end
  end
end
