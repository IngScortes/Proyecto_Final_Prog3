defmodule Sismo.Zones.Book do
  @moduledoc """
  Estado de todas las zonas y sus reglas, en funciones puras.
  Las funciones de decisión devuelven `{:ok, evento}` o `{:error, razón}`;
  `apply_event/2` aplica un evento ya validado; `replay/2` reconstruye el estado.
  """
  alias Sismo.Zones.{AttentionPoint, Sector, Tree, Zone}

  defstruct zones: %{}

  @id_regex ~r/^[a-z0-9_]{1,40}$/
  @levels %{
    "critico" => :critico,
    "crítico" => :critico,
    "alto" => :alto,
    "medio" => :medio,
    "bajo" => :bajo
  }
  @rank %{critico: 0, alto: 1, medio: 2, bajo: 3}
  @link_kinds %{"shelter" => :shelter, "need" => :need, "report" => :report}

  def level_rank(level), do: Map.fetch!(@rank, level)

  ## Consultas

  def fetch_zone(%__MODULE__{} = book, code) do
    case Map.fetch(book.zones, canon(code)) do
      {:ok, zone} -> {:ok, zone}
      :error -> {:error, :zone_not_found}
    end
  end

  ## Decisiones

  def create_zone(%__MODULE__{} = book, code, name, level, affected) do
    with {:ok, code} <- normalize_id(code, :code),
         {:ok, name} <- validate_text(name, :name),
         {:ok, level} <- parse_level(level),
         :ok <- validate_non_negative(affected),
         :ok <- ensure_absent(book, code) do
      {:ok, {:zone_created, code, name, level, affected}}
    end
  end

  def add_sector(%__MODULE__{} = book, zone, parent, id, name, affected) do
    with {:ok, z} <- fetch_zone(book, zone),
         {:ok, id} <- normalize_id(id, :id),
         {:ok, name} <- validate_text(name, :name),
         :ok <- validate_non_negative(affected),
         {:ok, parent} <- check_parent(z, parent),
         :ok <- ensure_new(id, Tree.sector_ids(z.sectors)) do
      {:ok, {:sector_added, z.code, id, parent, name, affected}}
    end
  end

  def add_point(%__MODULE__{} = book, zone, sector_id, id, name, kind) do
    with {:ok, z} <- fetch_zone(book, zone),
         sector_id = canon(sector_id),
         {:ok, _sector} <- find_sector(z, sector_id),
         {:ok, id} <- normalize_id(id, :id),
         {:ok, name} <- validate_text(name, :name),
         {:ok, kind} <- validate_text(kind, :kind),
         :ok <- ensure_new(id, Tree.point_ids(z.sectors)) do
      {:ok, {:point_added, z.code, sector_id, id, name, kind}}
    end
  end

  def set_level(%__MODULE__{} = book, zone, level) do
    with {:ok, z} <- fetch_zone(book, zone),
         {:ok, level} <- parse_level(level) do
      {:ok, {:level_set, z.code, level}}
    end
  end

  def set_affected(%__MODULE__{} = book, zone, affected) do
    with {:ok, z} <- fetch_zone(book, zone),
         :ok <- validate_non_negative(affected) do
      {:ok, {:affected_set, z.code, affected}}
    end
  end

  @doc "Asocia un albergue, necesidad o reporte a la zona. No permite asociar dos veces lo mismo."
  def link(%__MODULE__{} = book, zone, kind, ref) when kind in [:shelter, :need, :report] do
    with {:ok, z} <- fetch_zone(book, zone),
         {:ok, ref} <- validate_text(ref, :ref),
         :ok <- ensure_not_linked(z, kind, ref) do
      {:ok, {:linked, z.code, kind, ref}}
    end
  end

  def link(_book, _zone, _kind, _ref), do: {:error, :invalid_kind}

  ## Aplicar eventos (total: un evento inaplicable se ignora)

  def apply_event(book, {:zone_created, code, name, level, affected}) do
    zone = %Zone{code: code, name: name, level: level, estimated_affected: affected}
    %{book | zones: Map.put(book.zones, code, zone)}
  end

  def apply_event(book, {:sector_added, zone, id, parent, name, affected}) do
    sector = %Sector{id: id, name: name, estimated_affected: affected}

    update_zone(book, zone, fn z ->
      case parent do
        nil ->
          %{z | sectors: z.sectors ++ [sector]}

        parent_id ->
          add = fn s -> %{s | subsectors: s.subsectors ++ [sector]} end

          case Tree.update_sector(z.sectors, parent_id, add) do
            {:ok, sectors} -> %{z | sectors: sectors}
            :error -> z
          end
      end
    end)
  end

  def apply_event(book, {:point_added, zone, sector_id, id, name, kind}) do
    point = %AttentionPoint{id: id, name: name, kind: kind}

    update_zone(book, zone, fn z ->
      case Tree.update_sector(z.sectors, sector_id, &%{&1 | points: &1.points ++ [point]}) do
        {:ok, sectors} -> %{z | sectors: sectors}
        :error -> z
      end
    end)
  end

  def apply_event(book, {:level_set, zone, level}),
    do: update_zone(book, zone, &%{&1 | level: level})

  def apply_event(book, {:affected_set, zone, n}),
    do: update_zone(book, zone, &%{&1 | estimated_affected: n})

  def apply_event(book, {:linked, zone, :shelter, ref}),
    do: update_zone(book, zone, &%{&1 | shelter_codes: MapSet.put(&1.shelter_codes, ref)})

  def apply_event(book, {:linked, zone, :need, ref}),
    do: update_zone(book, zone, &%{&1 | need_ids: MapSet.put(&1.need_ids, ref)})

  def apply_event(book, {:linked, zone, :report, ref}),
    do: update_zone(book, zone, &%{&1 | report_ids: MapSet.put(&1.report_ids, ref)})

  def apply_event(book, _unknown), do: book

  @doc "Recursión de cola sobre la lista de eventos."
  def replay(%__MODULE__{} = book, []), do: book
  def replay(%__MODULE__{} = book, [event | rest]), do: replay(apply_event(book, event), rest)

  ## Codificación a texto plano

  def to_fields({:zone_created, code, name, level, affected}),
    do: ["zone", code, name, Atom.to_string(level), affected]

  def to_fields({:sector_added, zone, id, parent, name, affected}),
    do: ["sector", zone, id, parent || "", name, affected]

  def to_fields({:point_added, zone, sector_id, id, name, kind}),
    do: ["point", zone, sector_id, id, name, kind]

  def to_fields({:level_set, zone, level}), do: ["level", zone, Atom.to_string(level)]
  def to_fields({:affected_set, zone, n}), do: ["affected", zone, n]
  def to_fields({:linked, zone, kind, ref}), do: ["link", zone, Atom.to_string(kind), ref]

  def from_fields(["zone", code, name, level, affected]) do
    with {:ok, level} <- parse_level(level), {affected, ""} <- Integer.parse(affected) do
      {:ok, {:zone_created, code, name, level, affected}}
    else
      _ -> {:error, :malformed_record}
    end
  end

  def from_fields(["sector", zone, id, parent, name, affected]) do
    case Integer.parse(affected) do
      {n, ""} -> {:ok, {:sector_added, zone, id, if(parent == "", do: nil, else: parent), name, n}}
      _ -> {:error, :malformed_record}
    end
  end

  def from_fields(["point", zone, sector_id, id, name, kind]),
    do: {:ok, {:point_added, zone, sector_id, id, name, kind}}

  def from_fields(["level", zone, level]) do
    case parse_level(level) do
      {:ok, level} -> {:ok, {:level_set, zone, level}}
      _ -> {:error, :malformed_record}
    end
  end

  def from_fields(["affected", zone, n]) do
    case Integer.parse(n) do
      {n, ""} -> {:ok, {:affected_set, zone, n}}
      _ -> {:error, :malformed_record}
    end
  end

  def from_fields(["link", zone, kind, ref]) do
    case Map.fetch(@link_kinds, kind) do
      {:ok, kind} -> {:ok, {:linked, zone, kind, ref}}
      :error -> {:error, :malformed_record}
    end
  end

  def from_fields(_), do: {:error, :malformed_record}

  ## Validaciones

  def parse_level(level) when is_atom(level) and not is_nil(level),
    do: level |> Atom.to_string() |> parse_level()

  def parse_level(level) when is_binary(level) do
    case Map.fetch(@levels, level |> String.trim() |> String.downcase()) do
      {:ok, parsed} -> {:ok, parsed}
      :error -> {:error, {:invalid_field, :level}}
    end
  end

  def parse_level(_), do: {:error, {:invalid_field, :level}}

  defp canon(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp canon(_), do: nil

  defp normalize_id(value, field) do
    id = canon(value)

    if is_binary(id) and Regex.match?(@id_regex, id),
      do: {:ok, id},
      else: {:error, {:invalid_field, field}}
  end

  defp validate_text(value, field) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, {:invalid_field, field}}
      text -> {:ok, text}
    end
  end

  defp validate_text(_, field), do: {:error, {:invalid_field, field}}

  defp validate_non_negative(n) when is_integer(n) and n >= 0, do: :ok
  defp validate_non_negative(_), do: {:error, :invalid_quantity}

  defp ensure_absent(book, code),
    do: if(Map.has_key?(book.zones, code), do: {:error, :duplicate_code}, else: :ok)

  defp ensure_new(id, ids), do: if(id in ids, do: {:error, :duplicate_id}, else: :ok)

  defp check_parent(_zone, nil), do: {:ok, nil}

  defp check_parent(zone, parent) do
    parent = canon(parent)

    case Tree.find_sector(zone.sectors, parent) do
      {:ok, _} -> {:ok, parent}
      :error -> {:error, :parent_not_found}
    end
  end

  defp find_sector(zone, sector_id) do
    case Tree.find_sector(zone.sectors, sector_id) do
      {:ok, sector} -> {:ok, sector}
      :error -> {:error, :sector_not_found}
    end
  end

  defp ensure_not_linked(zone, kind, ref) do
    if MapSet.member?(linked(zone, kind), ref), do: {:error, :already_linked}, else: :ok
  end

  defp linked(zone, :shelter), do: zone.shelter_codes
  defp linked(zone, :need), do: zone.need_ids
  defp linked(zone, :report), do: zone.report_ids

  defp update_zone(book, code, fun) do
    case Map.fetch(book.zones, code) do
      {:ok, zone} -> %{book | zones: Map.put(book.zones, code, fun.(zone))}
      :error -> book
    end
  end
end
