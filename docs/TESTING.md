# Testing

## Running

```sh
mix test                    # tests, doctests and property tests
elixir scripts/check.exs    # every gate, as CI and the factory run it
```

## Policy

- Line coverage of `lib/` (measured by `mix test --cover`) must stay at or above 80 %; the gate
  fails below it.
- Tests exercise the public API. They assert every observable effect: returned values, raised
  exceptions (`assert_raise` with the message) and returned error tuples.
- Property tests (`use ExUnitProperties`, `check all`) state invariants such as idempotence or
  round trips over generated inputs. The seed is ExUnit's, printed by every run, so
  `mix test --seed <n>` repeats a failing run exactly.
- Each bug fix starts with a failing test that reproduces it.
- Tests are deterministic: no network, no wall clock, no dependence on order (ExUnit runs them in
  random order); use `async: true` unless a test touches global state.

## Tiers

- Local tier (every gate run, coverage measured here): unit, doc and property tests, plus
  conformance on small fixtures kept in the repository.
- CI tier: conformance that needs an external tool or a download. Tag the test module with
  `@moduletag :conformance` (or a test with `@tag :conformance`); the tests gate runs
  `mix test --exclude conformance` unless `scripts/check.exs` runs with `FABRICA_CI=1`, while
  Credo and Dialyzer always check it. The CI `conformance` job sets `FABRICA_CI=1` and runs the
  full suite. Tools are installed by the optional `ci/conformance-setup.sh` (bash, CI only; verify
  every download against a pinned SHA-256); a tagged test fails with a clear `flunk` message when
  its tool is missing.

## Layout

Tests live in `test/`, mirroring `lib/` (`test/trysac/broadway_ingest_pipeline/*_test.exs`), one
`ExUnit.Case` module each. Fixtures and golden files go in `test/fixtures/` (read them with
`Path.join([__DIR__, "..", "..", "fixtures", ...])` relative to the test file).
