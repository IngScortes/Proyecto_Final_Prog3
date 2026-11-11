defmodule Sismo.CLI.Commands do
  @moduledoc """
  Traduce comandos de texto a llamadas a los servidores. Cada comando pasa por
  `Users.authorize/3` y queda registrado en la bitácora de actividad.
  El estado es solo el usuario conectado: no hay proceso propio.
  """
  alias Sismo.Activity.Log
  alias Sismo.CLI.{Format, Parser}
  alias Sismo.Needs.Need
  alias Sismo.Needs.Server, as: Needs
  alias Sismo.People.Server, as: People
  alias Sismo.Pets.{Matcher, Similarity}
  alias Sismo.Pets.Server, as: Pets
  alias Sismo.Resources.{Center, CenterSupervisor, Inventory, Transfer}
  alias Sismo.Shelters.{Report, ShelterSupervisor}
  alias Sismo.Shelters.Server, as: Shelters
  alias Sismo.Users.Server, as: Users
  alias Sismo.Zones.Server, as: Zones

  defstruct user: nil

  # comando -> acción de Permissions
  @actions %{
    "register_zone" => :register_zone,
    "add_sector" => :register_zone,
    "add_point" => :register_zone,
    "zone_status" => :zone_status,
    "register_need" => :register_need,
    "list_needs" => :list_needs,
    "pending_needs" => :pending_needs,
    "update_need" => :update_need,
    "assign_resource" => :assign_resource,
    "register_resource" => :register_resource,
    "stock_in" => :register_resource,
    "stock_out" => :register_resource,
    "list_resources" => :list_resources,
    "resource_history" => :list_resources,
    "transfer_resource" => :transfer_resource,
    "critical_resources" => :critical_resources,
    "report_person" => :report_person,
    "find_person" => :find_person,
    "person_status" => :person_status,
    "send_family_message" => :send_family_message,
    "list_family_messages" => :list_family_messages,
    "mark_message" => :mark_message,
    "report_pet" => :report_pet,
    "list_pets" => :list_pets,
    "match_pets" => :match_pets,
    "propose_match" => :match_pets,
    "reject_match" => :confirm_match,
    "confirm_match" => :confirm_match,
    "register_shelter" => :register_shelter,
    "link_shelter" => :register_shelter,
    "check_shelter" => :check_shelter,
    "shelter_report" => :check_shelter,
    "register_entry" => :register_entry,
    "register_exit" => :register_exit,
    "summary" => :summary,
    "activity" => :activity
  }

  @usage %{
    "connect" => "connect usuario contraseña [tipo] [zona]",
    "disconnect" => "disconnect",
    "exit" => "exit",
    "register_zone" => "register_zone codigo nombre nivel [afectados]",
    "add_sector" => "add_sector zona sector nombre [afectados] [parent=sector_padre]",
    "add_point" => "add_point zona sector punto nombre tipo",
    "zone_status" => "zone_status [zona]",
    "register_need" => "register_need tipo cantidad prioridad zona descripcion",
    "list_needs" => "list_needs [zona=..] [tipo=..] [prioridad=..] [estado=..]",
    "pending_needs" => "pending_needs",
    "update_need" => "update_need necesidad en_atencion|atendida|cancelada",
    "assign_resource" => "assign_resource necesidad recurso cantidad [centro]",
    "register_resource" => "register_resource codigo nombre cantidad unidad centro",
    "stock_in" => "stock_in centro codigo cantidad",
    "stock_out" => "stock_out centro codigo cantidad",
    "list_resources" => "list_resources [zona=..] [tipo=..]",
    "resource_history" => "resource_history centro",
    "transfer_resource" => "transfer_resource codigo origen destino cantidad",
    "critical_resources" => "critical_resources [umbral=10]",
    "report_person" => "report_person documento nombre zona estado [edad]",
    "find_person" => "find_person documento | find_person [nombre=..] [zona=..] [estado=..]",
    "person_status" => "person_status documento estado",
    "send_family_message" => "send_family_message documento \"mensaje\"",
    "list_family_messages" => "list_family_messages documento",
    "mark_message" => "mark_message mensaje entregado|pendiente",
    "report_pet" => "report_pet lost|found especie nombre color tamaño zona contacto [caracteristicas]",
    "list_pets" => "list_pets [especie=..] [zona=..] [estado=..] [tipo=lost|found]",
    "match_pets" => "match_pets [umbral=50]",
    "propose_match" => "propose_match reporte1 reporte2",
    "reject_match" => "reject_match reporte1 reporte2",
    "confirm_match" => "confirm_match reporte1 reporte2",
    "register_shelter" => "register_shelter codigo nombre zona capacidad",
    "link_shelter" => "link_shelter albergue need|resource referencia",
    "check_shelter" => "check_shelter albergue",
    "shelter_report" => "shelter_report [n]",
    "register_entry" => "register_entry albergue documento",
    "register_exit" => "register_exit albergue documento",
    "summary" => "summary",
    "activity" => "activity",
    "help" => "help"
  }

  ## API

  def new, do: %__MODULE__{}

  @doc "Ejecuta una línea. Devuelve `{:ok | :error | :quit, texto, estado}`."
  def run(%__MODULE__{} = state, line) when is_binary(line) do
    case Parser.parse(line) do
      :empty -> {:ok, "", state}
      {:error, reason} -> {:error, Format.error(reason), state}
      {:ok, {name, args}} -> handle(state, name, args)
    end
  end

  def shutdown(%__MODULE__{user: nil} = state), do: state

  def shutdown(%__MODULE__{user: user} = state) do
    Users.disconnect(user)
    %{state | user: nil}
  end

  ## Comandos de sesión

  defp handle(state, "help", _args), do: {:ok, help_text(), state}
  defp handle(state, name, _args) when name in ["exit", "quit"], do: {:quit, "Hasta luego.", shutdown(state)}
  defp handle(state, "connect", args), do: connect(state, args)
  defp handle(state, "disconnect", _args), do: disconnect(state)
  defp handle(state, name, args), do: dispatch(state, name, args)

  defp connect(%{user: user} = state, args) when not is_nil(user) do
    if Users.connected?(user) do
      {:error, "Ya estás conectado como #{user}. Usa disconnect primero.", state}
    else
      connect(%{state | user: nil}, args)
    end
  end

  defp connect(state, [username, password | rest]) when length(rest) <= 2 do
    attrs =
      case rest do
        [role, zone] -> %{role: role, zone: zone}
        [role] -> %{role: role}
        [] -> %{}
      end

    case Users.connect(username, password, attrs) do
      {:ok, kind, user} ->
        verb = if kind == :registered, do: "Usuario registrado y conectado", else: "Sesión iniciada"
        text = "#{verb}: #{user.username} (#{user.role}, zona #{user.zone})"
        {:ok, text, %{state | user: user.username}}

      {:error, reason} ->
        {:error, Format.error(reason), state}
    end
  end

  defp connect(state, _args), do: {:error, Format.error({:usage, @usage["connect"]}), state}

  defp disconnect(%{user: nil} = state), do: {:error, Format.error(:not_connected), state}

  defp disconnect(%{user: user} = state) do
    Users.disconnect(user)
    {:ok, "Sesión de #{user} cerrada.", %{state | user: nil}}
  end

  ## Despacho con autorización

  defp dispatch(state, name, args) do
    case Map.fetch(@actions, name) do
      {:ok, action} -> authorized(state, name, action, args)
      :error -> {:error, "Comando desconocido: #{name}. Escribe help.", state}
    end
  end

  defp authorized(state, name, action, args) do
    with {:ok, user} <- Users.authorize(state.user, action),
         {:ok, text} <- safe_exec(name, args, user) do
      Log.record(user.username, name, Enum.join(args, " "))
      {:ok, text, state}
    else
      {:error, reason} -> {:error, Format.error(reason), state}
    end
  end

  defp safe_exec(name, args, user) do
    exec(name, args, user)
  catch
    :exit, reason -> {:error, {:unavailable, reason}}
  end

  ## Comandos de dominio (todas las cláusulas de exec/3 juntas)

  # --- Zonas ---
  defp exec("register_zone", [code, name, level | opt], _u) when length(opt) <= 1 do
    with {:ok, affected} <- opt_int(opt, 0),
         {:ok, zone} <- Zones.create_zone(code, name, level, affected) do
      {:ok, "Zona #{zone.code} registrada (nivel #{zone.level}, #{zone.estimated_affected} afectados)"}
    end
  end

  defp exec("add_sector", args, _u) do
    case Parser.split_opts(args) do
      {[zone, id, name | opt], opts} when length(opt) <= 1 ->
        with {:ok, affected} <- opt_int(opt, 0),
             {:ok, _zone} <- Zones.add_sector(zone, opts[:parent], id, name, affected) do
          {:ok, "Sector #{id} agregado a la zona #{zone}"}
        end

      _ ->
        usage("add_sector")
    end
  end

  defp exec("add_point", [zone, sector, id, name, kind], _u) do
    with {:ok, _zone} <- Zones.add_point(zone, sector, id, name, kind) do
      {:ok, "Punto de atención #{id} agregado al sector #{sector}"}
    end
  end

  defp exec("zone_status", [], _u), do: {:ok, Format.zones_overview(Zones.overview())}

  defp exec("zone_status", [code], _u) do
    with {:ok, stats} <- Zones.stats(code), do: {:ok, Format.zone_stats(stats)}
  end

  # --- Necesidades ---
  defp exec("register_need", [type, qty, priority, zone | desc], u) when desc != [] do
    with {:ok, qty} <- int(qty),
         {:ok, need} <- Needs.register(type, qty, priority, zone, Enum.join(desc, " "), u.username) do
      {:ok,
       "Necesidad #{need.id} registrada: #{need.type} x#{need.quantity}, " <>
         "prioridad #{need.priority}, zona #{need.zone}"}
    end
  end

  defp exec("list_needs", args, _u) do
    case Parser.split_opts(args) do
      {[], opts} -> with {:ok, needs} <- Needs.list(opts), do: {:ok, Format.needs(needs)}
      _ -> usage("list_needs")
    end
  end

  defp exec("pending_needs", [], _u), do: {:ok, Format.needs(Needs.queue())}

  defp exec("update_need", [raw_id, status], _u) do
    with {:ok, id} <- need_id(raw_id),
         {:ok, need} <- change_need(id, norm_token(status)) do
      {:ok, "#{need.id}: estado #{need.status}"}
    end
  end

  defp exec("assign_resource", [raw_id, term, raw_qty | opt], _u) when length(opt) <= 1 do
    with {:ok, id} <- need_id(raw_id),
         {:ok, qty} <- int(raw_qty),
         {:ok, need} <- Needs.get(id),
         :ok <- assignable(need, qty),
         {:ok, plan} <- plan_assignment(need, term, qty, opt),
         {:ok, done, failure} <- allocate(id, plan),
         {:ok, need} <- Needs.get(id) do
      {:ok, Format.assignment(need, done, failure)}
    end
  end

  # --- Recursos ---
  defp exec("register_resource", [code, name, raw_qty, unit, center], u) do
    with {:ok, qty} <- int(raw_qty),
         {:ok, center} <- ensure_center(center, u.zone),
         {:ok, r} <- Center.register_resource(center, code, name, name, unit, qty) do
      {:ok, "Recurso #{r.code} (#{r.name}) registrado en #{center}: #{r.available} #{r.unit}"}
    end
  end

  defp exec("stock_in", [center, code, qty], _u), do: stock(:deposit, center, code, qty)
  defp exec("stock_out", [center, code, qty], _u), do: stock(:withdraw, center, code, qty)

  defp exec("list_resources", args, _u) do
    case Parser.split_opts(args) do
      {[], opts} ->
        filters = [zone: opts[:zone], category: opts[:type] || opts[:category]]
        {:ok, Format.resources(Inventory.list(filters))}

      _ ->
        usage("list_resources")
    end
  end

  defp exec("resource_history", [center], _u) do
    case Center.history(norm(center)) do
      {:error, _} = error -> error
      movements -> {:ok, Format.movements(movements)}
    end
  end

  defp exec("transfer_resource", [code, from, to, raw_qty], _u) do
    from = norm(from)

    with {:ok, qty} <- int(raw_qty),
         %{zone: zone} <- Center.snapshot(from),
         {:ok, resource} <- Center.get_resource(from, code),
         :ok <- enough(resource, qty),
         {:ok, to} <- ensure_center(to, zone),
         {:ok, t} <- Transfer.transfer(from, to, code, qty) do
      {:ok, "Transferencia #{t.transfer_id}: #{t.quantity} de #{t.code} de #{t.from} a #{t.to}"}
    end
  end

  defp exec("critical_resources", args, _u) do
    with {[], opts} <- Parser.split_opts(args),
         {:ok, threshold} <- opt_int(List.wrap(opts[:threshold]), 10) do
      entries = Inventory.list()
      low = Enum.filter(entries, &(&1.available <= threshold))
      {:ok, Format.critical(deficits(entries), low)}
    else
      {[_ | _], _opts} -> usage("critical_resources")
      error -> error
    end
  end

  # --- Personas y mensajes ---
  defp exec("report_person", [doc, name, zone, status | opt], u) when length(opt) <= 1 do
    with {:ok, age} <- opt_age(opt),
         {:ok, p} <- People.report(doc, name, age, zone, status, u.username) do
      {:ok, "Persona #{p.id} registrada: #{p.name}, documento #{p.document}, estado #{p.status}"}
    end
  end

  defp exec("find_person", args, _u) do
    case Parser.split_opts(args) do
      {[doc], []} ->
        with {:ok, person} <- People.get(doc),
             {:ok, history} <- People.history(doc) do
          {:ok, Format.person(person, history)}
        end

      {[], [_ | _] = opts} ->
        with {:ok, people} <- People.search(opts), do: {:ok, Format.people(people)}

      _ ->
        usage("find_person")
    end
  end

  defp exec("person_status", [doc, status], u) do
    with {:ok, p} <- People.set_status(doc, status, u.username) do
      {:ok, "#{p.name} (#{p.document}): estado #{p.status}"}
    end
  end

  defp exec("send_family_message", [doc | content], u) when content != [] do
    with {:ok, m} <- People.send_message(u.username, doc, Enum.join(content, " ")) do
      {:ok, "Mensaje #{m.id} guardado para el documento #{m.to_document} (#{m.status})"}
    end
  end

  defp exec("list_family_messages", [doc], _u), do: {:ok, Format.messages(People.messages_for(doc))}

  defp exec("mark_message", [id, status], _u) do
    result =
      case norm_token(status) do
        "entregado" -> People.mark_delivered(id)
        "pendiente" -> People.mark_pending(id)
        _ -> {:error, {:invalid_field, :message_status}}
      end

    with {:ok, m} <- result, do: {:ok, "Mensaje #{m.id} marcado como #{m.status}"}
  end

  # --- Mascotas ---
  defp exec("report_pet", [kind, species, name, color, size, zone, contact | traits], u) do
    attrs = %{
      kind: kind, species: species, name: name, color: color, size: size,
      zone: zone, contact: contact, traits: Enum.join(traits, " ")
    }

    with {:ok, r} <- Pets.report(attrs, u.username) do
      {:ok, "Reporte #{r.id} registrado: #{r.kind} de #{r.species} en #{r.zone}"}
    end
  end

  defp exec("list_pets", args, _u) do
    case Parser.split_opts(args) do
      {[], opts} ->
        filters = for {key, value} <- opts, do: {if(key == :type, do: :kind, else: key), value}
        with {:ok, reports} <- Pets.list(filters), do: {:ok, Format.pets(reports)}

      _ ->
        usage("list_pets")
    end
  end

  defp exec("match_pets", args, _u) do
    with {[], opts} <- Parser.split_opts(args),
         {:ok, threshold} <- opt_int(List.wrap(opts[:threshold]), 50) do
      {:ok, Format.candidates(Matcher.find(threshold: threshold))}
    else
      {[_ | _], _opts} -> usage("match_pets")
      error -> error
    end
  end

  defp exec("propose_match", [a, b], _u), do: pair(Pets.propose(a, b), "Coincidencia propuesta")
  defp exec("reject_match", [a, b], _u), do: pair(Pets.reject(a, b), "Coincidencia descartada")
  defp exec("confirm_match", [a, b], _u), do: pair(Pets.confirm(a, b), "Coincidencia confirmada")

  # --- Albergues ---
  defp exec("register_shelter", [code, name, zone, raw_cap], _u) do
    with {:ok, capacity} <- int(raw_cap),
         {:ok, code} <- ShelterSupervisor.open_shelter(code, name, zone, capacity) do
      {:ok, "Albergue #{code} registrado en la zona #{zone} con capacidad #{capacity}"}
    end
  end

  defp exec("link_shelter", [code, kind, ref], _u) do
    with {:ok, kind} <- link_kind(norm_token(kind)),
         {:ok, info} <- Shelters.link(code, kind, ref) do
      {:ok, "#{ref} asociado al albergue #{info.code}"}
    end
  end

  defp exec("check_shelter", [code], _u) do
    with {:ok, info} <- Shelters.info(code), do: {:ok, Format.shelter(info)}
  end

  defp exec("shelter_report", args, _u) when length(args) <= 1 do
    with {:ok, n} <- opt_int(args, 5), do: {:ok, Format.shelters(Report.top_occupied(max(n, 1)))}
  end

  defp exec("register_entry", [code, doc], u) do
    with {:ok, person} <- People.get(doc),
         :ok <- ensure_enterable(person),
         :ok <- ensure_not_elsewhere(code, person.document),
         {:ok, info} <- Shelters.enter(code, person.document) do
      mark_in_shelter(code, person, info, u)
    end
  end

  defp exec("register_exit", [code, doc], u) do
    with {:ok, info} <- Shelters.leave(code, doc) do
      {:ok, "Salida registrada en #{info.code}: ocupación #{info.occupancy}/#{info.capacity}." <> release_person(doc, u)}
    end
  end

  # --- Gestión ---
  defp exec("summary", [], _u), do: {:ok, Format.summary(gather_summary())}

  defp exec("activity", [], u),
    do: {:ok, Format.activity(u.username |> Log.for_user() |> Enum.take(20))}

  defp exec(name, _args, _u), do: usage(name)

  ## Auxiliares de comandos

  defp usage(name), do: {:error, {:usage, Map.get(@usage, name, name)}}

  defp int(raw) do
    case Integer.parse(String.trim(raw)) do
      {n, ""} -> {:ok, n}
      _ -> {:error, :invalid_quantity}
    end
  end

  defp opt_int([], default), do: {:ok, default}
  defp opt_int([raw], _default), do: int(raw)

  defp opt_age([]), do: {:ok, nil}

  defp opt_age([raw]) do
    case Integer.parse(String.trim(raw)) do
      {n, ""} -> {:ok, n}
      _ -> {:error, :invalid_age}
    end
  end

  defp norm(id), do: id |> String.trim() |> String.downcase()
  defp norm_token(text), do: text |> Similarity.fold() |> String.replace(" ", "_")

  # Acepta "N001" y "need001".
  defp need_id(raw) do
    case Regex.run(~r/^(?:need|n)0*(\d+)$/i, String.trim(raw)) do
      [_, digits] -> {:ok, "N" <> String.pad_leading(digits, 3, "0")}
      _ -> {:error, :need_not_found}
    end
  end

  defp change_need(id, "en_atencion"), do: Needs.start_attention(id)
  defp change_need(id, "atendida"), do: Needs.complete(id)
  defp change_need(id, "cancelada"), do: Needs.cancel(id)
  defp change_need(_id, _status), do: {:error, {:invalid_field, :status}}

  defp link_kind(kind) when kind in ["need", "necesidad"], do: {:ok, :need}
  defp link_kind(kind) when kind in ["resource", "recurso"], do: {:ok, :resource}
  defp link_kind(_kind), do: {:error, :invalid_kind}

  defp pair({:ok, %{lost: lost, found: found}}, text),
    do: {:ok, "#{text}: #{lost.id} (#{lost.status}) y #{found.id} (#{found.status})"}

  defp pair({:error, _} = error, _text), do: error

  # --- Asignación de recursos a una necesidad ---

  defp assignable(%{status: status}, _qty) when status not in [:pendiente, :asignada],
    do: {:error, {:not_assignable, status}}

  defp assignable(_need, qty) when not (is_integer(qty) and qty > 0), do: {:error, :invalid_quantity}

  defp assignable(need, qty) do
    remaining = Need.remaining(need)
    if qty <= remaining, do: :ok, else: {:error, {:exceeds_remaining, remaining}}
  end

  defp plan_assignment(need, term, qty, opt) do
    candidates = term |> Inventory.candidates(need.zone) |> filter_center(opt)
    total = candidates |> Enum.map(& &1.available) |> Enum.sum()

    cond do
      candidates == [] -> {:error, :resource_not_found}
      total < qty -> {:error, {:insufficient_stock, total}}
      true -> {:ok, split_plan(candidates, qty)}
    end
  end

  defp filter_center(candidates, []), do: candidates
  defp filter_center(candidates, [center]), do: Enum.filter(candidates, &(&1.center == norm(center)))

  # Recursión: toma de cada centro lo que pueda hasta cubrir la cantidad.
  defp split_plan([], _remaining), do: []
  defp split_plan(_candidates, 0), do: []
  defp split_plan([%{available: 0} | rest], remaining), do: split_plan(rest, remaining)

  defp split_plan([c | rest], remaining) do
    take = min(c.available, remaining)
    [{c.center, c.code, take} | split_plan(rest, remaining - take)]
  end

  defp allocate(id, plan) do
    {done, failure} =
      Enum.reduce_while(plan, {[], nil}, fn {center, code, take}, {done, _} ->
        case Needs.assign(id, center, code, take) do
          {:ok, _need} -> {:cont, {[{center, code, take} | done], nil}}
          {:error, reason} -> {:halt, {done, reason}}
        end
      end)

    case {done, failure} do
      {[], reason} -> {:error, reason}
      {done, failure} -> {:ok, Enum.reverse(done), failure}
    end
  end

  # --- Inventario ---

  defp ensure_center(raw_id, zone) do
    id = norm(raw_id)

    cond do
      Center.exists?(id) ->
        {:ok, id}

      not Zones.exists?(zone) ->
        {:error, :zone_not_found}

      true ->
        case CenterSupervisor.open_center(id, zone) do
          {:ok, id} -> {:ok, id}
          {:error, :already_exists} -> {:ok, id}
          error -> error
        end
    end
  end

  defp stock(op, center, code, raw_qty) do
    center = norm(center)

    with {:ok, qty} <- int(raw_qty),
         {:ok, _movement} <- apply(Center, op, [center, code, qty]),
         {:ok, r} <- Center.get_resource(center, code) do
      {:ok, "#{center}: #{r.code} disponible #{r.available} #{r.unit}"}
    end
  end

  defp enough(_resource, qty) when not (is_integer(qty) and qty > 0), do: {:error, :invalid_quantity}
  defp enough(%{available: available}, qty) when qty > available, do: {:error, {:insufficient_stock, available}}
  defp enough(_resource, _qty), do: :ok

  # Demanda pendiente (necesidades por cubrir) contra stock, por tipo de necesidad.
  defp deficits(entries) do
    Needs.queue()
    |> Enum.group_by(& &1.type, &Need.remaining/1)
    |> Enum.map(fn {type, remaining} ->
      available =
        entries
        |> Enum.filter(&Inventory.matches?(&1, Atom.to_string(type)))
        |> Enum.map(& &1.available)
        |> Enum.sum()

      %{type: type, needed: Enum.sum(remaining), available: available}
    end)
    |> Enum.filter(&(&1.needed > &1.available))
    |> Enum.sort_by(&(&1.available - &1.needed))
  end

  # --- Albergues y personas: saga de ingreso ---

  defp ensure_enterable(%{status: :reunificada}), do: {:error, {:invalid_transition, :reunificada, :en_albergue}}
  defp ensure_enterable(_person), do: :ok

  defp ensure_not_elsewhere(code, doc) do
    code = norm(code)

    case ShelterSupervisor.codes() |> Enum.reject(&(&1 == code)) |> Enum.find(&in_shelter?(&1, doc)) do
      nil -> :ok
      other -> {:error, {:in_other_shelter, other}}
    end
  end

  defp in_shelter?(code, doc) do
    case Shelters.occupants(code) do
      {:ok, docs} -> doc in docs
      _ -> false
    end
  end

  defp mark_in_shelter(code, %{status: :en_albergue} = person, info, _u), do: {:ok, entry_text(code, person, info)}

  defp mark_in_shelter(code, person, info, u) do
    case People.set_status(person.document, "en_albergue", u.username) do
      {:ok, _person} ->
        {:ok, entry_text(code, person, info)}

      {:error, reason} ->
        # Compensación: se deshace el ingreso para no dejar los dos módulos desfasados.
        Shelters.leave(code, person.document)
        {:error, {:status_update_failed, reason}}
    end
  end

  defp entry_text(code, person, info),
    do: "#{person.name} ingresó a #{norm(code)}: ocupación #{info.occupancy}/#{info.capacity}"

  defp release_person(doc, u) do
    case People.get(doc) do
      {:ok, %{status: :en_albergue}} ->
        case People.set_status(doc, "localizada", u.username) do
          {:ok, _} -> " Estado de la persona: localizada."
          {:error, _} -> ""
        end

      _ ->
        ""
    end
  end

  # --- Resumen global: cada consulta en una tarea distinta ---

  defp gather_summary do
    jobs = %{
      zones: fn -> Zones.overview() end,
      needs: fn -> %{counts: Needs.counts(), queue: length(Needs.queue())} end,
      resources: fn -> Inventory.list() end,
      people: fn -> People.counts() end,
      messages: fn -> People.message_counts() end,
      pets: fn -> Pets.counts() end,
      shelters: fn -> Report.all() end
    }

    Sismo.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(jobs, fn {key, job} -> {key, job.()} end,
      timeout: 10_000,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, pair} -> [pair]
      _failed -> []
    end)
    |> Map.new()
  end

  defp help_text do
    lines = @usage |> Map.values() |> Enum.sort() |> Enum.map(&"  " <> &1)
    Enum.join(["Comandos disponibles:" | lines], "\n")
  end
end
