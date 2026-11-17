# Runs every quality gate of this repository, in order, stopping at the first failure.
#
# Usage: `elixir scripts/check.exs` (the same command locally, in the factory and in CI); append gate names to run
# only those, in the standard order. Run `mix deps.get` first.
#
# Gates: format (`mix format --check-formatted`); lint (`mix compile --warnings-as-errors`, unused mix.lock entries,
# no inline `credo:disable` or `@dialyzer` suppressions, then Credo in strict mode, any issue fails); types
# (Dialyzer through dialyxir); semgrep (Semgrep CE with the factory's own rules in .semgrep/); tests (ExUnit with
# `mix test --cover`) with line coverage >= 80 % of lib/; docs: the documentation manifest plus every public module,
# function and macro of lib/ documented (scripts/docs.exs); secrets (gitleaks); audit (`mix hex.audit`, retired
# releases and Hex advisories, and `mix deps.audit`, the Elixir security advisories; any finding fails) and
# OSV-Scanner over mix.lock (high severity). Every mix command runs with MIX_ENV=test, so the project and its dependencies compile once. No
# shell: every tool runs with an argument list, so it behaves the same on Windows and Linux. Factory-owned file:
# agents must not edit it.

defmodule Check do
  @moduledoc false

  @min_coverage 80.0
  @docs_manifest "docs-manifest.json"
  @allow_missing_gitleaks "FABRICA_ALLOW_MISSING_GITLEAKS"
  @allow_offline_audit "FABRICA_ALLOW_OFFLINE_AUDIT"
  # FABRICA_CI=1 also runs the tests tagged `:conformance` (external tools or downloads); only the CI conformance
  # job sets it, so local gates and coverage skip them.
  @ci_tier "FABRICA_CI"
  @conformance_tag "conformance"
  # The factory's own Semgrep rules; Semgrep-maintained rules are never used (license).
  @semgrep_rules ".semgrep/factory-rules.yml"
  @lock_file "mix.lock"
  @high_cvss 7.0
  # osv-scanner's exit codes: 1 when vulnerabilities were found, 128 when no package was found.
  @osv_found 1
  @osv_no_packages 128
  # Suppressions that would hide a finding from the lint and types gates.
  @suppressions [{"credo:disable", ~w(lib test)}, {"@dialyzer", ~w(lib)}]
  @gates ~w(format lint types semgrep tests docs secrets audit osv)

  def main(args) do
    cond do
      not (File.regular?("mix.exs") and File.regular?("scripts/check.exs")) ->
        IO.puts(:stderr, "check: run from the repository root (mix.exs not found)")
        2

      unknown = Enum.find(args, &(&1 not in @gates)) ->
        IO.puts(:stderr, "check: unknown gate \"#{unknown}\"")
        2

      true ->
        run_gates(Enum.filter(@gates, &(args == [] or &1 in args)))
    end
  end

  defp run_gates([]) do
    IO.puts("==> all gates passed")
    0
  end

  defp run_gates([name | rest]) do
    IO.puts("==> #{name}")

    case gate(name) do
      :ok ->
        IO.puts("==> #{name}: ok")
        run_gates(rest)

      {:error, reason} ->
        IO.puts(:stderr, "#{name}: #{reason}")
        IO.puts(:stderr, "==> #{name}: FAILED")
        1
    end
  end

  defp flag?(name), do: System.get_env(name) == "1"

  # Runs a program without a shell, its output going to the terminal; :ok or the reason it failed.
  defp run(argv, env \\ []) do
    case capture(argv, env, true) do
      {0, _} -> :ok
      {127, _} -> {:error, "`#{Enum.join(argv, " ")}` failed (cannot start it)"}
      {code, _} -> {:error, "`#{Enum.join(argv, " ")}` failed (exit #{code})"}
    end
  end

  # Runs a program without a shell and returns its exit code and output (stdout and stderr together); `echo`
  # also prints the output.
  defp capture([program | args], env \\ [], echo \\ false) do
    case System.find_executable(program) do
      nil ->
        {127, "#{program} not found"}

      exe ->
        {out, code} = System.cmd(exe, args, env: env, stderr_to_stdout: true)
        if echo, do: IO.write(out)
        {code, out}
    end
  end

  # A mix command in the test environment.
  defp mix(args), do: ["mix" | args]
  defp test_env(extra \\ []), do: [{"MIX_ENV", "test"} | extra]

  defp gate("format") do
    case run(mix(["format", "--check-formatted"]), test_env()) do
      :ok ->
        IO.puts("mix format: every file is formatted")

      {:error, reason} ->
        {:error, "#{reason}: run `mix format`"}
    end
  end

  defp gate("lint") do
    with :ok <- run(mix(["compile", "--warnings-as-errors", "--force"]), test_env()),
         :ok <- run(mix(["deps.unlock", "--check-unused"]), test_env()),
         :ok <- suppressions(),
         :ok <- run(mix(["credo", "--strict", "--all-priorities", "--format", "oneline"]), test_env()) do
      IO.puts("mix compile --warnings-as-errors and Credo (strict): no issues")
    end
  end

  defp gate("types") do
    with :ok <- run(mix(["dialyzer", "--format", "short"]), test_env()) do
      IO.puts("dialyzer: no warnings")
    end
  end

  # Semgrep CE with the factory's own rules only; ERROR rules fail and nosemgrep comments are ignored. Tests,
  # scripts/, deps/ and _build/ are not scanned.
  defp gate("semgrep") do
    case System.find_executable("semgrep") do
      nil ->
        missing_scanner("semgrep")

      exe ->
        run([
          exe,
          "scan",
          "--config",
          @semgrep_rules,
          "--error",
          "--severity",
          "ERROR",
          "--metrics",
          "off",
          "--disable-version-check",
          "--disable-nosem",
          "--quiet",
          "--exclude=scripts",
          "--exclude=test",
          "--exclude=deps",
          "--exclude=_build",
          "."
        ])
    end
  end

  defp gate("tests") do
    dir = Path.join(build_base(), "fabrica-elixir-check-#{System.pid()}")
    File.rm_rf!(dir)

    args =
      if flag?(@ci_tier) do
        IO.puts("tests: CI tier, the conformance tests run too")
        ["test", "--cover", "--warnings-as-errors"]
      else
        ["test", "--cover", "--warnings-as-errors", "--exclude", @conformance_tag]
      end

    {code, out} = capture(mix(args), test_env([{"FABRICA_COVERAGE_DIR", dir}]), true)
    File.rm_rf!(dir)

    case {code, Regex.run(~r/\|\s*([0-9.]+)%\s*\|\s*Total\s*\|/, out)} do
      {0, [_, total]} -> coverage(String.to_float(total))
      {0, nil} -> {:error, "mix test --cover printed no total coverage"}
      {code, _} -> {:error, "`mix #{Enum.join(args, " ")}` failed (exit #{code})"}
    end
  end

  defp gate("docs") do
    with {:ok, text} <- read_manifest(),
         {:ok, manifest} <- decode_manifest(text) do
      errors = manifest_errors(if is_map(manifest), do: manifest, else: %{})
      Enum.each(errors, &IO.puts(:stderr, "docs: #{&1}"))

      case {errors, run(mix(["run", "--no-start", "scripts/docs.exs"]), test_env())} do
        {[], :ok} -> IO.puts("docs: every file in #{@docs_manifest} is present and the public API is documented")
        {[], {:error, _}} -> {:error, "the public API has undocumented modules or functions"}
        {_, _} -> {:error, "#{length(errors)} documentation problem(s) in #{@docs_manifest}"}
      end
    end
  end

  defp gate("secrets") do
    case System.find_executable("gitleaks") do
      nil ->
        if flag?(@allow_missing_gitleaks) do
          IO.puts("gitleaks: SKIPPED (not installed)")
        else
          {:error,
           "FAIL - gitleaks is not installed. Install it (https://github.com/gitleaks/gitleaks#installing), e.g. " <>
             "`winget install Gitleaks.Gitleaks`, `brew install gitleaks` or a release binary, or set " <>
             "#{@allow_missing_gitleaks}=1 to skip this gate locally."}
        end

      exe ->
        run([exe, "dir", ".", "--redact", "--verbose", "--no-banner"])
    end
  end

  # Every package of mix.lock (runtime and dev/test): retired releases and Hex security advisories
  # (`mix hex.audit`) and the Elixir security advisories (`mix deps.audit`, mix_audit); any finding fails, like
  # pip-audit or npm audit. Both need the network; FABRICA_ALLOW_OFFLINE_AUDIT=1 skips the gate when a tool fails
  # without reporting a finding (its advisory source is unreachable).
  defp gate("audit") do
    checks = [
      {mix(["hex.audit"]), ["Found retired packages", "Found packages with security advisories"]},
      {mix(["deps.audit"]), ["Vulnerabilities found"]}
    ]

    checks
    |> Enum.reduce_while(:ok, fn {argv, found}, :ok -> audit(argv, found) end)
    |> case do
      :ok -> IO.puts("audit: no retired packages and no known vulnerabilities in #{@lock_file}")
      :skipped -> :ok
      error -> error
    end
  end

  # OSV-Scanner over mix.lock (Hex is an OSV ecosystem); high or unknown severity fails.
  defp gate("osv") do
    case System.find_executable("osv-scanner") do
      nil -> missing_scanner("osv-scanner")
      exe -> osv(exe)
    end
  end

  defp audit(argv, found) do
    command = Enum.join(argv, " ")
    {code, out} = capture(argv, test_env(), true)

    cond do
      Enum.any?(found, &String.contains?(out, &1)) ->
        {:halt, {:error, "`#{command}`: known vulnerable or retired packages in #{@lock_file}"}}

      code == 0 ->
        {:cont, :ok}

      flag?(@allow_offline_audit) ->
        IO.puts("audit: SKIPPED (`#{command}` cannot reach its advisory source)")
        {:halt, :skipped}

      true ->
        {:halt,
         {:error, "`#{command}` failed (exit #{code}), or set #{@allow_offline_audit}=1 to skip this gate offline"}}
    end
  end

  defp osv(exe) do
    case capture([exe, "scan", "source", "--format", "json", "--lockfile=#{@lock_file}"]) do
      {0, _} ->
        IO.puts("osv-scanner: no known vulnerabilities in #{@lock_file}")

      {@osv_no_packages, _} ->
        IO.puts("osv-scanner: no packages in #{@lock_file}")

      {@osv_found, out} ->
        osv_report(out)

      {code, out} ->
        IO.write(:stderr, out)
        {:error, "osv-scanner failed (exit #{code})"}
    end
  end

  defp osv_report(out) do
    # stderr is merged into the output: the JSON report is the object that starts the first line opening with "{".
    json = out |> String.split("\n") |> Enum.drop_while(&(not String.starts_with?(&1, "{"))) |> Enum.join("\n")

    case JSON.decode(json) do
      {:ok, report} when is_map(report) ->
        blocking = osv_blocking(report)
        Enum.each(blocking, &IO.puts(:stderr, "osv-scanner: #{&1}"))

        if blocking == [] do
          IO.puts("osv-scanner: only advisories below high severity (reported, not failing)")
        else
          {:error, "#{length(blocking)} advisory group(s) of high or unknown severity"}
        end

      _ ->
        {:error, "osv-scanner: unreadable JSON report"}
    end
  end

  # The advisory groups with CVSS >= 7.0 or no score (unknown counts as high).
  defp osv_blocking(report) do
    for %{} = result <- List.wrap(report["results"]),
        %{} = package <- List.wrap(result["packages"]),
        %{} = group <- List.wrap(package["groups"]),
        severity = group["max_severity"] |> to_string() |> String.trim(),
        blocking_severity?(severity) do
      # A bare `known = ...` clause would be a filter and drop unknown severities, so compute it here.
      known = known_severity?(severity)
      info = if is_map(package["package"]), do: package["package"], else: %{}
      ids = group["ids"] |> List.wrap() |> Enum.filter(&is_binary/1) |> Enum.join(",")
      "#{info["name"]}@#{info["version"]} #{ids} (#{if known, do: severity, else: "unknown"})"
    end
  end

  defp known_severity?(severity), do: Regex.match?(~r/\A\d+(\.\d+)?\z/, severity)

  defp blocking_severity?(severity),
    do: not known_severity?(severity) or to_number(severity) >= @high_cvss

  defp to_number(text) do
    {value, ""} = Float.parse(text)
    value
  end

  defp build_base do
    case System.get_env("FABRICA_BUILD_DIR", "") do
      "" -> System.tmp_dir!()
      base -> base
    end
  end

  defp coverage(total) do
    IO.puts("Total coverage: #{:erlang.float_to_binary(total, decimals: 2)}%")

    if total < @min_coverage do
      {:error, "total line coverage #{:erlang.float_to_binary(total, decimals: 1)}% is below #{trunc(@min_coverage)}%"}
    else
      IO.puts("tests: line coverage #{:erlang.float_to_binary(total, decimals: 1)}% (minimum #{trunc(@min_coverage)}%)")
    end
  end

  # `credo:disable` comments and `@dialyzer` attributes, which would hide a finding from lint or types.
  defp suppressions do
    found =
      for {needle, dirs} <- @suppressions,
          dir <- dirs,
          path <- Path.wildcard("#{dir}/**/*.{ex,exs}"),
          File.read!(path) |> String.contains?(needle),
          do: "#{path}: #{needle} is not allowed; fix the finding instead"

    Enum.each(found, &IO.puts(:stderr, "lint: #{&1}"))
    if found == [], do: :ok, else: {:error, "#{length(found)} suppressed finding(s)"}
  end

  defp read_manifest do
    case File.read(@docs_manifest) do
      {:ok, text} -> {:ok, text}
      {:error, _} -> {:error, "#{@docs_manifest} not found"}
    end
  end

  defp decode_manifest(text) do
    case JSON.decode(text) do
      {:ok, manifest} -> {:ok, manifest}
      {:error, reason} -> {:error, "#{@docs_manifest} is not valid JSON: #{inspect(reason)}"}
    end
  end

  defp strings(value) when is_list(value), do: Enum.filter(value, &is_binary/1)
  defp strings(_), do: []

  defp count_lines(text) do
    trimmed = text |> String.replace("\r\n", "\n") |> String.replace(~r/\n+\z/, "")
    if trimmed == "", do: 0, else: length(String.split(trimmed, "\n"))
  end

  # Every violation of docs-manifest.json; an empty list means the manifest part of the docs gate passes.
  defp manifest_errors(manifest) do
    required =
      for rel <- strings(manifest["required"]),
          error = required_error(rel),
          do: error

    globs =
      for pattern <- strings(manifest["required_globs"]),
          not Enum.any?(Path.wildcard(pattern), &File.regular?/1),
          do: "no file matches required pattern: #{pattern}"

    limits =
      for {rel, max} <- map(manifest["max_lines"]),
          is_integer(max) and File.regular?(rel),
          lines = count_lines(File.read!(rel)),
          lines > max,
          do: "#{rel} has #{lines} lines (max #{max})"

    references =
      for {rel, needle} <- map(manifest["must_reference"]),
          is_binary(needle) and File.regular?(rel),
          not String.contains?(File.read!(rel), needle),
          do: "#{rel} must reference #{needle}"

    required ++ globs ++ limits ++ references
  end

  defp required_error(rel) do
    cond do
      not File.regular?(rel) -> "missing required file: #{rel}"
      String.trim(File.read!(rel)) == "" -> "required file is empty: #{rel}"
      true -> nil
    end
  end

  defp map(value) when is_map(value), do: value
  defp map(_), do: %{}

  defp missing_scanner(tool) do
    if flag?(@ci_tier) do
      {:error, "#{tool} not installed (required when #{@ci_tier}=1)"}
    else
      IO.puts("#{tool}: skipped: #{tool} not installed")
    end
  end
end

System.halt(Check.main(System.argv()))
