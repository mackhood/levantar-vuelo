defmodule LevantarVuelo.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: LevantarVuelo.Registry},
      LevantarVuelo.AlertIndex,
      {Bandit, plug: LevantarVuelo.Router, port: 4000}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: LevantarVuelo.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
