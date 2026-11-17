# broadway-ingest-pipeline

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![CI](https://github.com/Trysac/u957-broadway-ingest-pipeline/actions/workflows/ci.yml/badge.svg)](https://github.com/Trysac/u957-broadway-ingest-pipeline/actions/workflows/ci.yml)

Broadway ingestion pipeline over a lease-based queue with idempotent Postgres-style batch upserts, exponential retry backoff and a dead-letter store that loses nothing on crashes

## Problem

Describe in two or three sentences the concrete problem this utility solves, who hits it, and what
they do today without it. Replace this paragraph when the first real feature lands.

## Install

```elixir
# mix.exs
def deps do
  [{:trysac_broadway_ingest_pipeline, "~> 0.1"}]
end
```

Until it is published on Hex, point the dependency at a release tag:
`{:trysac_broadway_ingest_pipeline, git: "https://github.com/Trysac/u957-broadway-ingest-pipeline", tag: "v0.1.0"}`. Requires Elixir 1.20 or newer on
Erlang/OTP 29. No dependencies outside the Elixir standard library.

## Usage

```elixir
# normalize trims surrounding whitespace and lower-cases the text.
Trysac.BroadwayIngestPipeline.Text.normalize("  Hello World ")
#=> "hello world"

# Blank input is rejected explicitly instead of returning an empty string.
Trysac.BroadwayIngestPipeline.Text.normalize("   ")
#=> ** (Trysac.BroadwayIngestPipeline.BlankInputError) input is blank
```

## Documentation

- [Architecture](docs/ARCHITECTURE.md) and [decisions](docs/decisions/)
- [Testing](docs/TESTING.md) and [security](docs/SECURITY.md)
- [Project record](docs/PROJECT.md) and [stack](docs/STACK.md)
- [Changelog](CHANGELOG.md) and [contributing guide](CONTRIBUTING.md)

## License

[MIT](LICENSE) (c) 2026 Miguel Gomez
