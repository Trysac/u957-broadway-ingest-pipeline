# Post-commit Broadway acknowledgement over a lease queue with idempotent batch upserts

Status: accepted (generated, pending human review)

## Context

Streaming ingestion pipelines lose messages when acknowledging before batch writes commit, or duplicate rows when retrying after consumer crashes.

## Decision

Combine a GenServer lease queue with an explicit Broadway.Acknowledger that acknowledges only after Sink.write_batch returns :ok, nacks failed batches with capped exponential backoff, dead-letters malformed or exhausted messages, and pairs with idempotent primary-key upserts.

## Consequences

Crashes between sink commit and lease acknowledgement are safe: expired leases are redelivered and deduplicated by primary key, ensuring zero message loss and zero duplicate stored rows.
