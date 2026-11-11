defmodule Sismo.Shelters.ShelterSupervisorTest do
  use ExUnit.Case, async: true

  alias Sismo.Persistence.Writer
  alias Sismo.Shelters.{Report, ShelterSupervisor}
  alias Sismo.Shelters.Server, as: Shelters
  alias Sismo.Zones.Server, as: ZonesServer

  setup do
    dir = Path.join(System.tmp_dir!(), "sismo_shsup_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    n = System.unique_integer([:positive])
    writer = :"hwriter_#{n}"
    zones = :"hzones_#{n}"
    sup = :"hsup_#{n}"

    start_supervised!(Supervisor.child_spec({Writer, name: writer}, id: :writer))

    start_supervised!(
      Supervisor.child_spec({ZonesServer, name: zones, data_dir: dir, writer: writer}, id: :zones)
    )

    start_supervised!(Supervisor.child_spec({ShelterSupervisor, name: sup}, id: :sup))

    {:ok, _} = ZonesServer.create_zone("norte", "Norte", "alto", 0, zones)
    {:ok, _} = ZonesServer.create_zone("sur", "Sur", "medio", 0, zones)

    {:ok, n: n, dir: dir, writer: writer, z: zones, sup: sup}
  end

  defp shelter_code(ctx, suffix), do: "h#{ctx.n}_#{suffix}"

  defp open(ctx, suffix, zone, capacity, name \\ nil) do
    ShelterSupervisor.open_shelter(
      shelter_code(ctx, suffix),
      name || "Albergue #{suffix}",
      zone,
      capacity,
      supervisor: ctx.sup,
      zones: ctx.z,
      data_dir: ctx.dir,
      writer: ctx.writer
    )
  end

  test "abre un albergue, valida los datos y la zona, y lo asocia a ella", ctx do
    a = shelter_code(ctx, "a")

    assert {:ok, ^a} = open(ctx, "a", "Norte", 150)
    assert {:ok, %{capacity: 150, zone: "norte", occupancy: 0}} = Shelters.info(a)
    assert {:ok, %{shelters: 1}} = ZonesServer.stats("norte", ctx.z)

    assert {:error, :zone_not_found} = open(ctx, "b", "nope", 10)
    assert {:error, :already_exists} = open(ctx, "a", "norte", 10)
    assert {:error, :invalid_capacity} = open(ctx, "c", "norte", 0)
    assert {:error, {:invalid_field, :name}} = open(ctx, "d", "norte", 10, " ")

    refute Shelters.exists?(shelter_code(ctx, "b"))
    refute Shelters.exists?(shelter_code(ctx, "c"))
    assert {:ok, %{shelters: 1}} = ZonesServer.stats("norte", ctx.z)
  end

  test "el reporte ordena por porcentaje de ocupación y filtra por zona", ctx do
    {:ok, a} = open(ctx, "a", "norte", 10)
    {:ok, b} = open(ctx, "b", "norte", 10)
    {:ok, c} = open(ctx, "c", "sur", 100)

    Enum.each(1..5, fn i -> {:ok, _} = Shelters.enter(a, "a#{i}") end)
    Enum.each(1..10, fn i -> {:ok, _} = Shelters.enter(b, "b#{i}") end)
    Enum.each(1..20, fn i -> {:ok, _} = Shelters.enter(c, "c#{i}") end)

    codes = [a, b, c]

    
    assert [^b, ^a, ^c] = Report.top_occupied(3, codes: codes) |> Enum.map(& &1.code)
    assert [^b] = Report.top_occupied(1, codes: codes) |> Enum.map(& &1.code)
    assert [^c] = Report.all(codes: codes, zone: "SUR") |> Enum.map(& &1.code)

    # El albergue lleno no aparece entre los que tienen cupo.
    assert [%{code: ^c, available: 80}, %{code: ^a, available: 5}] =
             Report.with_space(codes: codes)
  end

  test "restore_all levanta los albergues desde disco con su ocupación", ctx do
    {:ok, a} = open(ctx, "a", "norte", 10)
    {:ok, _} = Shelters.enter(a, "111")

    stop_supervised!(:sup)
    assert eventually(fn -> not Shelters.exists?(a) end)

    sup2 = :"hsup2_#{ctx.n}"
    start_supervised!(Supervisor.child_spec({ShelterSupervisor, name: sup2}, id: :sup2))

    assert [{^a, {:ok, _pid}}] = ShelterSupervisor.restore_all(ctx.dir, sup2)
    assert {:ok, %{occupancy: 1, capacity: 10}} = Shelters.info(a)
    assert {:error, :already_inside} = Shelters.enter(a, "111")
  end

  test "reconcile_links repara asociaciones faltantes y es idempotente", ctx do
    {:ok, a} = open(ctx, "a", "norte", 10)

    # Un servidor de zonas "nuevo" que no conoce el enlace.
    z2 = :"hzones2_#{ctx.n}"

    start_supervised!(
      Supervisor.child_spec(
        {ZonesServer, name: z2, data_dir: Path.join(ctx.dir, "z2"), writer: ctx.writer},
        id: :zones2
      )
    )

    {:ok, _} = ZonesServer.create_zone("norte", "Norte", "alto", 0, z2)
    assert {:ok, %{shelters: 0}} = ZonesServer.stats("norte", z2)

    assert :ok = ShelterSupervisor.reconcile_links(z2, [a])
    assert {:ok, %{shelters: 1}} = ZonesServer.stats("norte", z2)

    assert :ok = ShelterSupervisor.reconcile_links(z2, [a])
    assert {:ok, %{shelters: 1}} = ZonesServer.stats("norte", z2)
  end

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(10) && eventually(fun, tries - 1)
    end
  end
end
