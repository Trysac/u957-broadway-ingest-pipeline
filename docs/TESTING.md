# Testing

## Test Files

- `test/trysac/broadway_ingest_pipeline/pipeline_test.exs`: Acceptance tests. Covers valid ingestion (1,000 messages), crash safety (killing pipeline between commit and ack), exponential backoff retries, dead-lettering, SQL upsert generation, and telemetry event safety.
- `test/trysac/broadway_ingest_pipeline/properties_test.exs`: Property tests. Covers monotonic backoff boundaries, `MemorySink` idempotency (duplicate batches), and SQL parameter ordering.
- `test/trysac/broadway_ingest_pipeline/text_properties_test.exs`: Property tests for `Text.normalize`. Covers idempotence, whitespace removal, and case normalization.
- `test/trysac/broadway_ingest_pipeline/text_test.exs`: Unit tests for `Text.normalize` (doctests) and version exposure.

## Running

```bash
mix test
```