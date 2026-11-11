defmodule Sismo.People.ServerTest do
  use ExUnit.Case, async: true

  alias Sismo.People.Server, as: People
  alias Sismo.Persistence.Writer
  alias Sismo.Zones.Server, as: ZonesServer

  setup do
    dir = Path.join(System.tmp_dir!(), "sismo_people_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    n = System.unique_integer([:positive])
    writer = :"pwriter_#{n}"
    zones = :"pzones_#{n}"
    people = :"people_#{n}"

    start_supervised!(Supervisor.child_spec({Writer, name: writer}, id: :writer))

    start_supervised!(
      Supervisor.child_spec({ZonesServer, name: zones, data_dir: dir, writer: writer}, id: :zones)
    )

    start_supervised!(
      Supervisor.child_spec(
        {People, name: people, data_dir: dir, writer: writer, zones: zones},
        id: :people
      )
    )

    {:ok, _} = ZonesServer.create_zone("norte", "Norte", "alto", 0, zones)
    {:ok, _} = ZonesServer.create_zone("sur", "Sur", "medio", 0, zones)

    {:ok, p: people, dir: dir, writer: writer, z: zones}
  end

  defp report(ctx, doc, name, zone \\ "norte", status \\ "reportada") do
    {:ok, person} = People.report(doc, name, 30, zone, status, "ciudadano", ctx.p)
    person
  end

  test "registra personas, valida la zona y rechaza duplicados", ctx do
    assert {:ok, %{id: "P001", document: "1001", status: :localizada, zone: "norte"}} =
             People.report(" 1001 ", "Andrés", 30, "Norte", "localizada", "ciudadano", ctx.p)

    assert {:error, :duplicate_document} = People.report("1001", "Otro", 1, "norte", "reportada", "x", ctx.p)
    assert {:error, :zone_not_found} = People.report("2", "Ana", 1, "nope", "reportada", "x", ctx.p)
    assert {:error, {:invalid_field, :status}} = People.report("3", "Ana", 1, "norte", "xx", "x", ctx.p)
    assert {:error, :invalid_age} = People.report("4", "Ana", -5, "norte", "reportada", "x", ctx.p)
    assert {:error, :person_not_found} = People.get("999", ctx.p)

    assert {:ok, %{name: "Andrés"}} = People.get("1001", ctx.p)
    assert %{localizada: 1} = People.counts(ctx.p)
  end

  test "cambia de estado con transiciones válidas y conserva el historial", ctx do
    report(ctx, "1001", "Andrés")

    assert {:ok, %{status: :localizada}} = People.set_status("1001", "localizada", "laura", ctx.p)
    assert {:ok, %{status: :en_albergue}} = People.set_status("1001", "en_albergue", "voluntario", ctx.p)

    assert {:error, {:invalid_transition, :en_albergue, :reportada}} =
             People.set_status("1001", "reportada", "x", ctx.p)

    assert {:error, :person_not_found} = People.set_status("999", "localizada", "x", ctx.p)

    assert {:ok, history} = People.history("1001", ctx.p)
    assert Enum.map(history, &elem(&1, 0)) == [:reportada, :localizada, :en_albergue]
  end

  test "busca por nombre, documento, zona y estado", ctx do
    report(ctx, "1", "Andrés Pérez", "norte", "localizada")
    report(ctx, "2", "Ana Gómez", "sur", "reportada")

    assert {:ok, [%{document: "1"}]} = People.search([name: "andres"], ctx.p)
    assert {:ok, [%{document: "2"}]} = People.search([document: "2"], ctx.p)
    assert {:ok, [%{document: "2"}]} = People.search([zone: "sur"], ctx.p)
    assert {:ok, [%{document: "1"}]} = People.search([status: "localizada"], ctx.p)
    assert {:error, {:invalid_filter, :color}} = People.search([color: "x"], ctx.p)
  end

  test "mensajes familiares: se guardan, se listan y se marcan", ctx do
    report(ctx, "1001", "Andrés")

    assert {:ok, %{id: "M001", status: :pendiente, to_document: "1001"}} =
             People.send_message("mamá", "1001", "Estoy bien, estoy en el albergue norte", ctx.p)

    assert {:ok, %{id: "M002"}} = People.send_message("papá", " 1001 ", "Te busco", ctx.p)
    assert {:error, {:invalid_field, :content}} = People.send_message("papá", "1001", " ", ctx.p)

    assert [%{id: "M001"}, %{id: "M002"}] = People.messages_for("1001", ctx.p)
    assert [] = People.messages_for("999", ctx.p)

    assert {:ok, %{status: :entregado}} = People.mark_delivered("M001", ctx.p)
    assert {:error, {:already, :entregado}} = People.mark_delivered("M001", ctx.p)
    assert {:ok, %{status: :pendiente}} = People.mark_pending("M001", ctx.p)
    assert {:error, :message_not_found} = People.mark_delivered("M999", ctx.p)
  end

  test "un proceso suscrito recibe los mensajes de su documento", ctx do
    assert :ok = People.watch("1001", self(), ctx.p)
    assert :ok = People.watch("1001", self(), ctx.p)
    assert {:error, {:invalid_field, :document}} = People.watch(" ", self(), ctx.p)

    {:ok, _} = People.send_message("mamá", "1001", "Estoy bien", ctx.p)
    {:ok, _} = People.send_message("mamá", "2002", "Otro destino", ctx.p)

    assert_receive {:family_message, %{id: "M001", content: "Estoy bien", to_document: "1001"}}
    refute_receive {:family_message, _}, 100
  end

  test "si el suscriptor muere, el servidor sigue funcionando", ctx do
    parent = self()

    pid =
      spawn(fn ->
        :ok = People.watch("1001", self(), ctx.p)
        send(parent, :watching)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :watching
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}

    assert {:ok, %{id: "M001"}} = People.send_message("mamá", "1001", "Hola", ctx.p)
    assert {:ok, %{id: "M002"}} = People.send_message("mamá", "1001", "Sigues ahí", ctx.p)
  end

  describe "concurrencia" do
    test "50 reportes simultáneos del mismo documento: solo uno se registra", ctx do
      results =
        1..50
        |> Enum.map(fn i ->
          Task.async(fn -> People.report("1001", "Andrés #{i}", 30, "norte", "reportada", "x", ctx.p) end)
        end)
        |> Task.await_many(10_000)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, :duplicate_document}, &1)) == 49

      lines = ctx.dir |> Path.join("people.log") |> File.read!() |> String.split("\n", trim: true)
      assert length(lines) == 1
    end

    test "100 documentos distintos en paralelo reciben ids únicos", ctx do
      results =
        1..100
        |> Enum.map(fn i ->
          Task.async(fn -> People.report("doc#{i}", "Persona #{i}", 20, "sur", "reportada", "x", ctx.p) end)
        end)
        |> Task.await_many(10_000)

      assert Enum.all?(results, &match?({:ok, _}, &1))
      ids = Enum.map(results, fn {:ok, p} -> p.id end)
      assert length(Enum.uniq(ids)) == 100
      assert %{reportada: 100} = People.counts(ctx.p)
    end

    test "20 cambios simultáneos al mismo estado: solo uno se aplica", ctx do
      report(ctx, "1001", "Andrés")

      results =
        1..20
        |> Enum.map(fn _ -> Task.async(fn -> People.set_status("1001", "localizada", "x", ctx.p) end) end)
        |> Task.await_many(10_000)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, {:invalid_transition, :localizada, :localizada}}, &1)) == 19
      assert {:ok, history} = People.history("1001", ctx.p)
      assert length(history) == 2
    end

    test "mensajes simultáneos reciben ids únicos y todos se entregan al suscriptor", ctx do
      :ok = People.watch("1001", self(), ctx.p)

      results =
        1..30
        |> Enum.map(fn i -> Task.async(fn -> People.send_message("f#{i}", "1001", "msg #{i}", ctx.p) end) end)
        |> Task.await_many(10_000)

      assert Enum.all?(results, &match?({:ok, _}, &1))
      assert length(Enum.uniq(Enum.map(results, fn {:ok, m} -> m.id end))) == 30
      assert length(People.messages_for("1001", ctx.p)) == 30

      for _ <- 1..30, do: assert_receive({:family_message, _}, 1_000)
    end
  end

  test "personas, historial y mensajes sobreviven al reinicio", ctx do
    report(ctx, "1001", "Andrés | Pérez", "norte", "reportada")
    {:ok, _} = People.set_status("1001", "localizada", "laura", ctx.p)
    {:ok, _} = People.send_message("mamá", "1001", "línea1\nlínea2", ctx.p)
    {:ok, _} = People.mark_delivered("M001", ctx.p)

    {:ok, person_before} = People.get("1001", ctx.p)
    [message_before] = People.messages_for("1001", ctx.p)

    stop_supervised!(:people)
    restarted = :"people_r_#{System.unique_integer([:positive])}"

    start_supervised!(
      Supervisor.child_spec(
        {People, name: restarted, data_dir: ctx.dir, writer: ctx.writer, zones: ctx.z},
        id: :people_restarted
      )
    )

    assert {:ok, ^person_before} = People.get("1001", restarted)
    assert [^message_before] = People.messages_for("1001", restarted)
    assert %{status: :entregado} = message_before

    assert {:ok, %{id: "P002"}} = People.report("1002", "Ana", 5, "sur", "reportada", "x", restarted)
    assert {:ok, %{id: "M002"}} = People.send_message("papá", "1001", "Hola", restarted)
  end
end
