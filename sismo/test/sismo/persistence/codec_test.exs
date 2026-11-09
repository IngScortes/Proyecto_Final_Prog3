defmodule Sismo.Persistence.CodecTest do
  use ExUnit.Case, async: true
  alias Sismo.Persistence.Codec

  test "roundtrip con separadores, barras, saltos de línea y unicode" do
    fields = ["a|b", "c\\d", "línea1\nlínea2", "", "ñandú"]
    assert fields |> Codec.encode_line() |> Codec.decode_line() == fields
  end

  test "el encoding nunca contiene saltos de línea reales" do
    refute Codec.encode_line(["a\nb", "c"]) =~ "\n"
  end
end
