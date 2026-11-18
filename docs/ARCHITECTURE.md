# Architecture

## Overview

`Trysac.BroadwayIngestPipeline` coordinates four crash-safety guarantees around `Broadway`:

1. **Lease-based visibility (`LeaseQueue`)**: Messages transition from `ready` to `leased` with an expiration deadline (`lease_ms`, default 30,000 ms). If a consumer crashes before acknowledging, `LeaseQueue.expire/1` returns expired leases to `ready` with `attempt + 1`.
2. **Acknowledge after commit (`QueueProducer` + `Pipeline`)**: JSON decoding and envelope validation occur in `handle_message/3`. Batch writes happen in `handle_batch/4`. Broadway invokes `QueueProducer.ack/3` only after `handle_batch/4` completes.
3. **Bounded exponential backoff and dead-lettering**: Failed sink writes nack messages with delay `backoff_base_ms * 2^(attempt - 1)` capped at `backoff_max_ms`. Messages failing on `max_attempts` move to the dead-letter store with `:sink_failed`. Malformed JSON envelopes fail immediately in `handle_message/3` and move to the dead-letter store with `:invalid_message` without blocking valid messages in the same batch.
4. **Idempotent sink writes (`MemorySink` and `Sql.upsert/3`)**: At-least-once delivery from lease expiration or retry is collapsed into exactly-once stored rows by enforcing primary-key conflict ignore (`ON CONFLICT ("id") DO NOTHING`).
