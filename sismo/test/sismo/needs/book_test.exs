defmodule Sismo.Needs.BookTest do
  use ExUnit.Case, async: true
  alias Sismo.Needs.{Book, Need}
  alias Sismo.Persistence.Codec

  @at "2026-01-01T00:00:00Z"

  defp add(book, type, qty, priority, desc \\ "descripción") do
    {:ok, event} = Book.create(book, type, qty, priority, "Centro", desc, "laura", @at)
    Book.apply_event(book, event)
  end

  defp step(book, {:ok, event}), do: Book.apply_event(book, event)

  test "valida los datos antes de generar eventos" do
    b = %Book{}

    assert {:ok, {:need_created, "N001", 1, :agua, "d", 30, "centro", :critica, "laura", @at}} =
             Book.create(b, "Agua", 30, "crítica", "Centro", "d", "laura", @at)

    assert {:ok, {:need_created, _, _, :primeros_auxilios, _, _, _, _, _, _}} =
             Book.create(b, "primeros auxilios", 1, "alta", "z", "d", "x", @at)

    assert {:error, {:invalid_field, :type}} = Book.create(b, "lava", 1, "alta", "z", "d", "x", @at)
    assert {:error, :invalid_quantity} = Book.create(b, "agua", 0, "alta", "z", "d", "x", @at)
    assert {:error, :invalid_quantity} = Book.create(b, "agua", -3, "alta", "z", "d", "x", @at)
    assert {:error, {:invalid_field, :priority}} = Book.create(b, "agua", 1, "urgente", "z", "d", "x", @at)
    assert {:error, {:invalid_field, :description}} = Book.create(b, "agua", 1, "alta", "z", " ", "x", @at)
  end

  test "la cola ordena por prioridad y, a igual prioridad, por antigüedad" do
    book =
      %Book{}
      |> add("agua", 5, "baja")
      |> add("agua", 5, "critica")
      |> add("agua", 5, "alta")
      |> add("agua", 5, "critica")

    assert Enum.map(Book.queue(book), & &1.id) == ["N002", "N004", "N003", "N001"]
  end

  test "máquina de estados: transiciones válidas y cierre único" do
    book = add(%Book{}, "agua", 30, "critica")

    assert {:error, {:invalid_transition, :pendiente, :atendida}} = Book.transition(book, "N001", :atendida, @at)
    assert {:error, :invalid_status} = Book.transition(book, "N001", :asignada, @at)
    assert {:error, :need_not_found} = Book.transition(book, "N999", :cancelada, @at)

    book = Book.apply_event(book, {:assigned, "N001", "c1", "R001", 10, "N001:1", @at})
    assert %{status: :asignada} = book.needs["N001"]

    book = step(book, Book.transition(book, "N001", :en_atencion, @at))
    book = step(book, Book.transition(book, "N001", :atendida, @at))

    assert {:error, {:invalid_transition, :atendida, :atendida}} = Book.transition(book, "N001", :atendida, @at)
    assert {:error, {:invalid_transition, :atendida, :cancelada}} = Book.transition(book, "N001", :cancelada, @at)
    assert {:error, {:not_assignable, :atendida}} = Book.check_assign(book, "N001", "c1", "R001", 1)
  end

  test "las asignaciones no pueden exceder lo pendiente y usan referencias únicas" do
    book = add(%Book{}, "agua", 30, "alta")

    assert {:ok, %{ref: "N001:1", center: "c1"}} = Book.check_assign(book, "n001", "C1", "R001", 10)
    assert {:error, :invalid_quantity} = Book.check_assign(book, "N001", "c1", "R001", 0)
    assert {:error, {:exceeds_remaining, 30}} = Book.check_assign(book, "N001", "c1", "R001", 31)

    book = Book.apply_event(book, {:assigned, "N001", "c1", "R001", 10, "N001:1", @at})

    assert Need.remaining(book.needs["N001"]) == 20
    assert {:error, {:exceeds_remaining, 20}} = Book.check_assign(book, "N001", "c1", "R001", 25)
    assert {:ok, %{ref: "N001:2"}} = Book.check_assign(book, "N001", "c1", "R001", 20)
  end

  test "una necesidad totalmente cubierta sale de la cola, una parcial permanece" do
    book = %Book{} |> add("agua", 10, "alta") |> add("agua", 10, "alta")
    book = Book.apply_event(book, {:assigned, "N001", "c1", "R001", 10, "N001:1", @at})
    book = Book.apply_event(book, {:assigned, "N002", "c1", "R001", 4, "N002:1", @at})

    assert Enum.map(Book.queue(book), & &1.id) == ["N002"]
  end

  test "query filtra por zona, tipo, prioridad y estado" do
    book = %Book{} |> add("agua", 5, "critica") |> add("alimentos", 5, "critica") |> add("agua", 5, "baja")

    assert {:ok, [%{id: "N001"}, %{id: "N003"}]} = Book.query(book, type: "agua")
    assert {:ok, [%{id: "N001"}, %{id: "N002"}]} = Book.query(book, priority: "critica", zone: "CENTRO")
    assert {:ok, []} = Book.query(book, status: "atendida")
    assert {:ok, [_, _, _]} = Book.query(book, [])
    assert {:error, {:invalid_filter, :color}} = Book.query(book, color: "rojo")
    assert {:error, {:invalid_field, :priority}} = Book.query(book, priority: "xx")
  end

  test "to_fields/from_fields es reversible y replay reconstruye el estado" do
    events = [
      {:need_created, "N001", 1, :agua, "a|b\nc", 30, "centro", :critica, "laura", @at},
      {:assigned, "N001", "c1", "R001", 10, "N001:1", @at},
      {:status_changed, "N001", :en_atencion, @at}
    ]

    for event <- events do
      assert {:ok, ^event} =
               event |> Book.to_fields() |> Codec.encode_line() |> Codec.decode_line() |> Book.from_fields()
    end

    assert {:error, :malformed_record} = Book.from_fields(["need", "x"])

    book = Book.replay(%Book{}, events)
    assert %{status: :en_atencion, description: "a|b\nc"} = book.needs["N001"]
    assert book.seq == 1
    assert Book.counts(book).en_atencion == 1
  end
end
