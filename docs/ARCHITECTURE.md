# Architecture

## Purpose

The Hex package `trysac_broadway_ingest_pipeline` is a small, dependency-free Elixir library: Broadway ingestion pipeline over a lease-based queue with idempotent Postgres-style batch upserts, exponential retry backoff and a dead-letter store that loses nothing on crashes

## Shape

```text
caller code --> Trysac.BroadwayIngestPipeline (lib/trysac/broadway_ingest_pipeline.ex)
                    |
                    +-- Trysac.BroadwayIngestPipeline.* (lib/trysac/broadway_ingest_pipeline/)
                          +-- modules of pure functions; no processes, no I/O, no global state
                          +-- @moduledoc false / @doc false helpers (private, optional)
```

- **Public API**: every module of `lib/` with a `@moduledoc` and its public functions and macros.
  Modules marked `@moduledoc false` and functions marked `@doc false` are private and may change
  without a major version.
- **Errors**: invalid input raises an exception of the library (such as `BlankInputError`,
  defined with `defexception`) documented in the function's `@doc`, or the function returns
  `{:ok, value} | {:error, reason}` when failure is an expected outcome. The library never prints,
  halts the VM, starts processes or changes application environment.
- **Side effects**: none. If a feature needs I/O, accept data or a small behaviour instead of
  opening files, and record the choice in an ADR.

## Quality contract

`scripts/check.exs` is the single definition of the gates; `fabrica.json` tells the factory and CI
how to run it. See [TESTING.md](TESTING.md).

## Decisions

Architecture decisions are recorded in [decisions/](decisions/) as numbered ADRs.
