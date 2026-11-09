defmodule Sismo.Persistence.Codec do
  @moduledoc "Formato de texto plano: un registro por línea, campos separados por `|`."

  @spec encode_line([term()]) :: String.t()
  def encode_line(fields) when is_list(fields) do
    fields |> Enum.map(&(&1 |> to_string() |> escape())) |> Enum.join("|")
  end

  @spec decode_line(String.t()) :: [String.t()]
  def decode_line(line) when is_binary(line), do: do_decode(line, "", [])

  defp escape(s) do
    s
    |> String.replace("\\", "\\\\")
    |> String.replace("|", "\\p")
    |> String.replace("\n", "\\n")
  end

  # Recursión sobre el binario, un carácter a la vez.
  defp do_decode("", acc, fields), do: Enum.reverse([acc | fields])

  defp do_decode(<<"\\", c::utf8, rest::binary>>, acc, fields),
    do: do_decode(rest, acc <> unescape(c), fields)

  defp do_decode(<<"|", rest::binary>>, acc, fields), do: do_decode(rest, "", [acc | fields])

  defp do_decode(<<c::utf8, rest::binary>>, acc, fields),
    do: do_decode(rest, acc <> <<c::utf8>>, fields)

  defp unescape(?n), do: "\n"
  defp unescape(?p), do: "|"
  defp unescape(?\\), do: "\\"
  defp unescape(other), do: <<other::utf8>>
end
