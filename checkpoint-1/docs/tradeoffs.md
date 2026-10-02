# Decisiones de diseño y tradeoffs — Checkpoint 1

Este documento registra las decisiones que tomamos, por qué las tomamos y qué alternativas descartamos. La idea es que cualquier integrante del grupo pueda entender el razonamiento detrás del código sin tener que leerlo línea por línea.

---

## 1. Un GenServer por vuelo vs uno para todos

**Decisión: un `FlightServer` por vuelo.**

**Por qué:**
El invariante crítico del sistema es no vender dos veces el mismo asiento. Ese invariante vive dentro de un vuelo — ninguna operación involucra dos vuelos a la vez.

Un GenServer procesa mensajes de a uno (su mailbox serializa los pedidos). Si tenemos un proceso por vuelo, la serialización se aplica exactamente donde la necesitamos: dentro de cada vuelo. Dos usuarios compitiendo por el mismo asiento hacen fila en la mailbox de ese vuelo. Dos usuarios en vuelos distintos no se bloquean entre sí — sus procesos corren en paralelo en distintos cores.

**Alternativa descartada: un único GenServer para todos los vuelos.**
Todos los pedidos del sistema harían fila en una sola mailbox. Un vuelo muy demandado bloquearía las operaciones de todos los demás. No escala.

---

## 2. Módulo puro `Flight` separado del proceso `FlightServer`

**Decisión: separar la lógica de negocio (módulo puro) del proceso (GenServer).**

**Por qué:**
`Flight` contiene funciones que reciben un estado y devuelven uno nuevo, sin efectos de red ni procesos. Eso las hace testeables directamente: podés llamar `Flight.assign_seats(estado, ...)` en un test sin levantar ningún proceso.

El `FlightServer` solo se ocupa de recibir mensajes, llamar a `Flight`, y guardar el nuevo estado. Si mezcláramos todo en el GenServer, para testear que "no se puede asignar más asientos de los disponibles" tendríamos que levantar un proceso con Registry y timers.

**Alternativa descartada: toda la lógica dentro del GenServer.**
Más simple al principio, pero los tests se complican y la lógica de negocio queda acoplada a OTP.

---

## 3. `handle_call` vs `handle_cast` para las operaciones del vuelo

**Decisión: `handle_call` (sincrónico) para todas las operaciones.**

**Por qué:**
`handle_call` bloquea al que llama hasta recibir respuesta. `handle_cast` es fire-and-forget.

Para `reserve` y `assign_seats` necesitamos saber el resultado antes de responderle al usuario HTTP. Si usáramos `cast` para `assign_seats`, el endpoint devolvería un 200 inmediatamente sin saber si el asiento se asignó o hubo un error. El 200 tiene que significar "tu compra está confirmada", no "tu pedido llegó a la cola".

**Cuándo tiene sentido `cast`:**
Para las notificaciones. No necesitamos saber cuándo llegan, solo que eventualmente lleguen. Hoy usamos Logger sincrónico como placeholder — cuando reemplacemos eso por SSE/WebSocket real, el envío va a ir en procesos separados (ver tradeoff 5).

---

## 4. Overbooking permitido en las reservas

**Decisión: `reserve` no chequea stock, cualquiera puede reservar.**

**Por qué:**
El enunciado lo pide explícitamente (F4). Una reserva no es una compra — solo guarda el lugar en la cola. La compra real ocurre cuando se eligen asientos (`assign_seats`), y ahí sí se chequea disponibilidad.

Esto simplifica el modelo: reservar siempre funciona (salvo que el vuelo esté cerrado), y la competencia real por los asientos ocurre en un único punto del sistema.

---

## 5. Notificaciones sincrónicas dentro del FlightServer (limitación actual)

**Decisión actual: notificar dentro del `handle_call`, con Logger como placeholder.**

**Problema conocido:**
Cuando se cierra un vuelo, el `FlightServer` recorre todos los usuarios y los notifica antes de atender el próximo mensaje. Con muchos usuarios esto bloquea el proceso durante ese tiempo.

**Por qué lo dejamos así en el checkpoint 1:**
Las notificaciones reales (SSE/WebSocket) van en el checkpoint 2. Hoy el Logger es un placeholder que prueba que el flujo funciona. No tiene sentido optimizar algo que vamos a reemplazar.

**Solución para el checkpoint 2:**
Mover el fan-out a un proceso separado (`Notifier`). El `FlightServer` le manda un mensaje al `Notifier` con la lista de usuarios y vuelve a atender pedidos inmediatamente. El `Notifier` lanza un `Task.start` por usuario, que corren en paralelo en todos los cores.

**Tradeoff de las notificaciones: best-effort, no garantizadas.**
Si una notificación falla, se pierde. Aceptamos esto porque la notificación no es la fuente de verdad — el usuario siempre puede consultar el estado del vuelo con `GET /flights/:id`. Garantizar entrega requeriría un inbox persistente (mencionado en el enunciado como opcional).

---

## 6. `AlertIndex` con `handle_call` para `add` y `remove`

**Decisión: `call` para todas las operaciones del `AlertIndex`.**

**Por qué:**
`matching_users` tiene que ser `call` obligatoriamente — necesitamos la lista de usuarios para saber a quién notificar.

`add` y `remove` podrían ser `cast` (no necesitamos esperar confirmación). Los dejamos como `call` por simplicidad: es más fácil razonar sobre el sistema cuando las escrituras son sincrónicas, y la frecuencia de creación/borrado de alertas no justifica la optimización.

**Cuándo cambiar `add` a `cast`:**
Si las pruebas de carga mostraran que crear alertas es un cuello de botella (improbable — las alertas se crean una vez y raramente).

---

## 7. Plug + Bandit vs Phoenix

**Decisión: Plug + Bandit, sin Phoenix.**

**Por qué:**
Phoenix trae muchas cosas que no necesitamos: templates HTML, Ecto, LiveView, assets. Para una API REST pura, Plug es suficiente y más liviano.

Bandit es el servidor HTTP recomendado actualmente en el ecosistema Elixir (más moderno que Cowboy).

**Cuándo reconsiderar:**
Si en el checkpoint 2 queremos usar Phoenix Channels para WebSocket, conviene migrar a Phoenix en ese momento porque los Channels están integrados con su router y PubSub. Plug + Bandit también soporta WebSocket, pero es más manual.

---

## 8. Registry local vs Horde para encontrar los FlightServers

**Decisión: `Registry` de Elixir (un nodo) para el checkpoint 1.**

**Por qué:**
El `Registry` de Elixir resuelve el problema de encontrar un proceso por nombre dentro de un único nodo. No requiere dependencias externas.

**Limitación:**
Solo funciona en un nodo. Si el `FlightServer` del vuelo 17 está en el nodo B y el request llega al nodo A, el `Registry` local del nodo A no lo encuentra.

**Solución para el checkpoint 2 (distribución):**
Reemplazar `Registry` por `Horde.Registry`, que mantiene un registro distribuido entre todos los nodos del cluster. El cambio es mínimo — solo cambia la línea del `via`:
```elixir
# Hoy:
{:via, Registry, {LevantarVuelo.Registry, flight_id}}
# Checkpoint 2:
{:via, Horde.Registry, {LevantarVuelo.Registry, flight_id}}
```

---

## 9. CAP: CP para asientos, AP para alertas

**Decisión: consistencia fuerte para asientos y reservas, disponibilidad para alertas.**

**Asientos → CP:**
Vender dos veces el mismo asiento es el peor error posible para el negocio — no se puede deshacer fácilmente y afecta directamente al pasajero. Preferimos rechazar una operación (503) antes que arriesgarnos a una doble venta. En el checkpoint 1 esto lo garantiza la mailbox del actor. En el checkpoint 2 lo garantiza la replicación con quorum.

**Alertas → AP:**
Crear una alerta siempre debería funcionar. Si una alerta tarda unos milisegundos en propagarse a todos los nodos, lo peor que pasa es que alguien no reciba la notificación de un vuelo publicado justo en ese instante. No es catastrófico. Por eso en el checkpoint 2 las alertas van con `DeltaCrdt` (replicación eventual) en lugar de quorum.

---

## Resumen de decisiones pendientes para los próximos checkpoints

| Decisión | Checkpoint |
|---|---|
| Reemplazar `Registry` por `Horde.Registry` para distribución | 2 |
| Agregar `Horde.DynamicSupervisor` para reiniciar vuelos en otro nodo si se cae el actual | 2 |
| Reemplazar Logger de notificaciones por SSE/WebSocket | 2 |
| Mover el fan-out de notificaciones al `Notifier` con `Task.start` | 2 |
| Idempotencia en reservas (evitar duplicados si el cliente reintenta) | 2 |
| Replicación del estado del vuelo entre nodos con quorum | 2 |
| Alertas con `DeltaCrdt` replicado en todos los nodos | 2 |
| Métricas con Prometheus/Grafana | Final |
| Pruebas de carga con k6 | Final |
| Pruebas de caos (docker kill con carga continua) | Final |
