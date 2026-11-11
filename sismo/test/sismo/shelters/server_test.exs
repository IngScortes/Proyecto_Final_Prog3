# test/sismo/shelters/server_test.exs
defmodule Sismo.Shelters.ServerTest do
  use ExUnit.Case, async: true

  alias Sismo.Persistence.Writer
  alias Sismo.Shelters.Server, as: Shelters

  setup do
    dir = Path.join(System.tmp_dir!(), "sismo_shelter_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    n = System.unique_integer([:positive])
    writer = :"swriter_#{n}"
    start_supervised!(Supervisor.child_spec({Writer, name: writer}, id: :writer))

    {:ok, dir: dir, writer: writer, code: "sh_#{n}"}
  end

  defp open(ctx, capacity) do
    start_supervised!(
      Supervisor.child_spec(
        {Shelters,
         code: ctx.code, name: "Albergue Norte", zone: "norte", capacity: capacity,
         data_dir: ctx.dir, writer: ctx.writer},
        id: :shelter
      )
    )
  end

  test "registra ingresos y salidas y calcula los cupos", ctx do
    open(ctx, 3)

    assert {:ok, %{occupancy: 0, available: 3, capacity: 3}} = Shelters.info(ctx.code)
    assert {:ok, %{occupancy: 1, available: 2}} = Shelters.enter(ctx.code, "111")
    assert {:ok, %{occupancy: 2}} = Shelters.enter(ctx.code, "222")
    assert {:error, :already_inside} = Shelters.enter(ctx.code, "111")
    assert {:ok, %{occupancy: 1}} = Shelters.leave(ctx.code, "111")
    assert {:error, :not_inside} = Shelters.leave(ctx.code, "111")
    assert {:ok, ["222"]} = Shelters.occupants(ctx.code)

    assert Shelters.exists?(String.upcase(ctx.code))
    assert {:error, :shelter_not_found} = Shelters.enter("no_existe", "1")
  end

  test "200 ingresos simultáneos sobre 150 cupos: entran exactamente 150", ctx do
    open(ctx, 150)

    results =
      1..200
      |> Enum.map(fn i -> Task.async(fn -> Shelters.enter(ctx.code, "doc#{i}") end) end)
      |> Task.await_many(10_000)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 150
    assert Enum.count(results, &match?({:error, :shelter_full}, &1)) == 50
    assert {:ok, %{occupancy: 150, available: 0, percent: 100.0}} = Shelters.info(ctx.code)
  end

  test "la misma persona ingresando 30 veces en paralelo entra una sola vez", ctx do
    open(ctx, 100)

    results =
      1..30
      |> Enum.map(fn _ -> Task.async(fn -> Shelters.enter(ctx.code, "111") end) end)
      |> Task.await_many(10_000)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, :already_inside}, &1)) == 29
    assert {:ok, %{occupancy: 1}} = Shelters.info(ctx.code)
  end

  test "la misma persona saliendo 10 veces en paralelo sale una sola vez", ctx do
    open(ctx, 10)
    {:ok, _} = Shelters.enter(ctx.code, "111")
    {:ok, _} = Shelters.enter(ctx.code, "222")

    results =
      1..10
      |> Enum.map(fn _ -> Task.async(fn -> Shelters.leave(ctx.code, "111") end) end)
      |> Task.await_many(10_000)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, :not_inside}, &1)) == 9
    assert {:ok, %{occupancy: 1}} = Shelters.info(ctx.code)
  end

  test "entradas y salidas mezcladas nunca superan la capacidad", ctx do
    open(ctx, 10)
    Enum.each(1..10, fn i -> {:ok, _} = Shelters.enter(ctx.code, "in#{i}") end)

    leaves = for i <- 1..10, do: Task.async(fn -> Shelters.leave(ctx.code, "in#{i}") end)
    enters = for i <- 1..10, do: Task.async(fn -> Shelters.enter(ctx.code, "new#{i}") end)

    leave_results = Task.await_many(leaves, 10_000)
    enter_results = Task.await_many(enters, 10_000)

    assert Enum.all?(leave_results, &match?({:ok, _}, &1))
    entered = Enum.count(enter_results, &match?({:ok, _}, &1))

    assert {:ok, %{occupancy: occupancy}} = Shelters.info(ctx.code)
    assert occupancy == entered
    assert occupancy <= 10
  end

  test "asocia recursos y necesidades sin duplicar", ctx do
    open(ctx, 10)

    assert {:ok, %{resources: ["R001"]}} = Shelters.link(ctx.code, :resource, "R001")
    assert {:error, :already_linked} = Shelters.link(ctx.code, :resource, "R001")
    assert {:ok, %{needs: ["N001"]}} = Shelters.link(ctx.code, :need, "N001")
    assert {:error, :invalid_kind} = Shelters.link(ctx.code, :otra, "x")
  end

  test "el estado sobrevive al reinicio y los datos del encabezado vienen del archivo", ctx do
    open(ctx, 5)
    {:ok, _} = Shelters.enter(ctx.code, "111")
    {:ok, _} = Shelters.enter(ctx.code, "222")
    {:ok, _} = Shelters.leave(ctx.code, "111")
    {:ok, _} = Shelters.link(ctx.code, :resource, "R001")

    stop_supervised!(:shelter)
    assert eventually(fn -> not Shelters.exists?(ctx.code) end)

    # Sin nombre, zona ni capacidad: debe leerlos del encabezado.
    start_supervised!(
      Supervisor.child_spec(
        {Shelters, code: ctx.code, data_dir: ctx.dir, writer: ctx.writer},
        id: :restarted
      )
    )

    assert {:ok, %{name: "Albergue Norte", zone: "norte", capacity: 5, occupancy: 1, resources: ["R001"]}} =
             Shelters.info(ctx.code)

    assert {:ok, ["222"]} = Shelters.occupants(ctx.code)
    assert {:error, :already_inside} = Shelters.enter(ctx.code, "222")
    assert {:ok, %{occupancy: 2}} = Shelters.enter(ctx.code, "111")
  end

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(10) && eventually(fun, tries - 1)
    end
  end
end
