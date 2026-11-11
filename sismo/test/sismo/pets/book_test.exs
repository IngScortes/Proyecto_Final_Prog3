defmodule Sismo.Pets.BookTest do
  use ExUnit.Case, async: true
  alias Sismo.Persistence.Codec
  alias Sismo.Pets.Book

  @at "2026-01-01T00:00:00Z"
  @base %{
    kind: "lost", species: "perro", name: "Luna", color: "negra",
    size: "mediana", zone: "norte", contact: "300"
  }

  defp add(book, attrs \\ %{}) do
    {:ok, event} = Book.report(book, Map.merge(@base, attrs), "voluntario", @at)
    Book.apply_event(book, event)
  end

  defp step(book, {:ok, event}), do: Book.apply_event(book, event)

  test "valida y normaliza los datos al reportar" do
    b = %Book{}
    attrs = %{@base | kind: " LOST ", species: " Perro ", color: "Negra", zone: "Zona_Norte"}

    assert {:ok,
            {:pet_reported, "PT001", 1, :perdida, "perro", "Luna", "negra", :mediano, "",
             "zona_norte", "300", "voluntario", @at}} = Book.report(b, attrs, "voluntario", @at)

    found = Map.merge(@base, %{kind: "found", name: "Desconocido", size: "pequeño", traits: " collar rojo "})

    assert {:ok, {:pet_reported, _, _, :encontrada, _, nil, _, :pequeno, "collar rojo", _, _, _, _}} =
             Book.report(b, found, "v", @at)

    assert {:error, {:invalid_field, :kind}} = Book.report(b, %{@base | kind: "otra"}, "v", @at)
    assert {:error, {:invalid_field, :species}} = Book.report(b, %{@base | species: " "}, "v", @at)
    assert {:error, {:invalid_field, :color}} = Book.report(b, %{@base | color: nil}, "v", @at)
    assert {:error, {:invalid_field, :size}} = Book.report(b, %{@base | size: "enorme"}, "v", @at)
    assert {:error, {:invalid_field, :zone}} = Book.report(b, %{@base | zone: ""}, "v", @at)
    assert {:error, {:invalid_field, :contact}} = Book.report(b, %{@base | contact: " "}, "v", @at)
    assert {:error, {:invalid_field, :name}} = Book.report(b, %{@base | name: 123}, "v", @at)
    assert {:error, {:invalid_field, :traits}} = Book.report(b, Map.put(@base, :traits, 5), "v", @at)
    assert {:error, {:invalid_field, :reporter}} = Book.report(b, @base, " ", @at)
  end

  test "propose, reject y confirm: reglas y cierre único" do
    # PT001 perdida, PT002 y PT003 encontradas
    b = %Book{} |> add() |> add(%{kind: "found", name: nil}) |> add(%{kind: "found", name: nil, color: "negro"})

    assert {:error, :invalid_pair} = Book.propose(b, "PT002", "PT003", @at)
    assert {:error, :report_not_found} = Book.propose(b, "PT001", "PT999", @at)
    assert {:ok, {:pet_proposed, "PT001", "PT002", @at}} = Book.propose(b, "pt002", "pt001", @at)

    b = step(b, Book.propose(b, "PT001", "PT002", @at))
    assert %{status: :posible_coincidencia, matched_with: "PT002"} = b.reports["PT001"]
    assert %{status: :posible_coincidencia, matched_with: "PT001"} = b.reports["PT002"]
    assert %{status: :activa} = b.reports["PT003"]

    assert {:error, {:already_proposed, "PT001"}} = Book.propose(b, "PT001", "PT003", @at)
    assert {:error, {:matched_with_other, "PT001"}} = Book.confirm(b, "PT001", "PT003", @at)
    assert {:error, :not_proposed} = Book.reject(b, "PT001", "PT003", @at)

    rejected = step(b, Book.reject(b, "PT001", "PT002", @at))
    assert %{status: :activa, matched_with: nil} = rejected.reports["PT001"]

    b = step(b, Book.confirm(b, "PT001", "PT002", @at))
    assert %{status: :resuelta, matched_with: "PT002"} = b.reports["PT001"]
    assert %{status: :resuelta, matched_with: "PT001"} = b.reports["PT002"]
    assert Enum.map(b.reports["PT001"].history, &elem(&1, 0)) == [:resuelta, :posible_coincidencia, :activa]

    for op <- [:propose, :reject, :confirm] do
      assert {:error, {:already_resolved, "PT001"}} = apply(Book, op, [b, "PT001", "PT003", @at])
    end

    # Se puede confirmar directamente sin proponer antes.
    direct = %Book{} |> add() |> add(%{kind: "found"})
    direct = step(direct, Book.confirm(direct, "PT001", "PT002", @at))
    assert %{status: :resuelta} = direct.reports["PT002"]
  end

  test "búsqueda por especie, zona, estado y tipo; reportes abiertos y conteos" do
    b =
      %Book{}
      |> add()
      |> add(%{kind: "found", species: "gato", zone: "sur"})
      |> add(%{kind: "found"})

    assert {:ok, [%{id: "PT001"}, %{id: "PT003"}]} = Book.search(b, species: "PERRO")
    assert {:ok, [%{id: "PT002"}]} = Book.search(b, zone: "SUR")
    assert {:ok, [_, _, _]} = Book.search(b, status: "activa")
    assert {:ok, [%{id: "PT002"}, %{id: "PT003"}]} = Book.search(b, kind: "found")
    assert {:ok, [%{id: "PT003"}]} = Book.search(b, kind: "encontrada", species: "perro")
    assert {:ok, []} = Book.search(b, status: "resuelta")
    assert {:error, {:invalid_filter, :color}} = Book.search(b, color: "x")
    assert {:error, {:invalid_field, :status}} = Book.search(b, status: "xx")
    assert {:error, {:invalid_field, :kind}} = Book.search(b, kind: "xx")

    assert {[%{id: "PT001"}], [%{id: "PT002"}, %{id: "PT003"}]} = Book.open_reports(b)
    assert %{activa: 3, posible_coincidencia: 0, resuelta: 0} = Book.counts(b)
  end

  test "to_fields/from_fields es reversible y replay reconstruye el estado" do
    reported1 = {:pet_reported, "PT001", 1, :perdida, "perro", "Luna | Dos", "negra", :mediano, "collar\nrojo", "norte", "300|1", "x", @at}
    reported2 = {:pet_reported, "PT002", 2, :encontrada, "gato", nil, "gris", :pequeno, "", "sur", "c", "x", @at}
    proposed = {:pet_proposed, "PT001", "PT002", @at}
    rejected = {:pet_rejected, "PT001", "PT002", @at}
    resolved = {:pet_resolved, "PT001", "PT002", @at}

    for event <- [reported1, reported2, proposed, rejected, resolved] do
      assert {:ok, ^event} =
               event |> Book.to_fields() |> Codec.encode_line() |> Codec.decode_line() |> Book.from_fields()
    end

    assert {:error, :malformed_record} = Book.from_fields(["pet", "x"])

    assert {:error, :malformed_record} =
             Book.from_fields(["pet", "PT1", "no", "perdida", "perro", "", "negra", "mediano", "", "n", "c", "x", @at])

    book = Book.replay(%Book{}, [reported1, reported2, proposed, resolved])
    assert %{status: :resuelta, matched_with: "PT002", name: "Luna | Dos"} = book.reports["PT001"]
    assert %{name: nil, size: :pequeno} = book.reports["PT002"]
    assert book.seq == 2
  end
end
