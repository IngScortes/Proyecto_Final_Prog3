defmodule Sismo.Shelters.ShelterTest do
  use ExUnit.Case, async: true
  alias Sismo.Persistence.Codec
  alias Sismo.Shelters.Shelter

  @at "2026-01-01T00:00:00Z"

  defp shelter(capacity \\ 2) do
    {:ok, event} = Shelter.create(" A01 ", "Albergue | Norte", "Zona_Norte", capacity, @at)
    Shelter.apply_event(nil, event)
  end

  defp step(s, {:ok, event}), do: Shelter.apply_event(s, event)

  test "valida los datos al crear y normaliza código y zona" do
    assert {:ok, {:created, "a01", "Albergue Norte", "zona_norte", 150, @at}} =
             Shelter.create(" A01 ", "Albergue Norte", "Zona_Norte", 150, @at)

    assert {:error, {:invalid_field, :code}} = Shelter.create("A 01", "n", "z", 10, @at)
    assert {:error, {:invalid_field, :name}} = Shelter.create("a01", " ", "z", 10, @at)
    assert {:error, {:invalid_field, :zone}} = Shelter.create("a01", "n", "", 10, @at)
    assert {:error, :invalid_capacity} = Shelter.create("a01", "n", "z", 0, @at)
    assert {:error, :invalid_capacity} = Shelter.create("a01", "n", "z", -5, @at)
    assert {:error, :invalid_capacity} = Shelter.create("a01", "n", "z", "10", @at)
  end

  test "la ocupación se deriva del conjunto y respeta la capacidad" do
    s = shelter(2)
    assert Shelter.available(s) == 2

    s = step(s, Shelter.enter(s, "111", @at))
    s = step(s, Shelter.enter(s, " 222 ", @at))

    assert Shelter.occupancy(s) == 2
    assert Shelter.available(s) == 0
    assert Shelter.percent(s) == 100.0
    assert MapSet.member?(s.occupants, "222")

    assert {:error, :shelter_full} = Shelter.enter(s, "333", @at)
    assert {:error, :already_inside} = Shelter.enter(s, "111", @at)
    assert {:error, {:invalid_field, :document}} = Shelter.enter(s, " ", @at)
  end

  test "las salidas liberan cupo y no se pueden repetir" do
    s = shelter(2)
    s = step(s, Shelter.enter(s, "111", @at))

    assert {:error, :not_inside} = Shelter.leave(s, "999", @at)

    s = step(s, Shelter.leave(s, "111", @at))
    assert Shelter.occupancy(s) == 0
    assert Shelter.percent(s) == 0.0
    assert {:error, :not_inside} = Shelter.leave(s, "111", @at)
  end

  test "asocia recursos y necesidades sin duplicar" do
    s = shelter()
    assert {:ok, {:linked, :resource, "R001"}} = Shelter.link(s, :resource, "R001")

    s = step(s, Shelter.link(s, :need, "N001"))

    assert {:error, :already_linked} = Shelter.link(s, :need, "N001")
    assert {:error, :invalid_kind} = Shelter.link(s, :otra, "x")
    assert {:error, {:invalid_field, :ref}} = Shelter.link(s, :need, " ")
    assert %{needs: ["N001"], resources: []} = Shelter.summary(s)
  end

  test "to_fields/from_fields es reversible y replay reconstruye el estado" do
    events = [
      {:created, "a01", "Albergue | Norte", "zona_norte", 3, @at},
      {:entered, "111", @at},
      {:entered, "222", @at},
      {:exited, "111", @at},
      {:linked, :resource, "R001"},
      {:linked, :need, "N001"}
    ]

    for event <- events do
      assert {:ok, ^event} =
               event
               |> Shelter.to_fields()
               |> Codec.encode_line()
               |> Codec.decode_line()
               |> Shelter.from_fields()
    end

    assert {:error, :malformed_record} = Shelter.from_fields(["shelter", "a01", "x", "z", "mucho", @at])
    assert {:error, :malformed_record} = Shelter.from_fields(["nope"])

    s = Shelter.replay(nil, events)
    assert s.name == "Albergue | Norte"
    assert Shelter.occupancy(s) == 1
    assert MapSet.member?(s.occupants, "222")

    # Sin encabezado no hay albergue, y un segundo encabezado se ignora.
    assert Shelter.replay(nil, [{:entered, "111", @at}]) == nil
    assert Shelter.replay(s, [{:created, "otro", "x", "z", 9, @at}]) == s
  end
end
