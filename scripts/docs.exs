# The API part of the docs gate, run by scripts/check.exs as `mix run --no-start scripts/docs.exs` (MIX_ENV=test):
# every module of the application has a @moduledoc and every public function and macro a @doc. `@moduledoc false`
# and `@doc false` mark private API, which is not documented; callbacks implemented with `@impl` are documented by
# their behaviour. Exits 1 and lists every undocumented item. Factory-owned file: agents must not edit it.

defmodule Docs do
  @moduledoc false

  def undocumented(app) do
    {:ok, modules} = :application.get_key(app, :modules)
    modules |> Enum.sort() |> Enum.flat_map(&module_errors/1)
  end

  defp module_errors(module) do
    case Code.fetch_docs(module) do
      {:docs_v1, _, _, _, :hidden, _, _} ->
        []

      {:docs_v1, _, _, _, moduledoc, _, entries} ->
        missing = if moduledoc == :none, do: ["#{inspect(module)} has no @moduledoc"], else: []

        missing ++
          for {{kind, name, arity}, _, _, :none, _} <- entries,
              kind in [:function, :macro],
              not String.starts_with?(Atom.to_string(name), "_"),
              do: "#{inspect(module)}.#{name}/#{arity} has no @doc"

      {:error, reason} ->
        ["#{inspect(module)} has no documentation chunk (#{inspect(reason)})"]
    end
  end
end

app = Mix.Project.config()[:app]

case Application.load(app) do
  :ok -> :ok
  {:error, {:already_loaded, ^app}} -> :ok
end

case Docs.undocumented(app) do
  [] ->
    IO.puts("docs: every public module, function and macro of #{app} is documented")

  errors ->
    Enum.each(errors, &IO.puts(:stderr, "docs: #{&1}"))
    System.halt(1)
end
