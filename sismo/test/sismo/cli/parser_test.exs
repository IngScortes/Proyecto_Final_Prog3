defmodule Sismo.CLI.ParserTest do
  use ExUnit.Case, async: true
  alias Sismo.CLI.Parser

  test "tokeniza respetando comillas, también dentro de un token" do
    assert {:ok, ["a", "b c", "d"]} = Parser.tokenize(~s(a "b c" d))
    assert {:ok, ["x", ""]} = Parser.tokenize(~s(x ""))
    assert {:ok, ["nombre=Ana Pérez"]} = Parser.tokenize(~s(nombre="Ana Pérez"))
    assert {:ok, []} = Parser.tokenize("   ")
    assert {:error, :unbalanced_quotes} = Parser.tokenize(~s(a "b))
  end

  test "parse separa el comando en minúsculas y descarta saltos de línea" do
    assert :empty = Parser.parse("  ")
    assert {:ok, {"connect", ["laura", "1234"]}} = Parser.parse("  CONNECT laura 1234\r\n")
    assert {:error, :unbalanced_quotes} = Parser.parse(~s(register_need "x))
  end

  test "split_opts reconoce solo las claves conocidas" do
    assert {["agua"], [zone: "centro", priority: "critica"]} =
             Parser.split_opts(["agua", "zona=centro", "prioridad=critica"])

    assert {["color=rojo"], []} = Parser.split_opts(["color=rojo"])
    assert {[], [zone: "a=b"]} = Parser.split_opts(["zona=a=b"])
  end
end
