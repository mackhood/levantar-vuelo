# Debate y decisiones — Checkpoint 1

Este documento registra las decisiones que tomamos y los puntos que quedaron abiertos para discutir en equipo. Si no estás de acuerdo con algo o tenés una alternativa mejor, abrí una PR con tu razonamiento.

---

## Decisiones tomadas (y por qué)

### Un GenServer por vuelo

Elegimos tener un proceso actor por cada vuelo. Así la mailbox de ese proceso serializa todos los pedidos del vuelo y nunca se pueden vender dos asientos al mismo tiempo sin locks.

La alternativa sería un GenServer para todos los vuelos, pero todos los pedidos del sistema harían fila en una sola mailbox — un vuelo muy demandado bloquearía a todos los demás.

### Módulo `Flight` separado del `FlightServer`

La lógica de negocio (cuándo se puede asignar un asiento, cuándo coincide una alerta) vive en módulos puros sin procesos. El GenServer solo maneja mensajes y estado.

Ventaja: los tests del dominio corren sin levantar ningún proceso. Se puede testear `Flight.assign_seats` directamente.

### `handle_call` para todas las operaciones

Todas las operaciones de reserva y asignación usan `call` (sincrónico) porque necesitamos la respuesta antes de contestarle al usuario HTTP. Un 200 tiene que significar "tu compra está confirmada", no "tu pedido llegó a la cola".

### Notificaciones como best-effort

Si una notificación falla, se pierde. Lo aceptamos porque la notificación no es la fuente de verdad — el estado real siempre se puede consultar con `GET /flights/:id`.

---

## Puntos abiertos para debatir

### ¿`add` de alertas debería ser `cast`?

Hoy `AlertIndex.add` es `call` (sincrónico). En realidad no necesitamos esperar confirmación de que la alerta se guardó — podría ser `cast`.

**A favor de dejarlo como `call`:** más simple de razonar, menos casos borde.
**A favor de cambiarlo a `cast`:** si hay muchas alertas creándose al mismo tiempo, el cliente no se bloquea esperando.

¿Qué piensan?

### ¿Cómo organizamos la idempotencia en las reservas?

Si un cliente hace `POST /reservations` y no recibe respuesta (timeout de red), va a reintentar. Con el código actual eso crea dos reservas para el mismo usuario en el mismo vuelo.

Opciones:
- El cliente genera un `reservation_id` único y si ya existe devolvemos el mismo resultado (idempotencia por ID)
- El servidor genera el ID y el cliente tiene que consultar antes de reintentar

¿Cuál prefieren?

### ¿Validamos el body del POST en el router o en otro lado?

Hoy el router hace pattern matching directo sobre `conn.body_params` y explota con 500 si falta un campo. Deberíamos validar y devolver un 400 con un mensaje claro.

¿Lo hacemos en el router, o armamos un módulo de validación separado?

### Notificaciones: ¿cuándo pasamos de Logger a SSE real?

Las notificaciones son un Logger ahora. Para el checkpoint 2 necesitamos SSE o WebSocket real. ¿Alguien ya tiene experiencia con Phoenix Channels? Si la respuesta es sí, conviene migrar a Phoenix completo en el checkpoint 2 en lugar de hacer SSE manual con Plug.

---

## Lo que viene en el checkpoint 2 (29/10)

- Distribución con Horde y libcluster (clase el 15/10)
- Replicación del estado entre nodos con quorum
- Notificaciones en tiempo real (SSE o WebSocket)
- Idempotencia en reservas
- Límite de mailbox para no encolar sin límite bajo carga alta
