# Adds one Hex dependency for the factory: `elixir scripts/add_dependency.exs [--dev] <package> [<spec>]`.
#
# The spec is the allowed range of the item (empty, an exact version, `==x`, `>=x` or `>=x,<y`); it is written as an
# Elixir requirement (`>= x and < y`; an exact version or `==x` becomes `== x`; empty becomes `>= 0.0.0`): a runtime
# dependency to the deps of mix.exs, a `--dev` one with `only: [:dev, :test]`. Then `mix deps.get` pins the newest
# release inside the range in mix.lock and fetches it. When it fails, mix.exs and mix.lock are restored. No shell:
# mix runs with an argument list. Factory-owned file: agents must not edit it.

defmodule AddDependency do
  @moduledoc false

  @mix_exs "mix.exs"
  @lock "mix.lock"
  # Hex's package name rule.
  @name ~r/\A[a-z][a-z0-9_]*\z/
  @usage "usage: elixir scripts/add_dependency.exs [--dev] <package> [<spec>]"
  @anchor ~r/^  defp deps do\n    \[\n/m

  def main(args) do
    {dev, positional, error} = parse_args(args)

    cond do
      error != nil -> error
      length(positional) not in [1, 2] -> usage()
      true -> add(positional, dev)
    end
  end

  defp parse_args(args) do
    Enum.reduce(args, {false, [], nil}, fn
      _, {dev, positional, error} when error != nil ->
        {dev, positional, error}

      "--dev", {_, positional, nil} ->
        {true, positional, nil}

      "--git", {dev, positional, nil} ->
        IO.puts(:stderr, "add_dependency: factory repositories are not installable in Elixir yet (no Hex release)")
        {dev, positional, 1}

      "--" <> _ = option, {dev, positional, nil} ->
        IO.puts(:stderr, "add_dependency: unknown option #{option}")
        {dev, positional, 2}

      arg, {dev, positional, nil} ->
        {dev, positional ++ [arg], nil}
    end)
  end

  defp usage do
    IO.puts(:stderr, @usage)
    2
  end

  defp add([name | spec], dev) do
    with :ok <- check_name(name),
         {:ok, requirement} <- requirement(List.first(spec, "")) do
      insert(name, requirement, dev)
    end
  end

  defp check_name(name) do
    if Regex.match?(@name, name) do
      :ok
    else
      IO.puts(:stderr, "add_dependency: #{name} is not a Hex package name")
      2
    end
  end

  # The Elixir requirement of a factory spec; 2 after reporting an invalid one.
  defp requirement(spec) do
    parts =
      spec
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&part/1)

    text = if parts == [], do: ">= 0.0.0", else: Enum.join(parts, " and ")

    case Version.parse_requirement(text) do
      {:ok, _} ->
        {:ok, text}

      :error ->
        IO.puts(:stderr, "add_dependency: #{inspect(spec)} is not a valid version range")
        2
    end
  end

  defp part(text) do
    case Regex.run(~r/\A(==|>=|<=|>|<|~>)?\s*(.+)\z/, text) do
      [_, "", version] -> "== #{full(version)}"
      [_, "~>", version] -> "~> #{version}"
      [_, op, version] -> "#{op} #{full(version)}"
    end
  end

  # Elixir requirements compare full versions: `1.3` is `1.3.0` and `2` is `2.0.0` (pre-releases stay as written).
  defp full(version) do
    case Regex.run(~r/\A(\d+)(?:\.(\d+))?(?:\.(\d+))?\z/, version) do
      [_, major] -> "#{major}.0.0"
      [_, major, minor] -> "#{major}.#{minor}.0"
      _ -> version
    end
  end

  defp insert(name, requirement, dev) do
    saved = for file <- [@mix_exs, @lock], into: %{}, do: {file, File.read(file)}
    text = File.read!(@mix_exs)
    only = if dev, do: ", only: [:dev, :test]", else: ""
    line = "      {:#{name}, #{inspect(requirement)}#{only}},\n"

    case Regex.run(@anchor, text, return: :index) do
      [{at, length}] ->
        File.write!(
          @mix_exs,
          binary_part(text, 0, at + length) <> line <> binary_part(text, at + length, byte_size(text) - at - length)
        )

        fetch(saved)

      nil ->
        IO.puts(:stderr, "add_dependency: #{@mix_exs} has no place for a dependency")
        1
    end
  end

  defp fetch(saved) do
    {_, code} = System.cmd(System.find_executable("mix"), ["deps.get"], into: IO.stream(), stderr_to_stdout: true)

    if code == 0 do
      0
    else
      Enum.each(saved, fn
        {file, {:ok, content}} -> File.write!(file, content)
        {file, {:error, _}} -> File.rm(file)
      end)

      IO.puts(:stderr, "add_dependency: `mix deps.get` failed; #{@mix_exs} and #{@lock} were restored")
      1
    end
  end
end

System.halt(AddDependency.main(System.argv()))
