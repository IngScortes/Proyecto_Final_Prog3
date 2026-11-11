defmodule Sismo.Resources.Inventory do
  @moduledoc """
  Consultas sobre todos los centros. Cada centro se consulta en una tarea distinta
  (`Task.Supervisor`). El resultado es una foto aproximada, no atómica.
  """
  alias Sismo.Pets.Similarity
  alias Sismo.Resources.Center

  @doc "Ids de los centros vivos, ordenados."
  def center_ids do
    Sismo.Registry
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.flat_map(fn
      {:center, id} -> [id]
      _other -> []
    end)
    |> Enum.sort()
  end

  def snapshots(opts \\ []) do
    supervisor = Keyword.get(opts, :task_supervisor, Sismo.TaskSupervisor)

    supervisor
    |> Task.Supervisor.async_stream_nolink(center_ids(), &Center.snapshot/1,
      timeout: 5_000,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, %{resources: _} = snapshot} -> [snapshot]
      _failed_or_gone -> []
    end)
  end

  @doc "Todos los recursos de todos los centros. Filtros: `:zone` y `:category` (código, nombre o categoría)."
  def list(filters \\ [], opts \\ []) do
    zone = filters |> Keyword.get(:zone) |> zone_key()
    category = Keyword.get(filters, :category)

    opts
    |> snapshots()
    |> Enum.flat_map(fn snap -> Enum.map(snap.resources, &entry(snap, &1)) end)
    |> Enum.filter(fn e ->
      (zone == nil or e.zone == zone) and (category == nil or matches?(e, category))
    end)
    |> Enum.sort_by(&{&1.center, &1.code})
  end

  @doc "Recursos que coinciden con `term`; primero los de la zona dada y luego los de más stock."
  def candidates(term, zone \\ nil, opts \\ []) do
    []
    |> list(opts)
    |> Enum.filter(&matches?(&1, term))
    |> Enum.sort_by(&{&1.zone != zone, -&1.available, &1.center, &1.code})
  end

  def matches?(entry, term) when is_binary(term) do
    needle = norm(term)
    needle != "" and needle in [norm(entry.category), norm(entry.name), norm(entry.code)]
  end

  defp entry(snap, r) do
    %{
      center: snap.id, zone: snap.zone, code: r.code, name: r.name,
      category: r.category, unit: r.unit, available: r.available
    }
  end

  defp zone_key(nil), do: nil
  defp zone_key(zone) when is_binary(zone), do: zone |> String.trim() |> String.downcase()

  defp norm(text), do: text |> Similarity.fold() |> String.replace("_", " ")
end
