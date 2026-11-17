# AGENTS.md

Instructions for coding agents (and humans) working on the Hex package `trysac_broadway_ingest_pipeline` (module
`Trysac.BroadwayIngestPipeline`, OTP application `:trysac_broadway_ingest_pipeline`).

## Commands

| Task | Command |
|---|---|
| Install dependencies | `mix deps.get` |
| Run every gate (must pass before a PR) | `elixir scripts/check.exs` |
| Tests only | `mix test` |
| Format | `mix format` |
| Lint | `mix credo --strict` |
| Types | `mix dialyzer` |
| Coverage | `elixir scripts/check.exs tests` |

The gate sequence is: format (`mix format --check-formatted`), lint (`mix compile
--warnings-as-errors`, no unused `mix.lock` entries, no `credo:disable` or `@dialyzer`
suppressions, then Credo in strict mode; any issue fails), types (Dialyzer through dialyxir),
Semgrep (the factory's rules in `.semgrep/`), ExUnit with `mix test --cover` and
line coverage >= 80 % of `lib/`, documentation (`docs-manifest.json` plus every public module, function and
macro of `lib/` documented), gitleaks, `mix hex.audit` and `mix deps.audit` over `mix.lock`, and
OSV-Scanner over `mix.lock`. It stops at the first failure.

## Folder map

| Path | Content |
|---|---|
| `lib/trysac/broadway_ingest_pipeline.ex` | The entry module `Trysac.BroadwayIngestPipeline`. |
| `lib/trysac/broadway_ingest_pipeline/` | The library, one module per file under `Trysac.BroadwayIngestPipeline`; their public functions are the public API. |
| `test/` | ExUnit tests (`*_test.exs`, mirroring `lib/`), including StreamData property tests and doctests. |
| `test/fixtures/` | Optional fixtures and golden files used by tests. |
| `scripts/` | The single definition of the quality gates (`check.exs`, `docs.exs`) and the factory's dependency tool. |
| `docs/` | Architecture, decisions (ADRs), testing, security, project record, stack. |
| `fabrica.json` | Install and check commands used by the factory and CI. |
| `docs-manifest.json` | Documentation files the docs gate requires. |
| `.github/` | CI wrapper and Dependabot configuration. |

## Conventions

- Elixir 1.20 or newer on Erlang/OTP 29, formatted by `mix format`, clean under Credo strict and
  Dialyzer.
- Standard library only unless an ADR in `docs/decisions/` justifies a dependency.
- Every public module has a `@moduledoc`, every public function a `@doc` and a `@spec`; invalid
  input raises a documented exception of the library (`defexception`), or the function returns
  `{:ok, value} | {:error, reason}` when failure is expected. Never return nil or a sentinel.
- Write the failing test first; tests use every literal of the acceptance items verbatim, and
  property tests (`use ExUnitProperties`, `check all`) cover invariants.
- CI-only conformance tests (external tools or downloads) carry `@moduletag :conformance` or
  `@tag :conformance`; only CI runs them.
- Every behavior change updates `README.md` usage, `CHANGELOG.md` (Unreleased) and, if it is a
  design choice, a new ADR.
- Conventional Commits (`feat:`, `fix:`, `docs:`, `test:`, `refactor:`, `chore:`).

## Limits

- Never push to `main`; work on a branch and open a pull request.
- Do NOT edit `.github/`, `fabrica.json`, `docs-manifest.json`, `scripts/`, `mix.exs`,
  `mix.lock`, `.formatter.exs`, `.credo.exs`, `.editorconfig` or any tool configuration. They are
  the quality contract; changes to them are made by a human.
- Never lower the coverage threshold, add `# credo:disable-for-...` comments, `@dialyzer`
  attributes or a `.dialyzer_ignore.exs` to silence a finding, or skip a test to make a gate pass.
- Never commit secrets, tokens, credentials or `.env` files; gitleaks blocks them.
