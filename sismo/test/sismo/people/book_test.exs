defmodule Sismo.People.BookTest do
  use ExUnit.Case, async: true
  alias Sismo.People.Book
  alias Sismo.Persistence.Codec

  @at "2026-01-01T00:00:00Z"

  defp add(book, doc, name, zone, status) do
    {:ok, event} = Book.report(book, doc, name, 30, zone, status, "ciudadano", @at)
    Book.apply_event(book, event)
  end

  defp step(book, {:ok, event}), do: Book.apply_event(book, event)

  test "valida y normaliza los datos al reportar" do
    b = %Book{}

    assert {:ok, {:person_reported, "P001", 1, "1001", "Andrés", 30, "norte", :localizada, "ciudadano", @at}} =
             Book.report(b, " 1001 ", " Andrés ", 30, "Norte", "Localizada", "ciudadano", @at)

    assert {:ok, {:person_reported, _, _, _, _, nil, _, :sin_informacion, _, _}} =
             Book.report(b, "2", "Ana", nil, "norte", "sin información", "x", @at)

    assert {:error, {:invalid_field, :document}} = Book.report(b, " ", "A", 1, "z", "reportada", "x", @at)
    assert {:error, {:invalid_field, :name}} = Book.report(b, "1", " ", 1, "z", "reportada", "x", @at)
    assert {:error, :invalid_age} = Book.report(b, "1", "A", -1, "z", "reportada", "x", @at)
    assert {:error, :invalid_age} = Book.report(b, "1", "A", 200, "z", "reportada", "x", @at)
    assert {:error, {:invalid_field, :zone}} = Book.report(b, "1", "A", 1, "", "reportada", "x", @at)
    assert {:error, {:invalid_field, :status}} = Book.report(b, "1", "A", 1, "z", "perdida", "x", @at)

    b = add(b, "1001", "Andrés", "norte", "reportada")
    assert {:error, :duplicate_document} = Book.report(b, "1001", "Otro", 1, "z", "reportada", "x", @at)
  end

  test "transiciones válidas, historial y estado final" do
    b = add(%Book{}, "1001", "Andrés", "norte", "reportada")

    assert {:error, :person_not_found} = Book.change_status(b, "999", "localizada", "x", @at)
    assert {:error, {:invalid_field, :status}} = Book.change_status(b, "1001", "xx", "x", @at)
    assert {:error, {:invalid_transition, :reportada, :reportada}} = Book.change_status(b, "1001", "reportada", "x", @at)

    b = step(b, Book.change_status(b, "1001", "localizada", "laura", @at))
    assert {:error, {:invalid_transition, :localizada, :reportada}} = Book.change_status(b, "1001", "reportada", "x", @at)

    b = step(b, Book.change_status(b, "1001", "en_albergue", "voluntario", @at))
    b = step(b, Book.change_status(b, "1001", "reunificada", "laura", @at))
    assert {:error, {:invalid_transition, :reunificada, :localizada}} = Book.change_status(b, "1001", "localizada", "x", @at)

    assert {:ok, history} = Book.history(b, "1001")
    assert Enum.map(history, &elem(&1, 0)) == [:reportada, :localizada, :en_albergue, :reunificada]
    assert {_, _, "voluntario"} = Enum.at(history, 2)
  end

  test "búsqueda por nombre (sin tildes), documento, zona y estado" do
    b =
      %Book{}
      |> add("1", "Andrés Pérez", "norte", "localizada")
      |> add("2", "Ana Gómez", "norte", "reportada")
      |> add("3", "Luis Andrade", "sur", "localizada")

    assert {:ok, [%{document: "1"}]} = Book.search(b, name: "ANDRES")
    assert {:ok, [%{document: "1"}, %{document: "3"}]} = Book.search(b, name: "ANDR")
    assert {:ok, [%{document: "2"}]} = Book.search(b, document: " 2 ")
    assert {:ok, [%{document: "1"}, %{document: "2"}]} = Book.search(b, zone: "NORTE")
    assert {:ok, [%{document: "1"}]} = Book.search(b, zone: "norte", status: "localizada")
    assert {:ok, [_, _, _]} = Book.search(b, [])
    assert {:ok, []} = Book.search(b, name: "zzz")
    assert {:error, {:invalid_filter, :color}} = Book.search(b, color: "x")
    assert {:error, {:invalid_field, :name}} = Book.search(b, name: " ")
    assert {:error, {:invalid_field, :status}} = Book.search(b, status: "xx")
    assert %{localizada: 2, reportada: 1, reunificada: 0} = Book.counts(b)
  end

  test "mensajes: validación, orden y estado entregado/pendiente" do
    b = %Book{}

    assert {:error, {:invalid_field, :sender}} = Book.send_message(b, " ", "1", "hola", @at)
    assert {:error, {:invalid_field, :document}} = Book.send_message(b, "mamá", " ", "hola", @at)
    assert {:error, {:invalid_field, :content}} = Book.send_message(b, "mamá", "1", " ", @at)
    assert {:error, {:invalid_field, :content}} = Book.send_message(b, "mamá", "1", String.duplicate("x", 501), @at)

    b = step(b, Book.send_message(b, "mamá", "1", "Estoy bien", @at))
    b = step(b, Book.send_message(b, "papá", "1", "Te busco", @at))
    b = step(b, Book.send_message(b, "papá", "2", "Otro", @at))

    assert [%{id: "M001"}, %{id: "M002"}] = Book.messages_for(b, " 1 ")
    assert [] = Book.messages_for(b, "999")

    assert {:error, {:already, :pendiente}} = Book.set_message_status(b, "m001", "pendiente", @at)
    assert {:error, :message_not_found} = Book.set_message_status(b, "M999", "entregado", @at)
    assert {:error, {:invalid_field, :message_status}} = Book.set_message_status(b, "M001", "leido", @at)

    b = step(b, Book.set_message_status(b, "m001", "entregado", @at))
    assert %{status: :entregado} = b.messages["M001"]
    assert {:error, {:already, :entregado}} = Book.set_message_status(b, "M001", "entregado", @at)
  end

  test "to_fields/from_fields es reversible y replay reconstruye el estado" do
    events = [
      {:person_reported, "P001", 1, "1001", "Andrés | Pérez", nil, "norte", :reportada, "laura", @at},
      {:person_reported, "P002", 2, "1002", "Ana", 7, "sur", :localizada, "laura", @at},
      {:status_changed, "1001", :en_albergue, "voluntario", @at},
      {:message_sent, "M001", 1, "mamá", "1001", "línea1\nlínea2 | ok", @at},
      {:message_status, "M001", :entregado, @at}
    ]

    for event <- events do
      assert {:ok, ^event} =
               event |> Book.to_fields() |> Codec.encode_line() |> Codec.decode_line() |> Book.from_fields()
    end

    assert {:error, :malformed_record} = Book.from_fields(["person", "x"])
    assert {:error, :malformed_record} = Book.from_fields(["message", "M1", "no_numero", "a", "b", "c", @at])

    book = Book.replay(%Book{}, events)
    assert %{status: :en_albergue, age: nil, name: "Andrés | Pérez"} = book.persons["1001"]
    assert %{age: 7} = book.persons["1002"]
    assert %{status: :entregado, content: "línea1\nlínea2 | ok"} = book.messages["M001"]
    assert {book.seq, book.mseq} == {2, 1}
  end
end
