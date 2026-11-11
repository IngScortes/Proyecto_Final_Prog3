defmodule Sismo.CLI do
  @moduledoc """
  Consola interactiva y utilidades para simular varios usuarios a la vez.
  Cada usuario es un proceso distinto: su sesión se monitorea desde ese proceso.
  """
  alias Sismo.CLI.Commands

  @doc "Arranca la consola: `mix run -e \"Sismo.CLI.start()\"` o desde `iex -S mix`."
  def start do
    IO.puts("Sismo - gestión de emergencias. Escribe help para ver los comandos.")
    loop(Commands.new())
  end

  @doc "Ejecuta una lista de líneas. Devuelve `{[{estado, texto}], estado_final}`."
  def run_script(lines, state \\ Commands.new()) when is_list(lines) do
    Enum.map_reduce(lines, state, fn line, st ->
      {status, text, st} = Commands.run(st, line)
      {{status, text}, st}
    end)
  end

  @doc "Un script por usuario, cada uno en su propio proceso y todos a la vez."
  def parallel(scripts, timeout \\ 30_000) when is_list(scripts) do
    scripts
    |> Task.async_stream(
      fn lines ->
        {outputs, state} = run_script(lines)
        Commands.shutdown(state)
        outputs
      end,
      timeout: timeout,
      max_concurrency: max(length(scripts), 1)
    )
    |> Enum.map(fn {:ok, outputs} -> outputs end)
  end

  defp loop(state) do
    case IO.gets(prompt(state)) do
      line when is_binary(line) ->
        {status, text, state} = Commands.run(state, line)
        if text != "", do: IO.puts(text)
        if status == :quit, do: :ok, else: loop(state)

      _eof_or_error ->
        Commands.shutdown(state)
        :ok
    end
  end

  defp prompt(%{user: nil}), do: "sismo> "
  defp prompt(%{user: user}), do: "#{user}@sismo> "
end
