defmodule Sismo.Pets.ServerTest do
  use ExUnit.Case, async: true

  alias Sismo.Persistence.Writer
  alias Sismo.Pets.Matcher
  alias Sismo.Pets.Server, as: Pets
  alias Sismo.Zones.Server, as: ZonesServer

  setup do
    dir = Path.join(System.tmp_dir!(), "sismo_pets_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    n = System.unique_integer([:positive])
    writer = :"kwriter_#{n}"
    zones = :"kzones_#{n}"
    pets = :"pets_#{n}"
    tasks = :"ktasks_#{n}"

    start_supervised!(Supervisor.child_spec({Writer, name: writer}, id: :writer))
    start_supervised!(Supervisor.child_spec({Task.Supervisor, name: tasks}, id: :tasks))

    start_supervised!(
      Supervisor.child_spec({ZonesServer, name: zones, data_dir: dir, writer: writer}, id: :zones)
    )

    start_supervised!(
      Supervisor.child_spec(
        {Pets, name: pets, data_dir: dir, writer: writer, zones: zones},
        id: :pets
      )
    )

    {:ok, _} = ZonesServer.create_zone("norte", "Norte", "alto", 0, zones)
    {:ok, _} = ZonesServer.create_zone("sur", "Sur", "medio", 0, zones)

    {:ok, p: pets, t: tasks, dir: dir, writer: writer, z: zones}
  end

  defp report(ctx, kind, species, name, color, size, zone) do
    attrs = %{kind: kind, species: species, name: name, color: color, size: size, zone: zone, contact: "3001234567"}
    {:ok, report} = Pets.report(attrs, "voluntario", ctx.p)
    report
  end

  # PT001 perdida perro (norte), PT002 perdida gato (sur),
  # PT003 encontrada perro (norte), PT004 encontrada perro (sur), PT005 encontrada gato (sur)
  defp seed(ctx) do
    report(ctx, "lost", "perro", "Luna", "negra", "mediana", "norte")
    report(ctx, "lost", "gato", "Misi", "gris", "pequeña", "sur")
    report(ctx, "found", "perro", "desconocido", "negro", "mediano", "norte")
    report(ctx, "found", "perro", nil, "blanco", "grande", "sur")
    report(ctx, "found", "gato", nil, "gris", "pequeño", "sur")
  end

  defp find(ctx, opts \\ []), do: Matcher.find([server: ctx.p, task_supervisor: ctx.t] ++ opts)

  test "registra reportes, valida la zona y los asocia a ella", ctx do
    attrs = %{kind: "LOST", species: "Perro", name: "Luna", color: "Negra", size: "Mediana", zone: "Norte", contact: "300"}

    assert {:ok, %{id: "PT001", kind: :perdida, species: "perro", size: :mediano, zone: "norte", status: :activa}} =
             Pets.report(attrs, "voluntario", ctx.p)

    assert {:error, :zone_not_found} = Pets.report(%{attrs | zone: "nope"}, "v", ctx.p)
    assert {:error, {:invalid_field, :kind}} = Pets.report(%{attrs | kind: "x"}, "v", ctx.p)
    assert {:error, :report_not_found} = Pets.get("PT999", ctx.p)

    assert {:ok, %{reports: 1}} = ZonesServer.stats("norte", ctx.z)
  end

  test "match_pets puntúa en paralelo, filtra por umbral y ordena por puntaje", ctx do
    seed(ctx)

    assert [
             %{lost: "PT001", found: "PT003", score: 85},
             %{lost: "PT002", found: "PT005", score: 85}
           ] = find(ctx)

    assert [_, _, %{lost: "PT001", found: "PT004", score: 37}] = find(ctx, threshold: 30)
    assert [%{breakdown: %{species: 30, color: 25, size: 15, zone: 15}}, _] = find(ctx)
  end

  test "una coincidencia propuesta sale de los candidatos hasta que se descarta", ctx do
    seed(ctx)

    assert {:ok, %{lost: %{status: :posible_coincidencia, matched_with: "PT003"}, found: %{status: :posible_coincidencia}}} =
             Pets.propose("PT001", "PT003", ctx.p)

    assert [%{lost: "PT002"}] = find(ctx)

    assert {:ok, _} = Pets.reject("PT001", "PT003", ctx.p)
    assert {:ok, %{status: :activa, matched_with: nil}} = Pets.get("PT001", ctx.p)
    assert length(find(ctx)) == 2
  end

  test "confirmar cierra ambos reportes y no se puede repetir", ctx do
    seed(ctx)

    assert {:ok, %{lost: %{status: :resuelta}, found: %{status: :resuelta}}} =
             Pets.confirm("PT001", "PT003", ctx.p)

    assert {:error, {:already_resolved, "PT001"}} = Pets.confirm("PT001", "PT003", ctx.p)
    assert {:error, {:already_resolved, "PT001"}} = Pets.propose("PT003", "PT001", ctx.p)
    assert {:error, :invalid_pair} = Pets.confirm("PT001", "PT002", ctx.p)
    assert {:error, :report_not_found} = Pets.confirm("PT001", "PT999", ctx.p)

    assert {:ok, [%{id: "PT001"}, %{id: "PT003"}]} = Pets.list([status: "resuelta"], ctx.p)
    assert {:ok, [%{id: "PT001"}, %{id: "PT003"}, %{id: "PT004"}]} = Pets.list([species: "perro"], ctx.p)
    assert %{activa: 3, resuelta: 2, posible_coincidencia: 0} = Pets.counts(ctx.p)
    assert [%{lost: "PT002", found: "PT005"}] = find(ctx)
  end

  describe "concurrencia" do
    test "30 confirmaciones simultáneas del mismo par: solo una se aplica", ctx do
      seed(ctx)

      results =
        1..30
        |> Enum.map(fn _ -> Task.async(fn -> Pets.confirm("PT001", "PT003", ctx.p) end) end)
        |> Task.await_many(10_000)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, {:already_resolved, "PT001"}}, &1)) == 29

      lines = ctx.dir |> Path.join("pets.log") |> File.read!() |> String.split("\n", trim: true)
      assert Enum.count(lines, &String.starts_with?(&1, "pet_resolved|")) == 1
    end

    test "una perdida confirmada con dos encontradas a la vez: solo una gana", ctx do
      seed(ctx)

      tasks = [
        Task.async(fn -> Pets.confirm("PT001", "PT003", ctx.p) end),
        Task.async(fn -> Pets.confirm("PT001", "PT004", ctx.p) end)
      ]

      results = Task.await_many(tasks, 10_000)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, {:already_resolved, "PT001"}}, &1)) == 1
      assert %{resuelta: 2, activa: 3} = Pets.counts(ctx.p)
    end

    test "dos propuestas simultáneas para la misma perdida: solo una se registra", ctx do
      seed(ctx)

      results =
        ["PT003", "PT004"]
        |> Enum.map(fn found -> Task.async(fn -> Pets.propose("PT001", found, ctx.p) end) end)
        |> Task.await_many(10_000)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, {:already_proposed, "PT001"}}, &1)) == 1
    end

    test "50 reportes simultáneos reciben ids únicos y quedan asociados a la zona", ctx do
      results =
        1..50
        |> Enum.map(fn i ->
          Task.async(fn ->
            Pets.report(
              %{kind: "found", species: "perro", color: "negro", size: "mediano", zone: "norte", contact: "c#{i}"},
              "v",
              ctx.p
            )
          end)
        end)
        |> Task.await_many(10_000)

      assert Enum.all?(results, &match?({:ok, _}, &1))
      ids = Enum.map(results, fn {:ok, r} -> r.id end)
      assert length(Enum.uniq(ids)) == 50
      assert {:ok, %{reports: 50}} = ZonesServer.stats("norte", ctx.z)
    end
  end

  test "los reportes, coincidencias y cierres sobreviven al reinicio", ctx do
    seed(ctx)
    {:ok, _} = Pets.propose("PT001", "PT003", ctx.p)
    {:ok, _} = Pets.confirm("PT002", "PT005", ctx.p)

    {:ok, p1} = Pets.get("PT001", ctx.p)
    {:ok, p2} = Pets.get("PT002", ctx.p)

    stop_supervised!(:pets)
    restarted = :"pets_r_#{System.unique_integer([:positive])}"

    start_supervised!(
      Supervisor.child_spec(
        {Pets, name: restarted, data_dir: ctx.dir, writer: ctx.writer, zones: ctx.z},
        id: :pets_restarted
      )
    )

    assert {:ok, ^p1} = Pets.get("PT001", restarted)
    assert {:ok, ^p2} = Pets.get("PT002", restarted)
    assert %{status: :posible_coincidencia, matched_with: "PT003"} = p1
    assert %{status: :resuelta, matched_with: "PT005"} = p2
    assert {:error, {:already_resolved, "PT002"}} = Pets.confirm("PT002", "PT005", restarted)

    attrs = %{kind: "lost", species: "gato", color: "negro", size: "pequeño", zone: "sur", contact: "c"}
    assert {:ok, %{id: "PT006"}} = Pets.report(attrs, "v", restarted)
  end
end
