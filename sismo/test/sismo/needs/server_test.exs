defmodule Sismo.Needs.ServerTest do
  use ExUnit.Case, async: true

  alias Sismo.Persistence.Writer
  alias Sismo.Needs.Server, as: Needs
  alias Sismo.Resources.Center
  alias Sismo.Zones.Server, as: ZonesServer

  setup do
    dir = Path.join(System.tmp_dir!(), "sismo_needs_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    n = System.unique_integer([:positive])
    writer = :"nwriter_#{n}"
    zones = :"nzones_#{n}"
    needs = :"needs_#{n}"
    center = "nc_#{n}"

    start_supervised!(Supervisor.child_spec({Writer, name: writer}, id: :writer))

    start_supervised!(
      Supervisor.child_spec({ZonesServer, name: zones, data_dir: dir, writer: writer}, id: :zones)
    )

    start_supervised!(
      Supervisor.child_spec({Center, id: center, zone: "centro", data_dir: dir, writer: writer}, id: :center)
    )

    start_supervised!(
      Supervisor.child_spec(
        {Needs, name: needs, data_dir: dir, writer: writer, zones: zones},
        id: :needs
      )
    )

    {:ok, _} = ZonesServer.create_zone("centro", "Centro", "alto", 0, zones)
    {:ok, _} = Center.register_resource(center, "R001", "agua", "agua", "litros", 50)
    {:ok, _} = Center.register_resource(center, "R002", "agua", "agua", "litros", 100)

    {:ok, n: needs, z: zones, c: center, dir: dir, writer: writer}
  end

  defp register(ctx, type, qty, priority) do
    {:ok, need} = Needs.register(type, qty, priority, "centro", "Punto de atención", "laura", ctx.n)
    need
  end

  defp available(ctx, code) do
    {:ok, resource} = Center.get_resource(ctx.c, code)
    resource.available
  end

  test "registra necesidades, valida la zona y las asocia a ella", ctx do
    assert {:ok, %{id: "N001", status: :pendiente, zone: "centro"}} =
             Needs.register("agua", 30, "critica", "Centro", "Punto sector 3", "laura", ctx.n)

    assert {:error, :zone_not_found} = Needs.register("agua", 5, "alta", "nope", "d", "x", ctx.n)
    assert {:error, {:invalid_field, :type}} = Needs.register("lava", 5, "alta", "centro", "d", "x", ctx.n)
    assert {:error, :invalid_quantity} = Needs.register("agua", 0, "alta", "centro", "d", "x", ctx.n)
    assert {:error, :need_not_found} = Needs.get("N999", ctx.n)

    assert {:ok, %{needs: 1}} = ZonesServer.stats("centro", ctx.z)
  end

  test "flujo del enunciado: 30 y 25 litros contra 50 disponibles, nunca se asignan 55", ctx do
    n1 = register(ctx, "agua", 30, "critica")
    n2 = register(ctx, "agua", 25, "alta")

    results =
      [{n1.id, 30}, {n2.id, 25}]
      |> Enum.map(fn {id, qty} -> Task.async(fn -> Needs.assign(id, ctx.c, "R001", qty, ctx.n) end) end)
      |> Task.await_many(5_000)

    assert Enum.count(results, &match?({:ok, %{status: :asignada}}, &1)) == 1
    assert Enum.count(results, &match?({:error, {:insufficient_stock, _}}, &1)) == 1
    assert available(ctx, "R001") in [20, 25]

    # La necesidad rechazada queda intacta.
    statuses = [n1.id, n2.id] |> Enum.map(fn id -> {:ok, n} = Needs.get(id, ctx.n); n.status end)
    assert Enum.sort(statuses) == [:asignada, :pendiente]
  end

  test "20 asignaciones simultáneas de 10 sobre una necesidad de 50: solo 5 entran", ctx do
    need = register(ctx, "agua", 50, "alta")

    results =
      1..20
      |> Enum.map(fn _ -> Task.async(fn -> Needs.assign(need.id, ctx.c, "R002", 10, ctx.n) end) end)
      |> Task.await_many(10_000)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 5
    assert Enum.count(results, &match?({:error, {:exceeds_remaining, 0}}, &1)) == 15
    assert available(ctx, "R002") == 50

    {:ok, final} = Needs.get(need.id, ctx.n)
    refs = Enum.map(final.allocations, & &1.ref)
    assert Enum.sort(refs) == ["N001:1", "N001:2", "N001:3", "N001:4", "N001:5"]
  end

  test "cancelar devuelve el stock y cierra la necesidad", ctx do
    need = register(ctx, "agua", 30, "alta")
    {:ok, _} = Needs.assign(need.id, ctx.c, "R001", 30, ctx.n)
    assert available(ctx, "R001") == 20

    assert {:ok, %{status: :cancelada}} = Needs.cancel(need.id, ctx.n)
    assert available(ctx, "R001") == 50

    assert {:error, {:invalid_transition, :cancelada, :cancelada}} = Needs.cancel(need.id, ctx.n)
    assert {:error, {:not_assignable, :cancelada}} = Needs.assign(need.id, ctx.c, "R001", 1, ctx.n)
    assert available(ctx, "R001") == 50
  end

  test "una necesidad atendida no vuelve a consumir recursos ni se cancela", ctx do
    need = register(ctx, "agua", 10, "alta")
    {:ok, _} = Needs.assign(need.id, ctx.c, "R001", 10, ctx.n)

    assert {:error, {:invalid_transition, :asignada, :atendida}} = Needs.complete(need.id, ctx.n)
    assert {:ok, %{status: :en_atencion}} = Needs.start_attention(need.id, ctx.n)
    assert {:ok, %{status: :atendida}} = Needs.complete(need.id, ctx.n)

    assert {:error, {:not_assignable, :atendida}} = Needs.assign(need.id, ctx.c, "R001", 1, ctx.n)
    assert {:error, {:invalid_transition, :atendida, :cancelada}} = Needs.cancel(need.id, ctx.n)
    assert available(ctx, "R001") == 40
  end

  test "errores de asignación no modifican la necesidad", ctx do
    need = register(ctx, "agua", 10, "alta")

    assert {:error, :center_not_found} = Needs.assign(need.id, "no_existe", "R001", 5, ctx.n)
    assert {:error, :resource_not_found} = Needs.assign(need.id, ctx.c, "NOPE", 5, ctx.n)
    assert {:error, {:exceeds_remaining, 10}} = Needs.assign(need.id, ctx.c, "R001", 11, ctx.n)
    assert {:error, :invalid_quantity} = Needs.assign(need.id, ctx.c, "R001", -1, ctx.n)
    assert {:error, :need_not_found} = Needs.assign("N999", ctx.c, "R001", 1, ctx.n)

    assert {:ok, %{status: :pendiente, allocations: []}} = Needs.get(need.id, ctx.n)
    assert available(ctx, "R001") == 50
  end

  test "la prioridad ordena la cola y las necesidades cubiertas salen de ella", ctx do
    register(ctx, "agua", 5, "baja")
    register(ctx, "agua", 5, "critica")
    register(ctx, "agua", 5, "alta")
    register(ctx, "agua", 5, "critica")

    assert Enum.map(Needs.queue(ctx.n), & &1.id) == ["N002", "N004", "N003", "N001"]

    {:ok, _} = Needs.assign("N002", ctx.c, "R001", 5, ctx.n)
    {:ok, _} = Needs.assign("N004", ctx.c, "R001", 2, ctx.n)

    assert Enum.map(Needs.queue(ctx.n), & &1.id) == ["N004", "N003", "N001"]
  end

  test "consulta por zona, tipo, prioridad y estado", ctx do
    register(ctx, "agua", 5, "critica")
    register(ctx, "alimentos", 5, "critica")
    register(ctx, "agua", 5, "baja")
    {:ok, _} = Needs.cancel("N003", ctx.n)

    assert {:ok, [%{id: "N001"}, %{id: "N002"}]} = Needs.list([priority: "critica", zone: "centro"], ctx.n)
    assert {:ok, [%{id: "N003"}]} = Needs.list([status: "cancelada"], ctx.n)
    assert {:ok, [%{id: "N001"}]} = Needs.list([type: "agua", status: "pendiente"], ctx.n)
    assert {:error, {:invalid_filter, :color}} = Needs.list([color: "x"], ctx.n)
    assert %{pendiente: 2, cancelada: 1, atendida: 0} = Needs.counts(ctx.n)
  end

  test "50 registros simultáneos reciben ids únicos y quedan asociados a la zona", ctx do
    results =
      1..50
      |> Enum.map(fn _ ->
        Task.async(fn -> Needs.register("agua", 1, "media", "centro", "d", "x", ctx.n) end)
      end)
      |> Task.await_many(10_000)

    assert Enum.all?(results, &match?({:ok, _}, &1))
    ids = Enum.map(results, fn {:ok, need} -> need.id end)
    assert length(Enum.uniq(ids)) == 50
    assert {:ok, %{needs: 50}} = ZonesServer.stats("centro", ctx.z)
  end

  test "las necesidades y sus asignaciones sobreviven al reinicio", ctx do
    need = register(ctx, "agua", 30, "critica")
    {:ok, _} = Needs.assign(need.id, ctx.c, "R001", 10, ctx.n)
    {:ok, _} = Needs.assign(need.id, ctx.c, "R001", 5, ctx.n)
    {:ok, _} = Needs.start_attention(need.id, ctx.n)
    {:ok, before} = Needs.get(need.id, ctx.n)

    stop_supervised!(:needs)
    restarted = :"needs_r_#{System.unique_integer([:positive])}"

    start_supervised!(
      Supervisor.child_spec(
        {Needs, name: restarted, data_dir: ctx.dir, writer: ctx.writer, zones: ctx.z},
        id: :needs_restarted
      )
    )

    assert {:ok, ^before} = Needs.get(need.id, restarted)
    assert %{status: :en_atencion, allocations: [_, _]} = before
    assert {:ok, %{id: "N002"}} = Needs.register("agua", 1, "alta", "centro", "d", "x", restarted)
    assert available(ctx, "R001") == 35
  end
end
