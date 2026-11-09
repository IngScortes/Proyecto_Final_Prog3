defmodule Sismo.Users.ServerTest do
  use ExUnit.Case, async: true

  alias Sismo.Activity.Log
  alias Sismo.Persistence.Writer
  alias Sismo.Users.Server, as: Users

  @laura %{role: "coordinador", zone: "centro", full_name: "Laura Gómez"}

  # Cada test levanta su propia pila aislada, con nombres únicos y directorio temporal.
  setup do
  dir = Path.join(System.tmp_dir!(), "sismo_test_#{System.unique_integer([:positive])}")
  File.mkdir_p!(dir)
  on_exit(fn -> File.rm_rf(dir) end)

  id = System.unique_integer([:positive])
  ctx = %{writer: :"writer_#{id}", log: :"log_#{id}", users: :"users_#{id}", dir: dir}

  start_supervised!(Supervisor.child_spec({Writer, name: ctx.writer}, id: :writer))

  start_supervised!(
    Supervisor.child_spec({Log, name: ctx.log, data_dir: dir, writer: ctx.writer}, id: :log)
  )

  start_supervised!(
    Supervisor.child_spec(
      {Users, name: ctx.users, data_dir: dir, writer: ctx.writer, activity: ctx.log},
      id: :users
    )
  )

  {:ok, ctx}
end

  describe "conexión" do
    test "registra automáticamente, luego autentica y valida la contraseña", ctx do
      assert {:ok, :registered, %{username: "laura", role: :coordinador, zone: "centro"}} =
               connect(ctx, "laura", "1234", @laura)

      assert :ok = Users.disconnect("laura", ctx.users)
      assert {:error, :invalid_credentials} = connect(ctx, "laura", "9999")
      assert {:ok, :authenticated, %{username: "laura"}} = connect(ctx, "laura", "1234")
      assert {:error, :already_connected} = connect(ctx, "laura", "1234")
    end

    test "valida los datos antes de modificar el estado", ctx do
      assert {:error, {:invalid_field, :role}} = connect(ctx, "ana", "1234", %{zone: "norte"})
      assert {:error, {:invalid_field, :password}} = connect(ctx, "ana", "12", %{role: "ciudadano", zone: "norte"})
      assert {:error, {:invalid_field, :username}} = connect(ctx, "a b", "1234", @laura)
      assert {:error, :role_not_self_registrable} = connect(ctx, "root", "1234", %{role: "administrador", zone: "centro"})
      assert Users.user_count(ctx.users) == 0
    end

    test "disconnect sin sesión devuelve error", ctx do
      assert {:error, :not_connected} = Users.disconnect("nadie", ctx.users)
    end
  end

  describe "autorización por rol" do
    test "restringe operaciones según el tipo de usuario", ctx do
      assert {:error, :not_connected} = Users.authorize("laura", :register_zone, ctx.users)

      {:ok, :registered, _} = connect(ctx, "laura", "1234", @laura)
      {:ok, :registered, _} = connect(ctx, "juan", "1234", %{role: "ciudadano", zone: "centro"})

      assert {:ok, %{role: :coordinador}} = Users.authorize("laura", :register_zone, ctx.users)
      assert {:ok, _} = Users.authorize("juan", :report_person, ctx.users)
      assert {:error, :forbidden} = Users.authorize("juan", :register_zone, ctx.users)
      assert {:error, :forbidden} = Users.authorize("juan", :summary, ctx.users)
    end
  end

  describe "concurrencia" do
    test "50 conexiones simultáneas del MISMO usuario nuevo: solo una registra", ctx do
      results =
        1..50
        |> Enum.map(fn _ -> Task.async(fn -> connect(ctx, "laura", "1234", @laura) end) end)
        |> Task.await_many(10_000)

      assert Enum.count(results, &match?({:ok, :registered, _}, &1)) == 1

      assert Enum.all?(results, fn
               {:ok, :registered, _} -> true
               {:ok, :authenticated, _} -> true
               {:error, :already_connected} -> true
               _ -> false
             end)

      assert Users.user_count(ctx.users) == 1
      assert count_lines(ctx) == 1
    end

    test "100 usuarios distintos registrándose en paralelo", ctx do
      results =
        1..100
        |> Enum.map(fn i ->
          Task.async(fn -> connect(ctx, "user_#{i}", "pass#{i}", %{role: "voluntario", zone: "zona_#{rem(i, 5)}"}) end)
        end)
        |> Task.await_many(30_000)

      assert Enum.all?(results, &match?({:ok, :registered, _}, &1))
      assert Users.user_count(ctx.users) == 100
      assert count_lines(ctx) == 100
    end
  end

  describe "sesiones y actividad" do
    test "la sesión se libera cuando el proceso cliente muere", ctx do
      parent = self()

      pid =
        spawn(fn ->
          send(parent, {:res, connect(ctx, "laura", "1234", @laura)})
          receive do: (:stop -> :ok)
        end)

      assert_receive {:res, {:ok, :registered, _}}
      assert Users.connected?("laura", ctx.users)

      Process.exit(pid, :kill)
      assert eventually(fn -> not Users.connected?("laura", ctx.users) end)
      assert {:ok, :authenticated, _} = connect(ctx, "laura", "1234")
    end

    test "registra la actividad del usuario en memoria y en disco", ctx do
  {:ok, :registered, _} = connect(ctx, "juan", "1234", %{role: "ciudadano", zone: "centro"})
  {:error, :forbidden} = Users.authorize("juan", :register_zone, ctx.users)
  :ok = Users.disconnect("juan", ctx.users)

  # 1) Primero el Log: al responder, ya reenvió todo al Writer.
  actions = "juan" |> Log.for_user(ctx.log) |> Enum.map(& &1.action)

  # 2) Después el Writer: al responder, ya escribió todo a disco.
  Writer.flush(ctx.writer)

  assert actions == ["disconnect", "forbidden", "connect"]
  assert ctx.dir |> Path.join("activity.log") |> File.read!() =~ "forbidden"
end
  end

  describe "persistencia" do
    test "los usuarios sobreviven al reinicio del servidor", ctx do
      {:ok, :registered, _} = connect(ctx, "laura", "1234", @laura)
      :ok = Users.disconnect("laura", ctx.users)
      stop_supervised!(:users)

      restarted = :"users_restarted_#{System.unique_integer([:positive])}"

      start_supervised!(
        Supervisor.child_spec(
          {Users, name: restarted, data_dir: ctx.dir, writer: ctx.writer, activity: ctx.log},
          id: :users_restarted
        )
      )

      assert Users.user_count(restarted) == 1
      assert {:error, :invalid_credentials} = Users.connect("laura", "0000", %{}, restarted)
      assert {:ok, :authenticated, %{role: :coordinador}} = Users.connect("laura", "1234", %{}, restarted)
    end

    test "el archivo no guarda la contraseña en claro", ctx do
      {:ok, :registered, _} = connect(ctx, "laura", "clave-secreta", @laura)
      refute ctx.dir |> Path.join("users.db") |> File.read!() =~ "clave-secreta"
    end
  end

  ## Helpers

  defp connect(ctx, username, password, attrs \\ %{}),
    do: Users.connect(username, password, attrs, ctx.users)

  defp count_lines(ctx),
    do: ctx.dir |> Path.join("users.db") |> File.read!() |> String.split("\n", trim: true) |> length()

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(10) && eventually(fun, tries - 1)
    end
  end
end
