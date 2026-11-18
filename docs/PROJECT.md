# Project record

## Objective

Broadway ingestion pipeline over a lease-based queue with idempotent Postgres-style batch upserts, exponential retry backoff and a dead-letter store that loses nothing on crashes.

## Scope

- Implementing a `LeaseQueue` for visibility management.
- A `Broadway` producer acknowledging only after sink success.
- Idempotent `Sql.upsert` logic for PostgreSQL.
- Dead-letter handling for invalid JSON or exhausted retries.

## Out of Scope

- Direct Postgrex or database integration (only SQL string generation is provided).
- Kafka, RabbitMQ, or SQS support.
- Metrics exporters or schema migration tools.

## Effort metrics

| Metric | Value |
|---|---|
| Tokens (input / output) | 4184564 / 48146 |
| Hours (human) | pending measurement |
| Cost (USD) | 1.4857 |

## Factory run u957 (measured from API usage)

| Date (UTC) | Phase | Model | Batch | Input | Output | Cache write | Cache read | Cost (USD) |
|---|---|---|---|---|---|---|---|---|
| 2026-11-17 | generation | google/gemini-4-argon | yes | 6755 | 31684 | 0 | 0 | 0.6607 |
| 2026-11-17 | fix-1 | google/gemini-3.8-flash | no | 139925 | 8482 | 0 | 925926 | 0.2062 |
| 2026-11-17 | fix-2 | google/gemini-3.8-flash | no | 159964 | 1262 | 0 | 661561 | 0.1743 |
| 2026-11-17 | fix-3 | google/gemini-3.8-flash | no | 153965 | 1043 | 0 | 767770 | 0.1770 |
| 2026-11-17 | fix-4 | google/gemini-3.8-flash | no | 91468 | 3057 | 0 | 783962 | 0.1389 |
| 2026-11-18 | audit | google/gemini-3.8-flash | no | 122142 | 1244 | 0 | 356729 | 0.1230 |
| 2026-11-18 | docs | google/gemini-3.1-flash-lite | no | 14397 | 1374 | 0 | 0 | 0.0057 |

Total: $1.4857. Prices: vertex line, as measured by its adapter. Providers serve the current version of each model id, so the date tells which version answered; versions, launch stages and price sources per line are in the factory's model register (docs/MODELS.md).
