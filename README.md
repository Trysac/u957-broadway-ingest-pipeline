# Trysac.BroadwayIngestPipeline

Broadway ingestion pipeline over a lease-based queue with idempotent Postgres-style batch upserts, exponential retry backoff and a dead-letter store that loses nothing on crashes.

## Usage

```elixir
{:ok, queue} = Trysac.BroadwayIngestPipeline.LeaseQueue.start_link()
{:ok, sink} = Trysac.BroadwayIngestPipeline.MemorySink.start_link()
body = JSON.encode!(%{"id" => "evt-1", "ts" => "2026-01-01T00:00:00Z", "payload" => %{"ok" => true}})
{:ok, _ids} = Trysac.BroadwayIngestPipeline.LeaseQueue.enqueue(queue, [body])
{:ok, pipeline} = Trysac.BroadwayIngestPipeline.Pipeline.start_link(queue: queue, sink: sink, batch_size: 1)
{stmt, params} = hd(Trysac.BroadwayIngestPipeline.Sql.upsert("events", ["id", "ts", "payload"], [%{id: "evt-1", ts: "2026-01-01T00:00:00Z", payload: "{}"}]))
Supervisor.stop(pipeline)
```

## API Summary

- `LeaseQueue`: Manages visibility leases. Features: `enqueue/2`, `lease/2`, `ack/2`, `nack/3`, `dead_letter/3`, `expire/1`, `stats/0`.
- `Pipeline`: Configurable Broadway topology. Options: `name`, `queue`, `sink`, `batch_size`, `batch_timeout`, `processors`, `batchers`, `max_attempts`, `backoff_base_ms`, `backoff_max_ms`, `on_event`.
- `Sql`: Builder for `INSERT ... ON CONFLICT DO NOTHING` statements with automated parameter batching.
- `Error`: Typed exception for `:invalid_option`, `:invalid_identifier`, `:message_too_large`, `:queue_full`, `:unknown_lease`.

## Why not existing Broadway producers?

Standard Broadway producers acknowledge messages immediately upon consumption, causing data loss on consumer crashes. This library implements a lease-based queue that only acknowledges after the sink commits, providing guaranteed at-least-once delivery into the sink and exactly-once storage via primary-key conflict ignores.

## Security

See [docs/SECURITY.md](docs/SECURITY.md) for the threat model and limits.