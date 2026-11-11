defmodule Sismo.CLI.CommandsTest do
  # Usa los servidores reales de la aplicación (con datos en una carpeta temporal),
  # así que no puede ser async y cada prueba usa nombres únicos.
  use ExUnit.Case, async: false

  alias Sismo.CLI
  alias Sismo.CLI.Commands
  alias Sismo.Resources.Center
  alias Sismo.Zones.Server, as: Zones

  defp uniq, do: System.unique_integer([:positive])

  defp ok!(state, line) do
    assert {:ok, text, state} = Commands.run(state, line)
    {text, state}
  end

  defp err!(state, line) do
    assert {:error, text, state} = Commands.run(state, line)
    {text, state}
  end

  defp login(role, name, zone) do
    {_text, state} = ok!(Commands.new(), "connect #{name} 1234 #{role} #{zone}")
    state
  end

  defp id_of(text, prefix), do: ~r/#{prefix}\d+/ |> Regex.run(text) |> hd()

  test "exige conexión, respeta los roles y valida las entradas" do
    n = uniq()

    {msg, _} = err!(Commands.new(), "register_zone z#{n} Zona alto")
    assert msg =~ "conectarte"

    citizen = login("ciudadano", "c#{n}", "z#{n}")
    {msg, citizen} = err!(citizen, "register_zone z#{n} Zona alto")
    assert msg =~ "permiso"
    {msg, citizen} = err!(citizen, "comando_raro")
    assert msg =~ "desconocido"

    {_, citizen} = ok!(citizen, "disconnect")
    assert citizen.user == nil
    {msg, _} = err!(citizen, "disconnect")
    assert msg =~ "conectarte"
    {msg, _} = err!(Commands.new(), "connect c#{n} 9999")
    assert msg =~ "Credenciales"

    boss = login("coordinador", "b#{n}", "z#{n}")
    {_, boss} = ok!(boss, "register_zone z#{n} Zona alto")
    {msg, boss} = err!(boss, "register_need agua abc alta z#{n} x")
    assert msg =~ "Cantidad"
    {msg, boss} = err!(boss, ~s(register_need agua 5 alta z#{n} "sin cerrar))
    assert msg =~ "Comillas"
    {msg, _} = err!(boss, "register_need agua 5")
    assert msg =~ "Uso:"
  end

  test "flujo del enunciado: 30 y 25 litros contra 50 con dos usuarios simultáneos" do
    n = uniq()
    s = login("coordinador", "laura#{n}", "z#{n}")
    {_, s} = ok!(s, "register_zone z#{n} Centro critico")
    {_, s} = ok!(s, "register_resource R#{n} agua#{n} 50 litros centro_#{n}")
    {t1, s} = ok!(s, ~s(register_need agua 30 critica z#{n} "Punto de atención sector 3"))
    {t2, _s} = ok!(s, "register_need agua 25 alta z#{n} otro punto")
    {a, b} = {id_of(t1, "N"), id_of(t2, "N")}

    results =
      CLI.parallel([
        ["connect ana#{n} 1234 coordinador z#{n}", "assign_resource #{a} agua#{n} 30"],
        ["connect beto#{n} 1234 coordinador z#{n}", "assign_resource #{b} agua#{n} 25"]
      ])

    statuses = Enum.map(results, fn outputs -> outputs |> List.last() |> elem(0) end)
    assert Enum.sort(statuses) == [:error, :ok]

    {:ok, resource} = Center.get_resource("centro_#{n}", "R#{n}")
    assert resource.available in [20, 25]
  end

  test "ingreso y salida de albergue actualizan el estado de la persona" do
    n = uniq()
    s = login("coordinador", "lau#{n}", "z#{n}")
    {_, s} = ok!(s, "register_zone z#{n} Zona alto")
    {_, s} = ok!(s, ~s(register_shelter a#{n} "Albergue Norte" z#{n} 1))
    {_, s} = ok!(s, "register_shelter b#{n} Otro z#{n} 5")
    {_, s} = ok!(s, ~s(report_person d#{n}1 "Andrés Pérez" z#{n} reportada))
    {_, s} = ok!(s, "report_person d#{n}2 Ana z#{n} reportada")

    {_, s} = ok!(s, "register_entry a#{n} d#{n}1")
    {text, s} = ok!(s, "find_person d#{n}1")
    assert text =~ "en_albergue"

    {text, s} = ok!(s, "check_shelter a#{n}")
    assert text =~ "1/1"

    {msg, s} = err!(s, "register_entry b#{n} d#{n}1")
    assert msg =~ "a#{n}"
    {msg, s} = err!(s, "register_entry a#{n} d#{n}2")
    assert msg =~ "lleno"
    {text, s} = ok!(s, "find_person d#{n}2")
    refute text =~ "en_albergue"

    {_, s} = ok!(s, "register_exit a#{n} d#{n}1")
    {text, s} = ok!(s, "find_person d#{n}1")
    assert text =~ "localizada"
    {_, _s} = ok!(s, "register_entry a#{n} d#{n}2")
  end

  test "mensajes familiares y coincidencia de mascotas" do
    n = uniq()
    s = login("coordinador", "lau#{n}", "z#{n}")
    {_, s} = ok!(s, "register_zone z#{n} Zona alto")
    {_, s} = ok!(s, "report_person p#{n} Andrés z#{n} localizada")

    {text, s} = ok!(s, ~s(send_family_message p#{n} "Estoy bien, estoy en el albergue norte"))
    mid = id_of(text, "M")
    {text, s} = ok!(s, "list_family_messages p#{n}")
    assert text =~ "Estoy bien"
    assert text =~ "pendiente"

    {_, s} = ok!(s, "mark_message #{mid} entregado")
    {text, s} = ok!(s, "list_family_messages p#{n}")
    assert text =~ "entregado"
    {msg, s} = err!(s, "mark_message #{mid} entregado")
    assert msg =~ "Ya está en estado"

    species = "especie#{n}"
    {t1, s} = ok!(s, ~s(report_pet lost #{species} "Luna" negra mediana z#{n} 3001234567))
    {t2, s} = ok!(s, "report_pet found #{species} desconocido negra mediano z#{n} 3009999999")
    {lost, found} = {id_of(t1, "PT"), id_of(t2, "PT")}

    {text, s} = ok!(s, "match_pets")
    assert text =~ lost
    assert text =~ found
    assert text =~ "85"

    {_, s} = ok!(s, "confirm_match #{lost} #{found}")
    {msg, s} = err!(s, "confirm_match #{lost} #{found}")
    assert msg =~ "ya fue resuelto"

    {text, s} = ok!(s, "match_pets")
    refute text =~ lost
    {text, _s} = ok!(s, "list_pets especie=#{species} estado=resuelta")
    assert text =~ lost
  end

  test "20 usuarios conectados a la vez registran necesidades sin repetir ids" do
    n = uniq()
    {:ok, _} = Zones.create_zone("z#{n}", "Zona", "alto")

    scripts =
      for i <- 1..20 do
        [
          "connect u#{n}x#{i} 1234 ciudadano z#{n}",
          ~s(register_need agua 1 media z#{n} "necesidad #{i}")
        ]
      end

    ids =
      scripts
      |> CLI.parallel()
      |> Enum.map(fn outputs ->
        {:ok, text} = List.last(outputs)
        id_of(text, "N")
      end)

    assert length(Enum.uniq(ids)) == 20
    assert {:ok, %{needs: 20}} = Zones.stats("z#{n}")
  end

  test "summary, pending_needs y critical_resources" do
    n = uniq()
    s = login("coordinador", "lau#{n}", "z#{n}")
    {_, s} = ok!(s, "register_zone z#{n} Zona critico 100")
    {_, s} = ok!(s, "register_resource R#{n} suero#{n} 3 unidades centro_#{n}")
    {text, s} = ok!(s, "register_need transporte 7 critica z#{n} ambulancia")
    id = id_of(text, "N")

    {text, s} = ok!(s, "pending_needs")
    assert text =~ id

    {text, s} = ok!(s, "critical_resources")
    assert text =~ "transporte"
    assert text =~ "centro_#{n}"

    {text, s} = ok!(s, "zone_status z#{n}")
    assert text =~ "nivel critico"

    {text, s} = ok!(s, "summary")
    assert text =~ "RESUMEN GLOBAL"
    assert text =~ "z#{n}"

    {text, _s} = ok!(s, "activity")
    assert text =~ "register_need"
  end

  test "transferencias entre centros, entradas y salidas de inventario" do
    n = uniq()
    s = login("coordinador", "lau#{n}", "z#{n}")
    {_, s} = ok!(s, "register_zone z#{n} Zona alto")
    {_, s} = ok!(s, "register_resource R#{n} agua#{n} 50 litros origen_#{n}")

    {_, s} = ok!(s, "transfer_resource R#{n} origen_#{n} destino_#{n} 30")
    {text, s} = ok!(s, "list_resources zona=z#{n}")
    assert text =~ "origen_#{n}"
    assert text =~ "destino_#{n}"

    {msg, s} = err!(s, "transfer_resource R#{n} origen_#{n} destino_#{n} 99")
    assert msg =~ "Stock insuficiente"

    {text, s} = ok!(s, "stock_in origen_#{n} R#{n} 5")
    assert text =~ "25"
    {msg, s} = err!(s, "stock_out origen_#{n} R#{n} 100")
    assert msg =~ "Stock insuficiente"

    {text, _s} = ok!(s, "resource_history origen_#{n}")
    assert text =~ "transferencia_salida"
  end
end
