defmodule Sismo.Zones.TreeTest do
  use ExUnit.Case, async: true
  alias Sismo.Zones.{AttentionPoint, Sector, Tree, Zone}

  # s1 (50) ── s1a (20) ── s1a1 (10) ── punto p1
  # s2 (30) ── punto p2
  defp sample_zone do
    s1a1 = %Sector{id: "s1a1", name: "S1A1", estimated_affected: 10,
                   points: [%AttentionPoint{id: "p1", name: "Carpa", kind: "salud"}]}
    s1a = %Sector{id: "s1a", name: "S1A", estimated_affected: 20, subsectors: [s1a1]}
    s1 = %Sector{id: "s1", name: "S1", estimated_affected: 50, subsectors: [s1a]}
    s2 = %Sector{id: "s2", name: "S2", estimated_affected: 30,
                 points: [%AttentionPoint{id: "p2", name: "Acopio", kind: "agua"}]}

    %Zone{code: "centro", name: "Centro", level: :critico, estimated_affected: 100, sectors: [s1, s2]}
  end

  test "find_sector y update_sector llegan a cualquier profundidad y conservan el orden" do
    zone = sample_zone()

    assert {:ok, %Sector{name: "S1A1"}} = Tree.find_sector(zone.sectors, "s1a1")
    assert :error = Tree.find_sector(zone.sectors, "nope")

    {:ok, sectors} = Tree.update_sector(zone.sectors, "s1a1", &%{&1 | name: "Nuevo"})
    assert {:ok, %Sector{name: "Nuevo"}} = Tree.find_sector(sectors, "s1a1")
    assert Enum.map(sectors, & &1.id) == ["s1", "s2"]
    assert :error = Tree.update_sector(zone.sectors, "nope", & &1)
  end

  test "ids de todo el árbol" do
    zone = sample_zone()
    assert Enum.sort(Tree.sector_ids(zone.sectors)) == ["s1", "s1a", "s1a1", "s2"]
    assert Enum.sort(Tree.point_ids(zone.sectors)) == ["p1", "p2"]
  end

  test "las estadísticas se acumulan de abajo hacia arriba" do
    stats = Tree.zone_stats(sample_zone())

    assert stats.total_affected == 100 + 50 + 20 + 10 + 30
    assert stats.sectors == 4
    assert stats.points == 2
    assert stats.depth == 3

    s1 = Enum.find(stats.tree, &(&1.id == "s1"))
    assert s1.total_affected == 80
    assert s1.depth == 3
  end

  test "una zona sin sectores tiene estadísticas en cero" do
    stats = Tree.zone_stats(%Zone{code: "z", name: "Z", estimated_affected: 7})
    assert %{total_affected: 7, sectors: 0, points: 0, depth: 0, tree: []} = stats
  end
end
