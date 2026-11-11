defmodule Sismo.Shelters.Report do
  @moduledoc """
  Consultas sobre todos los albergues. Cada albergue se consulta en una tarea
  distinta, así que un albergue lento no bloquea a los demás.
  El resultado es una foto aproximada: los albergues siguen cambiando mientras se consulta.
  """
  alias Sismo.Shelters.{ShelterSupervisor, Server}

  @doc "Resumen de cada albergue. Opciones: `:zone`, `:codes`, `:task_supervisor`."
  def all(opts \\ []) do
    codes = Keyword.get_lazy(opts, :codes, &ShelterSupervisor.codes/0)
    supervisor = Keyword.get(opts, :task_supervisor, Sismo.TaskSupervisor)

    supervisor
    |> Task.Supervisor.async_stream_nolink(codes, &Server.info/1,
      timeout: 5_000,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, {:ok, info}} -> [info]
      _failed_or_gone -> []
    end)
    |> filter_zone(Keyword.get(opts, :zone))
  end

  @doc "Los `n` albergues con mayor porcentaje de ocupación."
  def top_occupied(n \\ 5, opts \\ []) when is_integer(n) and n > 0 do
    opts
    |> all()
    |> Enum.sort_by(&{-&1.percent, -&1.occupancy, &1.code})
    |> Enum.take(n)
  end

  @doc "Albergues con cupos libres, los que tienen más espacio primero."
  def with_space(opts \\ []) do
    opts
    |> all()
    |> Enum.filter(&(&1.available > 0))
    |> Enum.sort_by(&{-&1.available, &1.code})
  end

  defp filter_zone(infos, nil), do: infos

  defp filter_zone(infos, zone) do
    zone = zone |> String.trim() |> String.downcase()
    Enum.filter(infos, &(&1.zone == zone))
  end
end
