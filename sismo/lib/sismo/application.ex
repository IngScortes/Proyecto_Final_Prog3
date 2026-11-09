defmodule Sismo.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Starts a worker by calling: Sismo.Worker.start_link(arg)
      # {Sismo.Worker, arg}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Sismo.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
# lib/sismo/application.ex
defmodule Sismo.Application do
  use Application

  @impl true
  def start(_type, _args) do
    data_dir = Application.get_env(:sismo, :data_dir, "data")

    children = [
      {Registry, keys: :unique, name: Sismo.Registry},
      {Sismo.Persistence.Writer, []},
      {Sismo.Activity.Log, data_dir: data_dir},
      {Sismo.Users.Server, data_dir: data_dir},
      {Task.Supervisor, name: Sismo.TaskSupervisor}
      # Fases siguientes: Zones.Server, CenterSupervisor, ShelterSupervisor,
      # Needs.Server, People.Server, Pets.Server
    ]

    Supervisor.start_link(children, strategy: :rest_for_one, name: Sismo.Supervisor)
  end
end
