defmodule Sismo.Zones.ServerTest do
  use ExUnit.Case, async: true
  alias Sismo.Persistence.Writer
  alias Sismo.Zones.Server, as: Zones

  setup do
    dir = Path.join(System.tmp_dir!(), "sismo_zones_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    id = System.unique_integer([:positive])
    writer = :"zwriter_#{id}"
    zones = :"zones_#{id}"

    start_supervised!(Supervisor.child_spec({Writer, name: writer}, id: :writer))

    start_supervised!(
      Supervisor.child_spec({Zones, name: zones, data_dir: dir, writer: writer}, id: :zones)
    )

    {:ok, z: zones, dir: dir, writer: writer}
  end

  test "crea zonas y rechaza duplicados y datos inválidos", ctx do
    assert {:ok, %{code: "centro", level: :critico}} = Zones.create_zone("centro", "Centro", "critico", 100, ctx.z)
    assert {:error, :duplicate_code} = Zones.create_zone("CENTRO", "Otra", "bajo", 0, ctx.z)
    assert {:error, {:invalid_field, :level}} = Zones.create_zone("norte", "Norte", "xx", 0, ctx.z)
    assert {:error, :invalid_quantity} = Zones.create_zone("norte", "Norte", "alto", -5, ctx.z)
    assert Zones.exists?("centro", ctx.z)
    refute Zones.exists?("norte", ctx.z)
    assert length(Zones.list(ctx.z)) == 1
  end

  test "sectores anidados y estadísticas acumuladas", ctx do
    {:ok, _} = Zones.create_zone("centro", "Centro", "critico", 100, ctx.z)
    {:ok, _} = Zones.add_sector("centro", nil, "s1", "Sector 1", 50, ctx.z)
    {:ok, _} = Zones.add_sector("centro", nil, "s2", "Sector 2", 30, ctx.z)
    {:ok, _} = Zones.add_sector("centro", "s1", "s1a", "Sub 1A", 20, ctx.z)
    {:ok, _} = Zones.add_sector("centro", "s1a", "s1a1", "Sub 1A1", 10, ctx.z)
    {:ok, _} = Zones.add_point("centro", "s1a1", "p1", "Carpa médica", "salud", ctx.z)
    {:ok, _} = Zones.add_point("centro", "s2", "p2", "Acopio", "agua", ctx.z)

    assert {:ok, stats} = Zones.stats("centro", ctx.z)
    assert %{total_affected: 210, sectors: 4, points: 2, depth: 3} = stats

    s1 = Enum.find(stats.tree, &(&1.id == "s1"))
    assert s1.total_affected == 80
  end

  test "errores esperados no modifican el estado", ctx do
    {:ok, _} = Zones.create_zone("centro", "Centro", "alto", 0, ctx.z)
    {:ok, _} = Zones.add_sector("centro", nil, "s1", "S1", 0, ctx.z)

    assert {:error, :zone_not_found} = Zones.add_sector("nope", nil, "s1", "S1", 0, ctx.z)
    assert {:error, :parent_not_found} = Zones.add_sector("centro", "nope", "s2", "S2", 0, ctx.z)
    assert {:error, :duplicate_id} = Zones.add_sector("centro", nil, "s1", "Otra", 0, ctx.z)
    assert {:error, :sector_not_found} = Zones.add_point("centro", "nope", "p1", "P", "k", ctx.z)

    assert {:ok, _} = Zones.add_point("centro", "s1", "p1", "P", "k", ctx.z)
    assert {:error, :duplicate_id} = Zones.add_point("centro", "s1", "p1", "P", "k", ctx.z)
    assert {:ok, %{sectors: 1, points: 1}} = Zones.stats("centro", ctx.z)
  end

  test "asocia albergues, necesidades y reportes sin duplicar", ctx do
    {:ok, _} = Zones.create_zone("centro", "Centro", "alto", 0, ctx.z)

    assert {:ok, _} = Zones.link("centro", :shelter, "A01", ctx.z)
    assert {:error, :already_linked} = Zones.link("centro", :shelter, "A01", ctx.z)
    assert {:ok, _} = Zones.link("centro", :need, "N001", ctx.z)
    assert {:error, :invalid_kind} = Zones.link("centro", :otra_cosa, "x", ctx.z)

    assert {:ok, %{shelters: 1, needs: 1, reports: 0}} = Zones.stats("centro", ctx.z)
  end

  test "overview ordena por nivel de afectación y luego por personas afectadas", ctx do
    {:ok, _} = Zones.create_zone("bajo1", "Bajo", "bajo", 500, ctx.z)
    {:ok, _} = Zones.create_zone("crit1", "Crit 1", "critico", 10, ctx.z)
    {:ok, _} = Zones.create_zone("crit2", "Crit 2", "critico", 90, ctx.z)
    {:ok, _} = Zones.set_level("bajo1", "alto", ctx.z)

    assert Enum.map(Zones.overview(ctx.z), & &1.code) == ["crit2", "crit1", "bajo1"]
  end

  test "las zonas y su jerarquía sobreviven al reinicio", ctx do
    {:ok, _} = Zones.create_zone("centro", "Centro | Norte", "critico", 100, ctx.z)
    {:ok, _} = Zones.add_sector("centro", nil, "s1", "S1", 5, ctx.z)
    {:ok, _} = Zones.add_sector("centro", "s1", "s1a", "S1A", 7, ctx.z)
    {:ok, _} = Zones.add_point("centro", "s1a", "p1", "Punto", "salud", ctx.z)
    {:ok, _} = Zones.link("centro", :shelter, "A01", ctx.z)
    {:ok, _} = Zones.set_level("centro", "alto", ctx.z)
    {:ok, before} = Zones.stats("centro", ctx.z)

    stop_supervised!(:zones)
    restarted = :"zones_r_#{System.unique_integer([:positive])}"

    start_supervised!(
      Supervisor.child_spec(
        {Zones, name: restarted, data_dir: ctx.dir, writer: ctx.writer},
        id: :zones_restarted
      )
    )

    assert {:ok, ^before} = Zones.stats("centro", restarted)
    assert {:ok, %{name: "Centro | Norte", level: :alto}} = Zones.get("centro", restarted)
  end

  describe "concurrencia" do
    test "50 creaciones simultáneas de la misma zona: solo una se registra", ctx do
      results =
        1..50
        |> Enum.map(fn _ -> Task.async(fn -> Zones.create_zone("centro", "Centro", "alto", 0, ctx.z) end) end)
        |> Task.await_many(10_000)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, :duplicate_code}, &1)) == 49

      lines = ctx.dir |> Path.join("zones.log") |> File.read!() |> String.split("\n", trim: true)
      assert length(lines) == 1
    end

    test "20 sectores con el mismo id en paralelo: solo uno entra", ctx do
      {:ok, _} = Zones.create_zone("centro", "Centro", "alto", 0, ctx.z)

      results =
        1..20
        |> Enum.map(fn _ -> Task.async(fn -> Zones.add_sector("centro", nil, "dup", "Dup", 1, ctx.z) end) end)
        |> Task.await_many(10_000)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, :duplicate_id}, &1)) == 19
      assert {:ok, %{sectors: 1}} = Zones.stats("centro", ctx.z)
    end

    test "100 sectores distintos creados en paralelo se registran todos", ctx do
      {:ok, _} = Zones.create_zone("centro", "Centro", "alto", 0, ctx.z)

      results =
        1..100
        |> Enum.map(fn i ->
          Task.async(fn -> Zones.add_sector("centro", nil, "s#{i}", "Sector #{i}", 1, ctx.z) end)
        end)
        |> Task.await_many(10_000)

      assert Enum.all?(results, &match?({:ok, _}, &1))
      assert {:ok, %{sectors: 100, total_affected: 100}} = Zones.stats("centro", ctx.z)
    end
  end
end
