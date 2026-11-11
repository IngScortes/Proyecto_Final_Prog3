defmodule Sismo.CLI.FormatTest do
  use ExUnit.Case, async: true
  alias Sismo.CLI.Format

  test "table alinea las columnas y maneja el caso vacío" do
    assert Format.table(["A", "B"], [[1, "xx"], [22, "y"]]) == "A   B\n--  --\n1   xx\n22  y"
    assert Format.table(["A"], []) == "(sin resultados)"
  end

  test "los errores se traducen a español" do
    assert Format.error({:insufficient_stock, 20}) =~ "Stock insuficiente"
    assert Format.error({:transfer_failed, :shelter_full}) =~ "lleno"
    assert Format.error({:usage, "x y"}) == "Uso: x y"
    assert Format.error(:algo_raro) =~ "Error:"
  end
end
