defmodule Sismo.Pets.Similarity do
  @moduledoc """
  Puntaje de similitud entre un reporte de mascota perdida y uno de encontrada.
  Es una función pura: no depende de procesos, así que se puede ejecutar en paralelo.
  """
  alias Sismo.Pets.Report

  @species_pts 30
  @color_pts 25
  @color_partial_pts 12
  @size_pts 15
  @size_adjacent_pts 7
  @zone_pts 15
  @name_pts 10
  @traits_pts 5

  @size_rank %{pequeno: 0, mediano: 1, grande: 2}

  @doc "Desglose por atributo y `:total` (0..100). Si la especie difiere, todo es 0."
  def breakdown(%Report{} = lost, %Report{} = found) do
    if lost.species == found.species do
      parts = %{
        species: @species_pts,
        color: color_points(lost.color, found.color),
        size: size_points(lost.size, found.size),
        zone: if(lost.zone == found.zone, do: @zone_pts, else: 0),
        name: name_points(lost.name, found.name),
        traits: traits_points(lost.traits, found.traits)
      }

      Map.put(parts, :total, parts |> Map.values() |> Enum.sum())
    else
      %{species: 0, color: 0, size: 0, zone: 0, name: 0, traits: 0, total: 0}
    end
  end

  def score(%Report{} = lost, %Report{} = found), do: breakdown(lost, found).total

  ## Normalización de texto

  @doc "Sin mayúsculas ni tildes: \"Andrés\" -> \"andres\"."
  def fold(text) when is_binary(text) do
    text
    |> String.downcase()
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.trim()
  end

  @doc "Conjunto de palabras (mínimo 3 letras) sin la vocal final de género."
  def tokens(text) when is_binary(text) do
    text
    |> fold()
    |> String.split(~r/[^a-z0-9]+/, trim: true)
    |> Enum.filter(&(String.length(&1) >= 3))
    |> Enum.map(&stem/1)
    |> MapSet.new()
  end

  def tokens(_), do: MapSet.new()

  defp stem(token) do
    if String.length(token) > 3 and String.ends_with?(token, ["a", "o"]),
      do: String.slice(token, 0, String.length(token) - 1),
      else: token
  end

  ## Puntos por atributo

  defp color_points(a, b) do
    a = tokens(a)
    b = tokens(b)

    cond do
      MapSet.size(a) == 0 or MapSet.size(b) == 0 -> 0
      MapSet.equal?(a, b) -> @color_pts
      not MapSet.disjoint?(a, b) -> @color_partial_pts
      true -> 0
    end
  end

  defp size_points(a, b) do
    case abs(Map.fetch!(@size_rank, a) - Map.fetch!(@size_rank, b)) do
      0 -> @size_pts
      1 -> @size_adjacent_pts
      _ -> 0
    end
  end

  defp name_points(a, b) when is_binary(a) and is_binary(b),
    do: if(fold(a) == fold(b), do: @name_pts, else: 0)

  defp name_points(_a, _b), do: 0

  defp traits_points(a, b) do
    a = tokens(a)
    b = tokens(b)
    union = MapSet.size(MapSet.union(a, b))

    if union == 0,
      do: 0,
      else: round(@traits_pts * MapSet.size(MapSet.intersection(a, b)) / union)
  end
end
