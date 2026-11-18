# Security

## Threat Model

### Defended

- **Memory Exhaustion**: `LeaseQueue` enforces `max_body_bytes` (default 1,048,576 bytes) and `max_messages` (default 100,000), raising `:message_too_large` or `:queue_full` errors.
- **SQL Injection**: `Sql.upsert/3` validates identifiers against `~r/\A[a-z_][a-z0-9_]{0,62}\z/`, uses double-quoting, and positional parameters capped at 65,535 parameters.
- **Sensitive Data Leakage**: `Error` exceptions truncate input snippets to 200 characters. `on_event` telemetry callbacks contain only `:type`, `:count`, and `:attempt`, explicitly excluding message payloads.

### Not Defended

- Resource exhaustion via high-frequency API calls from untrusted sources.
- Denial of Service through complex JSON payload structures (standard library decoder limits apply).