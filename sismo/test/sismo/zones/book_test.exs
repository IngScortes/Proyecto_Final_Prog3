defmodule Sismo.Zones.BookTest do
  use ExUnit.Case, async: true
  alias Sismo.Persistence.Codec
  alias Sismo.Zones.{Book, Tree}

  @events [
    {:zone_created, "centro", "Centro | Norte", :critico, 10},
    {:sector_added, "centro", "s1", nil, "Sector 1", 5},
    {:sector_added, "centro", "s2", "s1", "Sub", 2},
    {:point_added, "centro", "s2", "p1", "Hospital", "salud"},
    {:level_set, "centro", :alto},
    {:affected_set, "centro", 7},
    {:linked, "centro", :shelter, "A01"}
  ]

  test "valida los datos antes de generar eventos" do
    b = %Book{}

    assert {:ok, {:zone_created, "centro", "Centro", :critico, 5}} =
             Book.create_zone(b, " Centro ", " Centro ", "crítico", 5)

    assert {:error, {:invalid_field, :code}} = Book.create_zone(b, "Mi Zona!", "x", "alto", 0)
    assert {:error, {:invalid_field, :name}} = Book.create_zone(b, "z", " ", "alto", 0)
    assert {:error, {:invalid_field, :level}} = Book.create_zone(b, "z", "x", "apocalipsis", 0)
    assert {:error, :invalid_quantity} = Book.create_zone(b, "z", "x", "alto", -1)
    assert {:error, :zone_not_found} = Book.add_sector(b, "nope", nil, "s1", "S1", 0)
  end

  test "to_fields/from_fields es reversible, incluso con separadores en el texto" do
    for event <- @events do
      assert {:ok, ^event} =
               event |> Book.to_fields() |> Codec.encode_line() |> Codec.decode_line() |> Book.from_fields()
    end

    assert {:error, :malformed_record} = Book.from_fields(["zone", "x"])
  end

  test "replay reconstruye la jerarquía" do
    zone = Book.replay(%Book{}, @events).zones["centro"]

    assert zone.level == :alto
    assert zone.estimated_affected == 7
    assert MapSet.member?(zone.shelter_codes, "A01")
    assert {:ok, %{name: "Sub", points: [%{id: "p1"}]}} = Tree.find_sector(zone.sectors, "s2")
    assert [%{id: "s1", subsectors: [%{id: "s2"}]}] = zone.sectors
  end
end
