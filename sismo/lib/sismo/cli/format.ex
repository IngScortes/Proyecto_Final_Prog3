defmodule Sismo.CLI.Format do
  @moduledoc "Texto para la consola: tablas, resúmenes y mensajes de error en español."
  alias Sismo.Needs.Need

  ## Errores (todas las cláusulas juntas)

  def error(:not_connected), do: "Debes conectarte primero: connect usuario contraseña tipo zona"
  def error(:forbidden), do: "Tu tipo de usuario no tiene permiso para esta operación"
  def error(:invalid_credentials), do: "Credenciales inválidas"
  def error(:already_connected), do: "Ese usuario ya tiene una sesión abierta"
  def error(:role_not_self_registrable), do: "El rol administrador no se puede auto-registrar"
  def error(:unbalanced_quotes), do: "Comillas sin cerrar"
  def error({:invalid_field, field}), do: "Campo inválido: #{field}"
  def error(:invalid_quantity), do: "Cantidad inválida: debe ser un número entero válido"
  def error(:invalid_capacity), do: "Capacidad inválida: debe ser un entero mayor que 0"
  def error(:invalid_age), do: "Edad inválida: debe estar entre 0 y 120"
  def error(:invalid_kind), do: "Tipo inválido"
  def error(:invalid_status), do: "Estado inválido para esta operación"
  def error(:zone_not_found), do: "La zona no existe"
  def error(:zones_unavailable), do: "El servicio de zonas no está disponible"
  def error(:parent_not_found), do: "El sector padre no existe"
  def error(:sector_not_found), do: "El sector no existe"
  def error(:duplicate_code), do: "Ya existe un registro con ese código"
  def error(:duplicate_id), do: "Ya existe un elemento con ese identificador"
  def error(:duplicate_document), do: "Ya hay una persona registrada con ese documento"
  def error(:need_not_found), do: "La necesidad no existe"
  def error(:person_not_found), do: "La persona no está registrada (usa report_person)"
  def error(:message_not_found), do: "El mensaje no existe"
  def error(:report_not_found), do: "El reporte no existe"
  def error(:center_not_found), do: "El centro no existe"
  def error(:shelter_not_found), do: "El albergue no existe"
  def error(:resource_not_found), do: "No se encontró ese recurso"
  def error({:insufficient_stock, n}), do: "Stock insuficiente: disponible #{n}"
  def error({:exceeds_remaining, n}), do: "La cantidad supera lo que falta cubrir (#{n})"
  def error({:not_assignable, s}), do: "La necesidad está #{s} y no admite más asignaciones"
  def error({:invalid_transition, a, b}), do: "Transición no permitida: #{a} -> #{b}"
  def error(:shelter_full), do: "El albergue está lleno"
  def error(:already_inside), do: "La persona ya está en ese albergue"
  def error(:not_inside), do: "La persona no está en ese albergue"
  def error({:in_other_shelter, code}), do: "La persona ya está registrada en el albergue #{code}"
  def error(:already_linked), do: "Ya estaba asociado"
  def error(:already_exists), do: "Ya existe"
  def error({:already_resolved, id}), do: "El reporte #{id} ya fue resuelto"
  def error({:already_proposed, id}), do: "El reporte #{id} ya tiene una coincidencia propuesta"
  def error({:matched_with_other, id}), do: "El reporte #{id} está emparejado con otro"
  def error(:not_proposed), do: "Esos reportes no tienen una coincidencia propuesta"
  def error(:invalid_pair), do: "Hay que indicar un reporte de perdida y uno de encontrada"
  def error({:already, status}), do: "Ya está en estado #{status}"
  def error({:invalid_filter, key}), do: "Filtro no válido: #{key}"
  def error(:invalid_filters), do: "Filtros mal formados"
  def error(:same_center), do: "El origen y el destino son el mismo centro"
  def error({:transfer_failed, reason}), do: "Transferencia fallida: " <> error(reason)
  def error({:persist_failed, _}), do: "No se pudo guardar en disco; no se hizo ningún cambio"
  def error({:status_update_failed, reason}),
    do: "No se pudo actualizar el estado de la persona (" <> error(reason) <> "); se revirtió el ingreso"

  def error({:unavailable, _}), do: "Un servicio no respondió; intenta de nuevo"
  def error({:usage, usage}), do: "Uso: #{usage}"
  def error(other), do: "Error: #{inspect(other)}"

  ## Tablas

  def table(_headers, []), do: "(sin resultados)"

  def table(headers, rows) do
    all = [headers | Enum.map(rows, fn row -> Enum.map(row, &cell/1) end)]

    widths =
      Enum.zip_with(all, fn column -> column |> Enum.map(&String.length/1) |> Enum.max() end)

    [head | body] = Enum.map(all, &render_row(&1, widths))
    sep = widths |> Enum.map(&String.duplicate("-", &1)) |> Enum.join("  ")
    Enum.join([head, sep | body], "\n")
  end

  defp render_row(row, widths) do
    row
    |> Enum.zip(widths)
    |> Enum.map(fn {text, width} -> String.pad_trailing(text, width) end)
    |> Enum.join("  ")
    |> String.trim_trailing()
  end

  defp cell(value) do
    text = value |> to_string() |> String.replace(~r/\s+/, " ")
    if String.length(text) > 60, do: String.slice(text, 0, 59) <> "…", else: text
  end

  ## Listados

  def needs(list) do
    table(
      ["ID", "Tipo", "Cant", "Asig", "Falta", "Prioridad", "Estado", "Zona", "Descripción"],
      Enum.map(list, fn n ->
        [n.id, n.type, n.quantity, Need.assigned(n), Need.remaining(n), n.priority, n.status, n.zone, n.description]
      end)
    )
  end

  def resources(list) do
    table(
      ["Centro", "Zona", "Código", "Nombre", "Categoría", "Disponible", "Unidad"],
      Enum.map(list, &[&1.center, &1.zone, &1.code, &1.name, &1.category, &1.available, &1.unit])
    )
  end

  def movements(list) do
    table(
      ["Id", "Fecha", "Tipo", "Código", "Cant", "Ref"],
      Enum.map(list, &[&1.id, &1.at, &1.kind, &1.code, &1.quantity, &1.ref || ""])
    )
  end

  def people(list) do
    table(
      ["ID", "Documento", "Nombre", "Edad", "Zona", "Estado"],
      Enum.map(list, &[&1.id, &1.document, &1.name, &1.age || "", &1.zone, &1.status])
    )
  end

  def person(p, history) do
    age = if p.age, do: " · edad #{p.age}", else: ""
    head = "#{p.id} #{p.name} · documento #{p.document} · zona #{p.zone} · estado #{p.status}" <> age
    lines = Enum.map(history, fn {status, at, by} -> "  - #{at} #{status} (por #{by})" end)
    Enum.join([head, "Historial:" | lines], "\n")
  end

  def messages(list) do
    table(
      ["ID", "De", "Estado", "Fecha", "Mensaje"],
      Enum.map(list, &[&1.id, &1.from, &1.status, &1.at, &1.content])
    )
  end

  def pets(list) do
    table(
      ["ID", "Tipo", "Especie", "Nombre", "Color", "Tamaño", "Zona", "Estado", "Pareja"],
      Enum.map(list, &[&1.id, &1.kind, &1.species, &1.name || "?", &1.color, &1.size, &1.zone, &1.status, &1.matched_with || ""])
    )
  end

  def candidates([]), do: "No hay coincidencias por encima del umbral"

  def candidates(list) do
    table(
      ["Perdida", "Encontrada", "Puntaje", "Detalle"],
      Enum.map(list, fn c ->
        detail = c.breakdown |> Enum.map(fn {k, v} -> "#{k}=#{v}" end) |> Enum.join(" ")
        [c.lost, c.found, c.score, detail]
      end)
    )
  end

  def shelter(i) do
    extra =
      [{"Recursos", i.resources}, {"Necesidades", i.needs}]
      |> Enum.reject(fn {_label, items} -> items == [] end)
      |> Enum.map(fn {label, items} -> " · #{label}: #{Enum.join(items, ", ")}" end)
      |> Enum.join()

    "#{i.code} #{i.name} (zona #{i.zone}): ocupación #{i.occupancy}/#{i.capacity} " <>
      "(#{i.percent}%), cupos libres #{i.available}" <> extra
  end

  def shelters(list) do
    table(
      ["Código", "Nombre", "Zona", "Ocupación", "%", "Cupos"],
      Enum.map(list, &[&1.code, &1.name, &1.zone, "#{&1.occupancy}/#{&1.capacity}", &1.percent, &1.available])
    )
  end

  def zones_overview(list) do
    table(
      ["Zona", "Nivel", "Afectados", "Sectores", "Puntos", "Albergues", "Necesidades", "Reportes"],
      Enum.map(list, &[&1.code, &1.level, &1.total_affected, &1.sectors, &1.points, &1.shelters, &1.needs, &1.reports])
    )
  end

  def zone_stats(s) do
    header = "Zona #{s.code} (#{s.name}) · nivel #{s.level}"

    totals =
      "Afectados: #{s.own_affected} sin desglosar, #{s.total_affected} en total · " <>
        "sectores #{s.sectors} · puntos #{s.points} · profundidad #{s.depth}"

    links = "Albergues: #{s.shelters} · necesidades: #{s.needs} · reportes: #{s.reports}"
    Enum.join([header, totals, links | tree_lines(s.tree, 0)], "\n")
  end

  # Recursión sobre la jerarquía de sectores.
  defp tree_lines([], _depth), do: []

  defp tree_lines([s | rest], depth) do
    line =
      String.duplicate("  ", depth) <>
        "- #{s.id} #{s.name}: #{s.own_affected} propios, #{s.total_affected} acumulados, #{s.points} puntos"

    [line | tree_lines(s.children, depth + 1)] ++ tree_lines(rest, depth)
  end

  def activity(entries) do
    table(["Fecha", "Acción", "Detalle"], Enum.map(entries, &[&1.at, &1.action, &1.detail]))
  end

  ## Asignación, críticos y resumen

  def assignment(need, done, failure) do
    parts = Enum.map_join(done, ", ", fn {center, code, qty} -> "#{qty} de #{code} en #{center}" end)
    total = done |> Enum.map(&elem(&1, 2)) |> Enum.sum()

    base =
      "#{need.id}: asignadas #{total} unidades (#{parts}). " <>
        "Estado: #{need.status}; faltan #{Need.remaining(need)}."

    if failure, do: base <> " Asignación parcial, falló: " <> error(failure), else: base
  end

  def critical(deficits, low) do
    deficit_text =
      if deficits == [] do
        "Sin déficit frente a las necesidades pendientes."
      else
        table(
          ["Tipo", "Necesario", "Disponible", "Déficit"],
          Enum.map(deficits, &[&1.type, &1.needed, &1.available, &1.needed - &1.available])
        )
      end

    Enum.join(
      ["Déficit frente a necesidades pendientes:", deficit_text, "", "Recursos con stock bajo:", resources(low)],
      "\n"
    )
  end

  def summary(d) do
    zones = Map.get(d, :zones, [])
    needs = Map.get(d, :needs, %{counts: %{}, queue: 0})
    resources = Map.get(d, :resources, [])
    people = Map.get(d, :people, %{})
    shelters = Map.get(d, :shelters, [])

    capacity = shelters |> Enum.map(& &1.capacity) |> Enum.sum()
    occupancy = shelters |> Enum.map(& &1.occupancy) |> Enum.sum()
    top = shelters |> Enum.sort_by(&{-&1.percent, &1.code}) |> Enum.take(3)
    centers = resources |> Enum.map(& &1.center) |> Enum.uniq() |> length()

    Enum.join(
      [
        "===== RESUMEN GLOBAL =====",
        "",
        "Zonas (#{length(zones)}):",
        zones_overview(zones),
        "",
        "Necesidades: #{counts_line(needs.counts)} | por cubrir: #{needs.queue}",
        "",
        "Recursos restantes (#{centers} centros):",
        resource_totals(resources),
        "",
        "Personas: #{counts_line(people)}",
        "Mensajes familiares: #{counts_line(Map.get(d, :messages, %{}))}",
        "Reportes de mascotas: #{counts_line(Map.get(d, :pets, %{}))}",
        "",
        "Albergues: #{length(shelters)} · ocupación #{occupancy}/#{capacity}",
        shelters(top)
      ],
      "\n"
    )
  end

  defp counts_line(counts) when map_size(counts) == 0, do: "sin datos"
  defp counts_line(counts), do: counts |> Enum.map(fn {k, v} -> "#{k}: #{v}" end) |> Enum.join(", ")

  defp resource_totals(entries) do
    rows =
      entries
      |> Enum.group_by(&{&1.category, &1.unit}, & &1.available)
      |> Enum.map(fn {{category, unit}, qtys} -> [category, unit, Enum.sum(qtys)] end)
      |> Enum.sort()

    table(["Categoría", "Unidad", "Disponible"], rows)
  end
end
