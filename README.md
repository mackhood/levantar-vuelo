# Levantar Vuelo — Checkpoint 1

TP grupal IASC 2C2026. Sistema de reserva de vuelos construido en Elixir/OTP.

---

## Índice

1. [Qué hay en este checkpoint](#1-qué-hay-en-este-checkpoint)
2. [Cómo correrlo](#2-cómo-correrlo)
3. [Arquitectura y decisiones de diseño](#3-arquitectura-y-decisiones-de-diseño)
4. [Estructura del código](#4-estructura-del-código)
5. [API HTTP — endpoints y ejemplos](#5-api-http--endpoints-y-ejemplos)
6. [Tests](#6-tests)
7. [Qué falta para los próximos checkpoints](#7-qué-falta-para-los-próximos-checkpoints)

---

## 1. Qué hay en este checkpoint

Este checkpoint cubre el **dominio completo en un único nodo**:

| Requerimiento | Estado |
|---|---|
| F1 — publicar vuelos | ✅ `POST /flights` |
| F2 — crear alertas | ✅ `POST /alerts` |
| F3 — notificar alertas al publicar un vuelo | ✅ al publicar, consulta el `AlertIndex` |
| F4 — reservar (con overbooking) | ✅ `POST /flights/:id/reservations` |
| F5 — elegir asientos (todo o nada) | ✅ `POST /flights/:id/reservations/:rid/seats` |
| F6 — cerrar vuelo por vencimiento del tiempo de oferta | ✅ timer con `Process.send_after` |
| F7 — cerrar vuelo al agotarse los asientos | ✅ automático dentro de `assign_seats` |
| F8 — cancelar reservas pendientes al cerrar y notificar | ✅ `Flight.close/2` |

Lo que **no** está en este checkpoint (viene después):
- Distribución en múltiples nodos (Horde, libcluster) — lo vemos en clase el 15/10
- Replicación del estado entre nodos
- Notificaciones en tiempo real por SSE/WebSocket (por ahora son logs)
- Monitoreo con Prometheus/Grafana

---

## 2. Cómo correrlo

### Requisitos

- Elixir 1.14+ (tenemos 1.20.4)
- Erlang/OTP 26+ (tenemos OTP 29)

### Instalación

```bash
git clone https://github.com/mackhood/levantar-vuelo.git
cd levantar-vuelo
mix deps.get
```

### Correr el servidor

```bash
mix run --no-halt
```

El servidor arranca en `http://localhost:4000`. Deberías ver:

```
[info] Running LevantarVuelo.Router with Bandit 1.12.5 at 0.0.0.0:4000 (http)
```

### Con Docker

```bash
docker compose up --build
```

El servidor queda disponible en `http://localhost:4000`. Para detenerlo: `Ctrl+C` o `docker compose down`.

### Consola interactiva (iex)

```bash
iex -S mix
```

Desde ahí podés llamar cualquier función directamente, por ejemplo:

```elixir
alias LevantarVuelo.FlightServer

FlightServer.start_link(%{
  id: "fl_1",
  airline: "Aerolineas",
  origin: "EZE",
  destination: "MAD",
  departs_at: ~U[2026-12-20 22:00:00Z],
  offer_ends_at: ~U[2099-01-01 00:00:00Z],
  capacity: %{window: 1, aisle: 1, middle: 0}
})

FlightServer.reserve("fl_1", "usuario_1", "reserva_1")
FlightServer.assign_seats("fl_1", "reserva_1", [:window])
FlightServer.get("fl_1")
```

---

## 3. Arquitectura y decisiones de diseño

### La idea central: un actor por vuelo

El único invariante duro del dominio es **no vender más asientos de un tipo que los disponibles**. Ese invariante vive dentro de un vuelo — ninguna operación involucra dos vuelos a la vez.

La solución: cada vuelo es un **GenServer** (un proceso actor de Elixir). Su mailbox actúa como cola de pedidos y los procesa **de a uno**. Eso hace que "chequear disponibilidad y asignar" sea atómico sin locks ni transacciones.

```
Usuario A ──→ ┐
              mailbox del FlightServer → procesa de a uno, sin carreras
Usuario B ──→ ┘
```

Si llegan dos usuarios al mismo tiempo queriendo el último asiento, uno de los dos llega primero al mailbox. El primero se lo lleva; el segundo recibe un error 409. No hay forma de que los dos vean "hay disponibilidad" al mismo tiempo.

Vuelos distintos son actores distintos: se procesan en paralelo en todos los cores. Un vuelo muy demandado no frena a los demás.

### Dos capas separadas: dominio puro y proceso

Separamos la lógica en dos capas:

**Módulos puros** (`Flight`, `Alert`): solo funciones que reciben un estado y devuelven uno nuevo. No usan procesos ni OTP. Se pueden testear sin levantar nada.

**GenServers** (`FlightServer`, `AlertIndex`): procesos que guardan estado y atienden mensajes. Internamente llaman a los módulos puros para ejecutar la lógica.

Esta separación es clave: la lógica de negocio (¿cuándo se puede asignar un asiento? ¿cuándo coincide una alerta?) está aislada y es fácil de testear y razonar. El proceso solo se ocupa de mensajes, timers y estado.

### Estado en memoria, sin base de datos

Todo el estado vive en los procesos mismos:
- Cada `FlightServer` guarda su `%Flight{}` en el estado del proceso (el tercer argumento de `handle_call`/`handle_cast`).
- El `AlertIndex` guarda un mapa de alertas en su propio estado.

No hay Ecto, no hay base de datos. La "durabilidad" en un nodo único es inexistente — si el proceso muere, el estado se pierde. En los próximos checkpoints vamos a replicar el estado entre nodos para que sobreviva caídas.

### CAP: consistencia primero para asientos

Elegimos **CP** para asientos y reservas: preferimos rechazar una operación antes que vender dos veces el mismo asiento. Esto es lo que el enunciado pide explícitamente.

Las alertas son **AP**: si tarda un poco en propagarse, lo peor que pasa es que alguien no reciba una notificación a tiempo.

---

## 4. Estructura del código

```
lib/
├── levantar_vuelo/
│   ├── application.ex      # punto de entrada: arranca el árbol de supervisión
│   ├── alert.ex            # módulo puro: struct Alert + lógica de matching
│   ├── alert_index.ex      # GenServer: almacena alertas y responde consultas
│   ├── flight.ex           # módulo puro: struct Flight + operaciones de dominio
│   ├── flight_server.ex    # GenServer: proceso actor de un vuelo
│   └── router.ex           # API HTTP con Plug
test/
└── levantar_vuelo/
    ├── alert_test.exs
    ├── flight_test.exs
    └── flight_server_test.exs
```

### `Flight` — módulo puro de dominio

Define el struct `%Flight{}` y tres operaciones:

```elixir
Flight.reserve(flight, user_id, reservation_id)
# → {:ok, reservation_id, nuevo_flight} | {:error, :flight_closed}
# Agrega una reserva pendiente. Overbooking permitido: no chequea stock.

Flight.assign_seats(flight, reservation_id, seats_wanted)
# → {:ok, nuevo_flight, asientos_asignados}
# | {:error, :unavailable, disponibilidad_actual}
# Todo o nada: si no alcanza algún tipo, no asigna nada.
# Si quedan 0 asientos, cierra el vuelo automáticamente.

Flight.close(flight, reason)  # reason: :sold_out | :expired
# → {nuevo_flight, usuarios_cancelados}
# Cancela todas las reservas pendientes y cierra el vuelo.
```

La asignación de `:any` sigue esta estrategia: primero asigna asientos del medio, después pasillos, y por último ventanas. Así se preservan ventanas y pasillos para quienes los piden explícitamente.

### `FlightServer` — GenServer actor del vuelo

Envuelve a `Flight` en un proceso. Cada vuelo tiene su propio proceso con un nombre único en el `Registry`:

```elixir
# Así lo encontramos sin necesitar el PID:
{:via, Registry, {LevantarVuelo.Registry, flight_id}}
```

El timer de oferta (F6) usa `Process.send_after/3`:

```elixir
# En init/1, después de crear el vuelo:
ms = ms_until(flight.offer_ends_at)
if ms > 0, do: Process.send_after(self(), :offer_expired, ms)

# Cuando el timer dispara, handle_info lo captura:
def handle_info(:offer_expired, flight) do
  {closed_flight, cancelled_users} = Flight.close(flight, :expired)
  notify_users(cancelled_users, {:flight_closed, flight.id, :expired})
  {:noreply, closed_flight}
end
```

### `Alert` y `AlertIndex`

`Alert` es un struct con `origin`, `destination`, y opcionalmente `date` (fecha puntual) o `month` ({año, mes}).

`Alert.matches?/2` determina si una alerta aplica a un vuelo dado usando pattern matching sobre las combinaciones posibles de fecha/mes.

`AlertIndex` es un GenServer que guarda todas las alertas en un mapa. Su operación principal es `matching_users(flight)`: filtra las alertas que coinciden con el vuelo y devuelve los `user_id` únicos.

### `Router` — API HTTP

Usa `Plug.Router` (similar a Express en Node o Sinatra en Ruby) con `Bandit` como servidor HTTP. Cada endpoint recibe un `conn` (la conexión) y devuelve un `conn` con la respuesta.

El árbol de supervisión completo:

```
LevantarVuelo.Supervisor
├── Registry              ← mapea nombres a PIDs de FlightServers
├── AlertIndex            ← GenServer de alertas
└── Bandit (puerto 4000)  ← servidor HTTP → Router → handlers
    (los FlightServers los arranca el Router al recibir POST /flights)
```

---

## 5. API HTTP — endpoints y ejemplos

### Publicar un vuelo

```bash
curl -X POST http://localhost:4000/flights \
  -H "Content-Type: application/json" \
  -d '{
    "id": "fl_1",
    "airline": "Aerolineas",
    "origin": "EZE",
    "destination": "MAD",
    "departs_at": "2026-12-20T22:00:00Z",
    "offer_ends_at": "2026-11-01T18:00:00Z",
    "capacity": {"window": 40, "aisle": 40, "middle": 20}
  }'

# → 201 {"flight_id":"fl_1","notified_users":3}
# Si había alertas que coinciden, notified_users muestra cuántos fueron notificados
```

### Crear una alerta

```bash
# Alerta por destino (cualquier fecha)
curl -X POST http://localhost:4000/alerts \
  -H "Content-Type: application/json" \
  -d '{"id":"al_1","user_id":"u1","origin":"EZE","destination":"MAD"}'

# Alerta por mes
curl -X POST http://localhost:4000/alerts \
  -H "Content-Type: application/json" \
  -d '{"id":"al_2","user_id":"u2","origin":"EZE","destination":"MAD","month":{"year":2026,"month":12}}'

# → 201 {"alert_id":"al_1"}
```

### Eliminar una alerta

```bash
curl -X DELETE http://localhost:4000/alerts/al_1
# → 204 (sin cuerpo)
```

### Reservar un lugar (overbooking permitido)

```bash
curl -X POST http://localhost:4000/flights/fl_1/reservations \
  -H "Content-Type: application/json" \
  -d '{"reservation_id":"r1","user_id":"usuario_1"}'

# → 201 {"reservation_id":"r1"}
# → 410 si el vuelo ya está cerrado
```

### Elegir asientos

Los tipos posibles son `"window"`, `"aisle"`, `"middle"`, `"any"`.

```bash
# Pedir 2 ventanas y 1 pasillo
curl -X POST http://localhost:4000/flights/fl_1/reservations/r1/seats \
  -H "Content-Type: application/json" \
  -d '{"seats":["window","window","aisle"]}'

# → 200 {"assigned":["window","window","aisle"]}   compra confirmada
# → 409 {"error":"sin disponibilidad","available":{"window":0,"aisle":2,"middle":5}}
#        no había stock; available muestra qué queda para elegir de nuevo
# → 410 si la reserva fue cancelada (vuelo cerrado)
```

### Ver estado de un vuelo

```bash
curl http://localhost:4000/flights/fl_1

# → 200 {
#     "id": "fl_1",
#     "status": ":open",
#     "available": {"window":38,"aisle":40,"middle":20},
#     "reservations_count": 2
#   }
```

---

## 6. Tests

```bash
mix test
```

Los tests están organizados en tres archivos:

- `flight_test.exs` — tests del módulo puro `Flight`, incluido el **escenario A/B/C del enunciado** (A y B reservan, B compra la ventana, C reserva, A pide ventana y recibe 409, C pide cualquiera y recibe el pasillo, el vuelo se cierra y cancela a A).
- `flight_server_test.exs` — tests del proceso `FlightServer`, incluyendo el escenario completo a través de la API del proceso y el cierre automático por timer.
- `alert_test.exs` — tests de matching de alertas y del `AlertIndex`.

Los tests del `FlightServer` usan un ID único por test (generado con `:erlang.phash2` del nombre del test) para que varios tests puedan correr en paralelo sin chocarse en el Registry.

---

## 7. Qué falta para los próximos checkpoints

### Checkpoint 2 (29/10)

- **Distribución con Horde y libcluster**: clase el 15/10. Múltiples nodos, cualquier nodo puede atender cualquier vuelo, el estado sobrevive a la caída de un nodo.
- **Replicación del estado**: `ReplicaStore` + escritura sincrónica con quorum (mayoría de réplicas tiene que confirmar antes de responder al cliente).
- **Notificaciones en tiempo real**: SSE o WebSocket en vez de Logger.
- **Idempotencia en reservas**: si un cliente reintenta porque no sabe si su pedido llegó, no duplicar la reserva.
- **Límite de mailbox**: si un vuelo tiene demasiados mensajes encolados, responder 503 en vez de acumular sin límite.

### Entrega final (13/12)

- Monitoreo con Prometheus y Grafana (métricas de mailbox, reservas por segundo, latencia).
- Pruebas de carga con k6.
- Pruebas de caos: `docker kill` a un nodo con carga continua y verificar que las compras confirmadas no se pierden.
- Docker Compose con load balancer (nginx o HAProxy).
