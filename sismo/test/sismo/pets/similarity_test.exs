defmodule Sismo.Pets.SimilarityTest do
  use ExUnit.Case, async: true
  alias Sismo.Pets.{Report, Similarity}

  defp pet(attrs \\ %{}) do
    struct!(
      Report,
      Map.merge(
        %{
          id: "PT001", seq: 1, kind: :perdida, species: "perro", name: nil, color: "negra",
          size: :mediano, traits: "", zone: "norte", contact: "300", reporter: "x", created_at: "t"
        },
        attrs
      )
    )
  end

  defp found(attrs \\ %{}), do: pet(Map.merge(%{id: "PT002", seq: 2, kind: :encontrada}, attrs))

  test "coincidencia perfecta suma 100 y la especie distinta anula todo" do
    lost = pet(%{name: "Luna", traits: "collar rojo"})
    assert Similarity.score(lost, found(%{name: "LUNA", traits: "collar rojo"})) == 100

    assert %{total: 0, species: 0, color: 0} = Similarity.breakdown(lost, found(%{species: "gato"}))
    assert Similarity.score(lost, found(%{species: "gato"})) == 0
  end

  test "color: ignora género, da puntos parciales y 0 si no hay nada en común" do
    assert Similarity.breakdown(pet(), found(%{color: "negro"})).color == 25
    assert Similarity.breakdown(pet(%{color: "negro con blanco"}), found(%{color: "blanca"})).color == 12
    assert Similarity.breakdown(pet(%{color: "rojo"}), found(%{color: "azul"})).color == 0
  end

  test "tamaño, zona y nombre" do
    assert Similarity.breakdown(pet(%{size: :pequeno}), found(%{size: :pequeno})).size == 15
    assert Similarity.breakdown(pet(%{size: :pequeno}), found(%{size: :mediano})).size == 7
    assert Similarity.breakdown(pet(%{size: :pequeno}), found(%{size: :grande})).size == 0

    assert Similarity.breakdown(pet(), found()).zone == 15
    assert Similarity.breakdown(pet(), found(%{zone: "sur"})).zone == 0

    assert Similarity.breakdown(pet(%{name: "Luna"}), found(%{name: "luna"})).name == 10
    assert Similarity.breakdown(pet(%{name: "Luna"}), found(%{name: nil})).name == 0
    assert Similarity.breakdown(pet(%{name: "Luna"}), found(%{name: "Nube"})).name == 0
  end

  test "características: proporción de palabras en común" do
    lost = pet(%{traits: "collar rojo"})

    assert Similarity.breakdown(lost, found(%{traits: "collar rojo"})).traits == 5
    assert Similarity.breakdown(lost, found(%{traits: "collar rojo con placa"})).traits == 3
    assert Similarity.breakdown(lost, found(%{traits: "cola corta"})).traits == 0
    assert Similarity.breakdown(pet(), found()).traits == 0
  end

  test "ejemplo del enunciado: misma especie, color, tamaño y zona suman 85" do
    assert Similarity.score(pet(%{name: "Luna"}), found(%{color: "negro"})) == 85
  end
end
