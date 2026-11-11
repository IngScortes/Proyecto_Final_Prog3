defmodule Sismo.Pets.Matcher do
  @moduledoc """
  Busca coincidencias entre mascotas perdidas y encontradas.
  Toma una foto de los reportes activos y puntúa cada par en una tarea distinta
  (`Task.Supervisor`). No modifica nada: proponer y confirmar son pasos explícitos.
  Si entre tanto un reporte cambia de estado, `propose/3` lo rechaza al validar.
  """
  alias Sismo.Pets.{Server, Similarity}

  @default_threshold 50

  @doc "Opciones: `:threshold` (por defecto 50), `:server`, `:task_supervisor`."
  def find(opts \\ []) do
    server = Keyword.get(opts, :server, Server)
    supervisor = Keyword.get(opts, :task_supervisor, Sismo.TaskSupervisor)
    threshold = Keyword.get(opts, :threshold, @default_threshold)

    {lost, found} = Server.open_reports(server)
    pairs = for l <- lost, f <- found, do: {l, f}

    supervisor
    |> Task.Supervisor.async_stream_nolink(pairs, &score_pair/1,
      timeout: 5_000,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, %{score: score} = candidate} when score >= threshold -> [candidate]
      _below_threshold_or_failed -> []
    end)
    |> Enum.sort_by(&{-&1.score, &1.lost, &1.found})
  end

  defp score_pair({lost, found}) do
    breakdown = Similarity.breakdown(lost, found)

    %{
      lost: lost.id,
      found: found.id,
      score: breakdown.total,
      breakdown: Map.delete(breakdown, :total)
    }
  end
end
