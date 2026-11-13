# Sismo: plataforma concurrente de gestión de emergencias post-terremoto

Sistema multiusuario en Elixir que simula una plataforma distribuida para coordinar la atención de un terremoto: zonas afectadas, necesidades, recursos y centros de acopio, albergues, personas y mensajes familiares, y mascotas perdidas o encontradas.

## Ejecución

```cmd
mix deps.get
mix test
mix run -e "Sismo.CLI.start()"
```

Flujo de ejemplo (el del enunciado):

```
connect laura 1234 coordinador centro
register_zone centro Centro critico 100
register_resource R001 agua 50 litros centro_acopio_1
register_need agua 30 critica centro "Punto de atención sector 3"
assign_resource N001 agua 30
pending_needs
summary
exit
```

Varios usuarios a la vez, desde `iex -S mix`:

```elixir
Sismo.CLI.parallel([
  ["connect ana 1234 coordinador centro", "list_needs"],
  ["connect beto 1234 voluntario centro", "pending_needs"]
])
```

Los datos se guardan en `data/` (configurable con `config :sismo, data_dir: ...`).

## Arquitectura

### Capas

| Capa | Módulos | Responsabilidad |
|---|---|---|
| Interfaz | `CLI`, `CLI.Commands`, `CLI.Parser`, `CLI.Format` | Traducir texto a llamadas, autorizar por rol, coordinar módulos, dar formato |
| Procesos | `*.Server`, `Resources.Center`, `Shelters.Server`, supervisores | Estado, exclusión mutua, persistencia |
| Dominio puro | `Ledger`, `Zones.Book`, `Needs.Book`, `People.Book`, `Pets.Book`, `Shelters.Shelter`, `Pets.Similarity`, `Zones.Tree` | Reglas de negocio sin procesos ni disco |
| Persistencia | `Persistence.Writer`, `Persistence.Codec` | Texto plano, un único proceso escribe en disco |

Las reglas de negocio viven en el dominio puro: son funciones que reciben un estado y devuelven `{:ok, evento}` o `{:error, razón}`. El `GenServer` valida, persiste y solo entonces aplica el evento en memoria. El CLI no contiene reglas, solo traduce y coordina.

### Árbol de supervisión

```
Sismo.Supervisor (rest_for_one)
├── Registry (Sismo.Registry)              nombres dinámicos {:center, id}, {:shelter, code}
├── Persistence.Writer                     único proceso que escribe en disco
├── Activity.Log                           bitácora de actividad por usuario
├── Task.Supervisor (Sismo.TaskSupervisor) trabajo paralelo sin estado
├── Resources.CenterSupervisor             DynamicSupervisor, one_for_one
│     └── Resources.Center × N             un GenServer por centro de acopio
├── Shelters.ShelterSupervisor             DynamicSupervisor, one_for_one
│     └── Shelters.Server × N              un GenServer por albergue
├── Users.Server                           usuarios y sesiones
├── Zones.Server                           zonas, sectores, puntos de atención
├── Needs.Server                           necesidades y cola por prioridad
├── People.Server                          personas y mensajes familiares
└── Pets.Server                            reportes de mascotas
```

**Por qué `rest_for_one`.** El orden de los hijos refleja dependencias. Si cae el `Registry` o el `Writer`, se reinicia todo lo que depende de ellos. Los centros y albergues van antes de los servidores de dominio, así que la caída de un servidor de dominio no los reinicia. Los subárboles `× N` usan `one_for_one`: la caída de un centro no afecta a los demás.

### Tipos de proceso

| Proceso | Tipo | Justificación |
|---|---|---|
| `Center`, `Shelters.Server` | un `GenServer` por entidad | Su estado es el recurso compartido; su mailbox es la exclusión mutua |
| `Users`, `Zones`, `Needs`, `People`, `Pets` | `GenServer` único | Baja contención y consultas globales |
| `Writer`, `Activity.Log` | `GenServer` único | Serializa el acceso al disco |
| `Matcher`, `Inventory`, `Shelters.Report`, `summary` | `Task.Supervisor.async_stream_nolink` | Trabajo puro y paralelizable |
| Suscriptores de `People.watch/3` | procesos arbitrarios con `send/2` y `Process.monitor` | Paso de mensajes crudo |
| Sesiones de usuario | monitor sobre el proceso cliente | Si el cliente muere, la sesión se libera |

## Concurrencia: cómo se evitan las inconsistencias

| Regla del enunciado | Mecanismo |
|---|---|
| No asignar más inventario del real (55 contra 50 litros) | Cada `Center` valida y descuenta dentro de un mismo `handle_call`. Centros distintos trabajan en paralelo |
| Una necesidad no consume recursos dos veces | La reserva es idempotente por `{código, referencia}`; cada asignación usa una referencia propia (`N001:2`) |
| No superar la capacidad de un albergue | El chequeo de cupo y la inserción ocurren en el mismo `handle_call`. La ocupación se deriva de un `MapSet`, sin contador |
| Un reporte no se resuelve dos veces | La máquina de estados valida y aplica dentro del mismo `handle_call`; `resuelta` es estado final |
| Ids únicos | Los genera el servidor dueño del estado, de forma secuencial |
| Registro automático concurrente de un mismo usuario | `Users.Server` serializa: una llamada registra, las demás autentican |

**Transferencias y operaciones entre módulos.** Ningún proceso llama a otro desde dentro de su `handle_call` en forma circular, así que no hay deadlock. Las operaciones que tocan dos procesos son sagas con compensación:

- `Transfer`: retira del origen, deposita en el destino y, si el depósito falla, devuelve al origen.
- `register_entry`: ingresa al albergue y cambia la persona a `en_albergue`; si lo segundo falla, la saca del albergue.
- `assign` y `cancel` en `Needs`: reservar o liberar (idempotente) y luego persistir, de modo que repetir tras un fallo es seguro.

## Persistencia en texto plano

Un registro por línea, campos separados por `|`, con escape de `\`, `|` y saltos de línea (`Persistence.Codec`).

| Archivo | Contenido | Estrategia |
|---|---|---|
| `users.db` | usuarios (contraseña con PBKDF2 y sal) | append síncrono |
| `activity.log` | actividad por usuario | append asíncrono |
| `zones.log`, `needs.log`, `people.log`, `pets.log` | eventos del dominio | append síncrono, replay al arrancar |
| `centers/<id>.log` | movimientos de inventario | append síncrono, replay al arrancar |
| `shelters/<code>.log` | eventos del albergue | append síncrono, replay al arrancar |

**Primero disco, después memoria.** Si la escritura falla, el estado no cambia. El estado se reconstruye con `replay/2`, una recursión de cola sobre la lista de eventos. Los archivos de eventos son además el historial que exige el enunciado (movimientos, cambios de estado).

## Estructuras de datos y recursividad

- **Estructuras:** mapas y structs (`Need`, `Person`, `Report`, `Zone`...), listas, tuplas de resultado y eventos, `MapSet` (ocupantes de albergue, asociaciones de zona).
- **Recursión sobre jerarquía** (`Zones.Tree`): `find_sector`, `update_sector`, `sector_ids` y `sector_stats` recorren `zona → sectores → subsectores → puntos de atención`.
- **Recursión sobre listas:** `replay/2` (cola) en todos los dominios, `Parser.tok` (sobre el binario), `split_plan` (reparte una asignación entre centros), `tree_lines` (dibuja el árbol).
- **Algoritmo de coincidencias** (`Pets.Similarity`): puntaje de 0 a 100 con especie 30, color 25, tamaño 15, zona 15, nombre 10 y características 5. Si la especie difiere el total es 0. Umbral por defecto: 50.

## Roles

| Rol | Hereda de | Acciones añadidas |
|---|---|---|
| ciudadano | | registrar necesidades, reportar personas y mascotas, mensajes, consultas |
| voluntario | ciudadano | registrar recursos, ingreso y salida de albergues, `match_pets`, `pending_needs` |
| coordinador | voluntario | zonas, asignar y transferir recursos, albergues, `summary`, `critical_resources`, confirmar coincidencias |
| administrador | coordinador | gestión de usuarios (no se obtiene por auto-registro) |

## Decisiones que el enunciado deja abiertas

- `assign_resource` no indica el centro: se busca el recurso por código, nombre o categoría, con preferencia por la zona de la necesidad y luego por mayor stock. Si un centro no alcanza, se reparte entre varios.
- Un albergue nace con ocupación 0; la ocupación sube con `register_entry`.
- `match_pets` solo calcula candidatos; proponer, descartar y confirmar son pasos explícitos.
- `estimated_affected` de la zona son las personas no desglosadas por sector; el total acumulado suma recursivamente los sectores.
- Los mensajes familiares pueden dejarse para un documento aún no registrado.

## Limitaciones conocidas

- La asociación zona-necesidad, zona-albergue y zona-reporte no es transaccional: si falla, queda una advertencia y `reconcile_links` la repara solo al arrancar. Los centros y las personas no se enlazan en `Zones`; los centros llevan su propia zona y las personas se consultan con `search(zone: ...)`.
- `restore_all` solo corre al iniciar la aplicación; si el `CenterSupervisor` se reiniciara por sí solo, los centros no se recuperarían.
- Una transferencia con timeout en el depósito no sabe si se aplicó; compensar podría duplicar stock.
- La comprobación de "una persona en un solo albergue" no es atómica entre albergues.
- Los reportes agregados (`Inventory`, `Shelters.Report`, `summary`) son una foto aproximada, no atómica.
- Las sesiones no persisten entre reinicios, a propósito.
- Las contraseñas usan 10.000 iteraciones de PBKDF2 por rendimiento del curso; en producción serían 100.000 o más.