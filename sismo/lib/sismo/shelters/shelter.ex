defmodule Sismo.Shelters.Shelter do
  @moduledoc """
  Estado de un albergue y sus reglas, en funciones puras.
  Las decisiones devuelven `{:ok, evento}` o `{:error, razón}`;
  `apply_event/2` aplica un evento ya validado; `replay/2` reconstruye el estado.
  La ocupación se DERIVA de `occupants`: no existe un contador aparte.
  """

  @enforce_keys [:code, :name, :zone, :capacity]
  defstruct [
    :code,
    :name,
    :zone,
    :capacity,
    occupants: MapSet.new(),
    resource_codes: MapSet.new(),
    need_ids: MapSet.new()
  ]

  @code_regex ~r/^[a-z0-9_]{1,40}$/
  @link_kinds %{"resource" => :resource, "need" => :need}

  ## Decisiones

  def create(code, name, zone, capacity, at) do
    with {:ok, code} <- normalize_code(code),
         {:ok, name} <- validate_text(name, :name),
         {:ok, zone} <- validate_text(zone, :zone),
         :ok <- validate_capacity(capacity) do
      {:ok, {:created, code, name, String.downcase(zone), capacity, at}}
    end
  end

  def enter(%__MODULE__{} = shelter, document, at) do
    with {:ok, doc} <- validate_text(document, :document),
         :ok <- ensure_outside(shelter, doc),
         :ok <- ensure_room(shelter) do
      {:ok, {:entered, doc, at}}
    end
  end

  def leave(%__MODULE__{} = shelter, document, at) do
    with {:ok, doc} <- validate_text(document, :document),
         :ok <- ensure_inside(shelter, doc) do
      {:ok, {:exited, doc, at}}
    end
  end

  @doc "Asocia un recurso o una necesidad al albergue, sin duplicados."
  def link(%__MODULE__{} = shelter, kind, ref) when kind in [:resource, :need] do
    with {:ok, ref} <- validate_text(ref, :ref),
         :ok <- ensure_not_linked(shelter, kind, ref) do
      {:ok, {:linked, kind, ref}}
    end
  end

  def link(_shelter, _kind, _ref), do: {:error, :invalid_kind}

  ## Aplicar eventos (total: un evento inaplicable se ignora)

  def apply_event(nil, {:created, code, name, zone, capacity, _at}),
    do: %__MODULE__{code: code, name: name, zone: zone, capacity: capacity}

  def apply_event(nil, _event), do: nil

  def apply_event(%__MODULE__{} = s, {:entered, doc, _at}),
    do: %{s | occupants: MapSet.put(s.occupants, doc)}

  def apply_event(%__MODULE__{} = s, {:exited, doc, _at}),
    do: %{s | occupants: MapSet.delete(s.occupants, doc)}

  def apply_event(%__MODULE__{} = s, {:linked, :resource, ref}),
    do: %{s | resource_codes: MapSet.put(s.resource_codes, ref)}

  def apply_event(%__MODULE__{} = s, {:linked, :need, ref}),
    do: %{s | need_ids: MapSet.put(s.need_ids, ref)}

  def apply_event(shelter, _unknown), do: shelter

  @doc "Recursión de cola sobre la lista de eventos. Empieza con `nil`."
  def replay(shelter, []), do: shelter
  def replay(shelter, [event | rest]), do: replay(apply_event(shelter, event), rest)

  ## Valores derivados

  def occupancy(%__MODULE__{occupants: occupants}), do: MapSet.size(occupants)
  def available(%__MODULE__{} = s), do: s.capacity - occupancy(s)
  def percent(%__MODULE__{} = s), do: Float.round(occupancy(s) * 100 / s.capacity, 1)

  def summary(%__MODULE__{} = s) do
    %{
      code: s.code,
      name: s.name,
      zone: s.zone,
      capacity: s.capacity,
      occupancy: occupancy(s),
      available: available(s),
      percent: percent(s),
      resources: Enum.sort(s.resource_codes),
      needs: Enum.sort(s.need_ids)
    }
  end

  ## Texto plano

  def to_fields({:created, code, name, zone, capacity, at}),
    do: ["shelter", code, name, zone, capacity, at]

  def to_fields({:entered, doc, at}), do: ["enter", doc, at]
  def to_fields({:exited, doc, at}), do: ["exit", doc, at]
  def to_fields({:linked, kind, ref}), do: ["link", Atom.to_string(kind), ref]

  def from_fields(["shelter", code, name, zone, capacity, at]) do
    case Integer.parse(capacity) do
      {n, ""} -> {:ok, {:created, code, name, zone, n, at}}
      _ -> {:error, :malformed_record}
    end
  end

  def from_fields(["enter", doc, at]), do: {:ok, {:entered, doc, at}}
  def from_fields(["exit", doc, at]), do: {:ok, {:exited, doc, at}}

  def from_fields(["link", kind, ref]) do
    case Map.fetch(@link_kinds, kind) do
      {:ok, kind} -> {:ok, {:linked, kind, ref}}
      :error -> {:error, :malformed_record}
    end
  end

  def from_fields(_), do: {:error, :malformed_record}

  ## Validaciones

  defp normalize_code(code) when is_binary(code) do
    code = code |> String.trim() |> String.downcase()
    if Regex.match?(@code_regex, code), do: {:ok, code}, else: {:error, {:invalid_field, :code}}
  end

  defp normalize_code(_), do: {:error, {:invalid_field, :code}}

  defp validate_text(value, field) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, {:invalid_field, field}}
      text -> {:ok, text}
    end
  end

  defp validate_text(_, field), do: {:error, {:invalid_field, field}}

  defp validate_capacity(c) when is_integer(c) and c > 0, do: :ok
  defp validate_capacity(_), do: {:error, :invalid_capacity}

  defp ensure_outside(s, doc),
    do: if(MapSet.member?(s.occupants, doc), do: {:error, :already_inside}, else: :ok)

  defp ensure_inside(s, doc),
    do: if(MapSet.member?(s.occupants, doc), do: :ok, else: {:error, :not_inside})

  defp ensure_room(s),
    do: if(occupancy(s) < s.capacity, do: :ok, else: {:error, :shelter_full})

  defp ensure_not_linked(s, kind, ref),
    do: if(MapSet.member?(linked(s, kind), ref), do: {:error, :already_linked}, else: :ok)

  defp linked(s, :resource), do: s.resource_codes
  defp linked(s, :need), do: s.need_ids
end
