defmodule LevantarVuelo.Router do
  use Plug.Router

  alias LevantarVuelo.{Alert, AlertIndex, FlightServer}

  plug Plug.Parsers,
    parsers: [:json],
    json_decoder: Jason

  plug :match
  plug :dispatch

  # --- Vuelos ---

  # POST /flights — publica un vuelo (F1) y notifica alertas coincidentes (F3)
  post "/flights" do
    %{"id" => id, "airline" => airline, "origin" => origin,
      "destination" => destination, "departs_at" => departs_at_str,
      "offer_ends_at" => offer_ends_at_str,
      "capacity" => %{"window" => w, "aisle" => a, "middle" => m}} = conn.body_params

    attrs = %{
      id: id,
      airline: airline,
      origin: origin,
      destination: destination,
      departs_at: parse_datetime!(departs_at_str),
      offer_ends_at: parse_datetime!(offer_ends_at_str),
      capacity: %{window: w, aisle: a, middle: m}
    }

    case FlightServer.start_link(attrs) do
      {:ok, _pid} ->
        # F3: busca usuarios con alertas que coinciden y los notifica
        flight = FlightServer.get(id)
        users = AlertIndex.matching_users(flight)
        notify_flight_published(users, id)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(201, Jason.encode!(%{flight_id: id, notified_users: length(users)}))

      {:error, {:already_started, _}} ->
        send_resp(conn, 409, Jason.encode!(%{error: "vuelo ya existe"}))
    end
  end

  # GET /flights/:id — estado y disponibilidad del vuelo
  get "/flights/:id" do
    case flight_or_404(conn, id) do
      {:ok, flight} ->
        body = %{
          id: flight.id,
          status: inspect(flight.status),
          available: flight.available,
          reservations_count: map_size(flight.reservations)
        }
        json(conn, 200, body)

      :not_found ->
        json(conn, 404, %{error: "vuelo no encontrado"})
    end
  end

  # --- Alertas ---

  # POST /alerts — crea una alerta (F2)
  post "/alerts" do
    %{"id" => id, "user_id" => user_id,
      "origin" => origin, "destination" => destination} = conn.body_params

    alert = Alert.new(%{
      id: id,
      user_id: user_id,
      origin: origin,
      destination: destination,
      date: parse_date(conn.body_params["date"]),
      month: parse_month(conn.body_params["month"])
    })

    {:ok, _} = AlertIndex.add(alert)
    json(conn, 201, %{alert_id: id})
  end

  # DELETE /alerts/:id — elimina una alerta
  delete "/alerts/:id" do
    AlertIndex.remove(id)
    send_resp(conn, 204, "")
  end

  # --- Reservas ---

  # POST /flights/:flight_id/reservations — reserva un lugar (F4)
  post "/flights/:flight_id/reservations" do
    %{"reservation_id" => rid, "user_id" => user_id} = conn.body_params

    case FlightServer.reserve(flight_id, user_id, rid) do
      {:ok, rid} ->
        json(conn, 201, %{reservation_id: rid})

      {:error, :flight_closed} ->
        json(conn, 410, %{error: "vuelo cerrado"})
    end
  end

  # POST /flights/:flight_id/reservations/:rid/seats — elige asientos (F5)
  post "/flights/:flight_id/reservations/:rid/seats" do
    wanted = conn.body_params["seats"] |> Enum.map(&String.to_atom/1)

    case FlightServer.assign_seats(flight_id, rid, wanted) do
      {:ok, assigned} ->
        json(conn, 200, %{assigned: Enum.map(assigned, &to_string/1)})

      {:error, :unavailable, disponibilidad} ->
        json(conn, 409, %{error: "sin disponibilidad", available: disponibilidad})

      {:error, :flight_closed} ->
        json(conn, 410, %{error: "vuelo cerrado"})

      {:error, reason} ->
        json(conn, 422, %{error: inspect(reason)})
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp flight_or_404(_conn, id) do
    case FlightServer.get(id) do
      nil -> :not_found
      flight -> {:ok, flight}
    end
  rescue
    _ -> :not_found
  end

  defp parse_datetime!(str) do
    {:ok, dt, _} = DateTime.from_iso8601(str)
    dt
  end

  defp parse_date(nil), do: nil
  defp parse_date(str), do: Date.from_iso8601!(str)

  defp parse_month(nil), do: nil
  defp parse_month(%{"year" => y, "month" => m}), do: {y, m}

  defp notify_flight_published(users, flight_id) do
    require Logger
    Enum.each(users, fn uid ->
      Logger.info("Notificando a #{uid}: nuevo vuelo #{flight_id}")
    end)
  end
end
