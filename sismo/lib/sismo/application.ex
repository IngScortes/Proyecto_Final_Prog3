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
      {Task.Supervisor, name: Sismo.TaskSupervisor},
      Sismo.Resources.CenterSupervisor,
      {Sismo.Users.Server, data_dir: data_dir},
      {Sismo.Zones.Server, data_dir: data_dir},
      {Sismo.Needs.Server, data_dir: data_dir}
    ]

    with {:ok, sup} <-
           Supervisor.start_link(children, strategy: :rest_for_one, name: Sismo.Supervisor) do
      Sismo.Resources.CenterSupervisor.restore_all(data_dir)
      Sismo.Needs.Server.reconcile_links()
      {:ok, sup}
    end
  end
end
