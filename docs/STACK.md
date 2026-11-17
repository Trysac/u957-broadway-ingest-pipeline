# Stack

## Used

| Tool | Why |
|---|---|
| Elixir 1.20 on Erlang/OTP 29 | The current stable Elixir minor on the current OTP major. |
| Mix + Hex | The standard build tool and package manager; `mix.lock` committed with checksums, `mix deps.get --check-locked`. |
| mix format | The format gate, configured by `.formatter.exs`. |
| Credo (strict) | The lint gate, with every default check plus specs, unsafe atoms and layout checks. |
| Dialyzer (dialyxir) | The types gate: success typings and the `@spec` of every public function. |
| ExUnit + StreamData | Tests, doctests and property tests (`check all`); `mix test --cover` measures line coverage of `lib/`. |
| Code.fetch_docs | The docs gate: every public module, function and macro documented (`scripts/docs.exs`). |
| Semgrep CE + OSV-Scanner | The factory's own rules (generic engine: Semgrep CE does not parse Elixir); OSV advisories over `mix.lock`. |
| mix hex.audit + mix_audit | Retired Hex releases and the Elixir security advisories for every locked package. |
| gitleaks | Secret scanning locally and in CI. |
| GitHub Actions + Dependabot | Thin CI wrapper over the local gates; weekly dependency updates. |

## Discarded

| Tool | Why not |
|---|---|
| ExCoveralls | `mix test --cover` reports the same line coverage without another dependency or service. |
| Sobelow | It targets Phoenix applications; the factory's Semgrep rules and Credo cover a library. |
| ExDoc | The docs gate reads the documentation chunks directly; HTML docs are built when the package is published. |
| PropCheck | StreamData is the community standard for property tests and needs no Erlang PropEr. |
| Shell scripts or Makefiles for gates | Not portable to Windows; the gates are an Elixir script. |
