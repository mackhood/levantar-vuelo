# Checkpoint 1 — Dominio en un nodo

Fecha de entrega: 08/10/2026.

Este checkpoint implementa el dominio completo del sistema en un único nodo, sin distribución. La distribución viene en el checkpoint 2 (clase de libcluster/Horde el 15/10).

---

## Índice

1. [Qué hay en este checkpoint](#1-qué-hay-en-este-checkpoint)
2. [Cómo correrlo](#2-cómo-correrlo)
3. [Arquitectura de este checkpoint](#3-arquitectura-de-este-checkpoint)
4. [Estructura del código](#4-estructura-del-código)
5. [API HTTP — endpoints y ejemplos](#5-api-http--endpoints-y-ejemplos)
6. [Tests](#6-tests)
7. [Documentación del equipo](#7-documentación-del-equipo)

---

## 1. Qué hay en este checkpoint

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
- Distribución en múltiples nodos (Horde, libcluster)
- Replicación del estado entre nodos
- Notificaciones en tiempo real por SSE/WebSocket (por ahora son logs)
- Monitoreo con Prometheus/Grafana

---

## 2. Cómo correrlo

### Requisitos

- Elixir 1.14+ (usamos 1.20.4)
- Erlang/OTP 26+ (usamos OTP 29)

### Sin Docker

```bash
mix deps.get
mix test              # correr los tests
mix run --no-halt     # servidor en localhost:4000
```

### Con Docker

```bash
docker compose up --build
```

El servidor queda en `http://localhost:4000`.

### Consola interactiva

```bash
iex -S mix
```

Ejemplo rápido desde `iex`:

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

FlightServer.reserve("fl_1", "usuario_1", "r1")
FlightServer.assign_seats("fl_1", "r1", [:window])
FlightServer.get("fl_1")
```

---

## 3. Arquitectura de este checkpoint

### La idea central: un actor por vuelo

El único invariante duro del dominio es **no vender más asientos de un tipo que los disponibles**. Ese invariante vive dentro de un vuelo — ninguna operación involucra dos vuelos a la vez.

Cada vuelo es un `GenServer`. Su mailbox actúa como cola de pedidos y los procesa **de a uno**. Eso hace que "chequear disponibilidad y asignar" sea atómico sin locks.

```
Usuario A ──→ ┐
              mailbox del FlightServer → procesa de a uno
Usuario B ──→ ┘
```

Si llegan dos usuarios al mismo tiempo por el último asiento, uno llega primero al mailbox y se lo lleva. El otro llega cuando el stock ya cambió y recibe un 409.

### Dos capas: dominio puro y proceso

**Módulos puros** (`Flight`, `Alert`): funciones que reciben estado y devuelven estado nuevo. Sin procesos ni OTP. Testeables directamente.

**GenServers** (`FlightServer`, `AlertIndex`): procesos que guardan estado y atienden mensajes. Llaman a los módulos puros para ejecutar la lógica.

### El árbol de supervisión

```
LevantarVuelo.Supervisor
├── Registry          ← mapea nombres a PIDs de FlightServers
├── AlertIndex        ← GenServer que guarda todas las alertas
└── Bandit (4000)     ← servidor HTTP → Router
    (FlightServers se crean dinámicamente al recibir POST /flights)
```

Cuando un `FlightServer` explota por un bug, el `Supervisor` lo reinicia automáticamente. Es la filosofía "let it crash" de Erlang: no intentás prevenir todos los errores, dejás que el proceso muera y el supervisor lo levanta limpio.

### Timer de oferta (F6)

En `init/1`, el `FlightServer` calcula cuántos milisegundos faltan hasta `offer_ends_at` y programa el cierre:

```elixir
Process.send_after(self(), :offer_expired, ms)
```

Cuando llega ese mensaje, `handle_info` cancela las reservas pendientes y cierra el vuelo. Como `offer_ends_at` es un instante absoluto (no "en 3 horas"), si el proceso se reinicia recalcula cuánto falta desde ese instante.

---

## 4. Estructura del código

```
lib/
├── levantar_vuelo/
│   ├── application.ex      árbol de supervisión
│   ├── flight.ex           módulo puro: struct Flight + operaciones
│   ├── flight_server.ex    GenServer: proceso actor por vuelo
│   ├── alert.ex            módulo puro: struct Alert + matching
│   ├── alert_index.ex      GenServer: índice de alertas
│   └── router.ex           API HTTP con Plug
test/
└── levantar_vuelo/
    ├── flight_test.exs         tests del dominio puro (incluye escenario A/B/C)
    ├── flight_server_test.exs  tests del proceso
    └── alert_test.exs          tests de alertas y matching
```

### `Flight` — dominio puro del vuelo

```elixir
Flight.reserve(flight, user_id, reservation_id)
# {:ok, reservation_id, nuevo_flight} | {:error, :flight_closed}
# Overbooking permitido: no chequea stock.

Flight.assign_seats(flight, reservation_id, seats_wanted)
# {:ok, nuevo_flight, asientos_asignados}
# {:error, :unavailable, disponibilidad_actual}
# Todo o nada. Si quedan 0 asientos, cierra el vuelo automáticamente.

Flight.close(flight, reason)   # :sold_out | :expired
# {nuevo_flight, usuarios_cancelados}
# Cancela reservas pendientes y cierra el vuelo.
```

La asignación de `:any` usa primero asientos del medio, después pasillos, y por último ventanas — para preservar los tipos más pedidos para quienes los piden explícitamente.

### `FlightServer` — proceso actor del vuelo

Envuelve a `Flight` en un proceso. Se registra en el `Registry` con su ID de vuelo como nombre:

```elixir
{:via, Registry, {LevantarVuelo.Registry, flight_id}}
```

Así cualquier parte del sistema puede mandarle mensajes sin necesitar el PID.

### `Alert` y `AlertIndex`

`Alert.matches?/2` determina si una alerta aplica a un vuelo: mismo origen, mismo destino, y si tiene fecha o mes, que coincida.

`AlertIndex.matching_users(flight)` filtra todas las alertas y devuelve los `user_id` únicos que corresponden. Se llama cuando se publica un vuelo nuevo (F3).

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
```

### Crear una alerta

```bash
# Sin filtro de fecha (cualquier vuelo EZE→MAD)
curl -X POST http://localhost:4000/alerts \
  -H "Content-Type: application/json" \
  -d '{"id":"al_1","user_id":"u1","origin":"EZE","destination":"MAD"}'

# Filtro por mes
curl -X POST http://localhost:4000/alerts \
  -H "Content-Type: application/json" \
  -d '{"id":"al_2","user_id":"u2","origin":"EZE","destination":"MAD","month":{"year":2026,"month":12}}'

# → 201 {"alert_id":"al_1"}
```

### Eliminar una alerta

```bash
curl -X DELETE http://localhost:4000/alerts/al_1
# → 204
```

### Reservar

```bash
curl -X POST http://localhost:4000/flights/fl_1/reservations \
  -H "Content-Type: application/json" \
  -d '{"reservation_id":"r1","user_id":"usuario_1"}'
# → 201 {"reservation_id":"r1"}
# → 410 si el vuelo está cerrado
```

### Elegir asientos

Los tipos posibles: `"window"`, `"aisle"`, `"middle"`, `"any"`.

```bash
curl -X POST http://localhost:4000/flights/fl_1/reservations/r1/seats \
  -H "Content-Type: application/json" \
  -d '{"seats":["window","aisle"]}'
# → 200 {"assigned":["window","aisle"]}   compra confirmada
# → 409 {"error":"sin disponibilidad","available":{"window":0,"aisle":2,"middle":5}}
# → 410 si la reserva fue cancelada
```

### Estado del vuelo

```bash
curl http://localhost:4000/flights/fl_1
# → 200 {"id":"fl_1","status":":open","available":{"window":38,"aisle":40,"middle":20},"reservations_count":2}
```

---

## 6. Tests

```bash
mix test
```

27 tests en total:

- **`flight_test.exs`** — dominio puro. Incluye el **escenario A/B/C del enunciado**: A y B reservan, B compra la ventana, C reserva, A pide ventana y recibe error, C pide `:any` y recibe el pasillo, el vuelo se cierra y cancela a A.
- **`flight_server_test.exs`** — el mismo escenario a través del proceso, más el cierre automático por timer.
- **`alert_test.exs`** — matching de alertas por origen/destino/fecha/mes, y operaciones del `AlertIndex`.

---

## 7. Documentación del equipo

- [Tradeoffs](docs/tradeoffs.md) — decisiones de diseño y por qué las tomamos
- [Debate](docs/debate.md) — puntos abiertos para discutir en equipo
