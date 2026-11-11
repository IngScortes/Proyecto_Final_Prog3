defmodule Sismo.CLI.Parser do
  @moduledoc """
  Convierte una línea de texto en comando y argumentos. Las comillas dobles agrupan
  palabras, incluso dentro de un token (`nombre="Ana Pérez"`).
  """

  @option_keys %{
    "zona" => :zone, "zone" => :zone,
    "tipo" => :type, "type" => :type,
    "prioridad" => :priority, "priority" => :priority,
    "estado" => :status, "status" => :status,
    "especie" => :species, "species" => :species,
    "nombre" => :name, "name" => :name,
    "documento" => :document,
    "categoria" => :category, "category" => :category,
    "umbral" => :threshold, "threshold" => :threshold,
    "parent" => :parent, "padre" => :parent
  }

  @spec parse(String.t()) :: :empty | {:ok, {String.t(), [String.t()]}} | {:error, atom()}
  def parse(line) when is_binary(line) do
    case tokenize(line) do
      {:ok, []} -> :empty
      {:ok, [name | args]} -> {:ok, {String.downcase(name), args}}
      {:error, _} = error -> error
    end
  end

  def tokenize(line) when is_binary(line), do: tok(String.trim(line), "", false, false, [])

  # Recursión sobre el binario: (resto, token actual, ¿dentro de comillas?, ¿hay token?, acumulado)
  defp tok(<<>>, _cur, true, _has, _acc), do: {:error, :unbalanced_quotes}
  defp tok(<<>>, cur, false, has, acc), do: {:ok, Enum.reverse(push(acc, cur, has))}
  defp tok(<<?", rest::binary>>, cur, quoted, _has, acc), do: tok(rest, cur, not quoted, true, acc)

  defp tok(<<c, rest::binary>>, cur, false, has, acc) when c in [?\s, ?\t, ?\r, ?\n],
    do: tok(rest, "", false, false, push(acc, cur, has))

  defp tok(<<c::utf8, rest::binary>>, cur, quoted, _has, acc),
    do: tok(rest, cur <> <<c::utf8>>, quoted, true, acc)

  # Byte que no es UTF-8 válido: se descarta.
  defp tok(<<_, rest::binary>>, cur, quoted, has, acc), do: tok(rest, cur, quoted, has, acc)

  defp push(acc, cur, true), do: [cur | acc]
  defp push(acc, _cur, false), do: acc

  @doc """
  Separa `{posicionales, opciones}`. Solo se reconocen las claves conocidas;
  cualquier otro `a=b` queda como argumento posicional.
  """
  def split_opts(args) when is_list(args), do: split(args, [], [])

  defp split([], pos, opts), do: {Enum.reverse(pos), Enum.reverse(opts)}

  defp split([arg | rest], pos, opts) do
    with [key, value] <- String.split(arg, "=", parts: 2),
         {:ok, atom} <- Map.fetch(@option_keys, String.downcase(key)) do
      split(rest, pos, [{atom, value} | opts])
    else
      _ -> split(rest, [arg | pos], opts)
    end
  end
end
