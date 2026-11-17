# Security notes

## Threat model

The Hex package `trysac_broadway_ingest_pipeline` is a pure library without I/O. The main risks are:

- **Supply chain**: a compromised package or CI action. Mitigation: standard library only, every
  package pinned by the committed `mix.lock` (with its checksums, fetched with
  `mix deps.get --check-locked`), `mix hex.audit` (retired releases), `mix deps.audit` (the
  Elixir security advisories) and OSV-Scanner over `mix.lock` in the gates, Dependabot weekly
  updates, actions pinned by commit SHA, minimal workflow permissions.
- **Leaked secrets**: tokens committed by mistake. Mitigation: `gitleaks` runs in the local gates
  and in CI; `.env` files and Hex API keys are never committed.
- **Insecure code**: code evaluation (`Code.eval_string`), shell command lines (`:os.cmd`,
  `System.shell`), unsafe deserialization (`:erlang.binary_to_term` without `:safe`), atoms
  created from input (`String.to_atom`), functions chosen by input (`apply/3`), disabled TLS
  verification (`:verify_none`). Mitigation: Credo's Warning checks in the lint gate, Dialyzer,
  and the factory's Semgrep rules (`.semgrep/factory-rules.yml`, `nosemgrep` ignored); fix the
  code instead of silencing it.
- **Untrusted input**: callers may pass hostile strings. Mitigation: validate input with guards
  and pattern matching and raise explicit, documented errors; never turn input into atoms or
  code.

## Publishing

Releases are git tags; publishing on Hex needs an account, whose API key is never stored in the
repository.

To report a vulnerability, see [SECURITY.md](../SECURITY.md).
