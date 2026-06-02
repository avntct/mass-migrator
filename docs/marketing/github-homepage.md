# Mass Migrator v3

> **10 million master records moved, enriched, and selectively updated — in 27 minutes, with 4 CLI commands.**
>
> No pipeline DSL. No YAML scheduler. No Spark cluster. Just declarative modes.

<p align="center">
  <img alt="Go" src="https://img.shields.io/badge/go-1.25.7-00ADD8?logo=go">
  <img alt="License" src="https://img.shields.io/badge/license-commercial-blue">
  <img alt="Tests" src="https://img.shields.io/badge/tests-passing-brightgreen">
  <img alt="Signed" src="https://img.shields.io/badge/releases-cosign%20%2B%20SLSA%20L3-success">
  <img alt="Dialects" src="https://img.shields.io/badge/dialects-7-orange">
</p>

---

## The Problem

Most "real" data tools force you into their pipeline framework before you can move a single row:

- Learn a DSL
- Stand up a scheduler
- Spin up workers
- Debug YAML
- Prove the pipeline is healthy before you can prove your data is healthy

…for a job that's fundamentally: *read file → write rows → update rows*.

The mismatch IS the cost.

## The Bet

Every routine bulk operation is its own first-class CLI mode. Declarative flags. No DSL required.

For the rare workflow that does need cross-product partitioning, multi-source joins, or complex DAG dependencies, the full pipeline mode is there. But you can skip all of that for the 80% of jobs that are fundamentally bulk CRUD plus lookups.

## Proof — 10M Records in 27 Minutes

Test bed: 10M synthetic rows, single Postgres node, 8 threads, 5,000-row batches.

| Step | Mode | Time |
|---|---|---|
| Generate test CSV | `gencsv` | ~3 min |
| Load CSV → Postgres | `csv2db` | ~7 min |
| Enrich + copy DB-to-DB | `insert` | ~9 min |
| Selective restore from CSV | `update-ind` | ~6 min |

**Total: 27 minutes.** End-to-end verified: row counts, balance sums, enrichment coverage, partition spread.

Reproduce: `tests/test-6step-simple-mode-go.sh`

## Quick Tour — Modes That Cover 80% of Jobs

### Generate test data

| Mode | Use for |
|---|---|
| `gencsv` | Synthesize CSV at hundreds of MB/s. One flag per column type: SEQUENTIAL / NORMAL / RANDOM / EMAIL / TIMESTAMP / DECIMAL / BOOLEAN. |
| `genparquet` | Same idea, Parquet output with configurable row-group size and compression. |

### File → Database

| Mode | Strategy | Use for |
|---|---|---|
| `csv2db` | insert (default) | Bulk CSV ingest with parallel threads, auto-batching, partition routing, optional table auto-create. |
| `insert-ind` | insert | CSV import where the strategy must be insert specifically. |
| `update-ind` | update | CSV-driven UPDATE with key matching. Restores any column from any file. |
| `merge-ind` | merge | CSV-driven UPSERT (insert-or-update). |
| `upsert-ind` | upsert | Same as merge-ind, named by intent. |

### Database → Database

| Mode | Strategy | Use for |
|---|---|---|
| `insert` | insert | Direct DB-to-DB copy with column mapping. Cross-dialect supported (Oracle → Postgres, MySQL → SQL Server, etc.). |
| `update` | update | DB-to-DB UPDATE driven by source table contents. |
| `merge` | merge (UPSERT) | DB-to-DB upsert using dialect-native MERGE (PostgreSQL ON CONFLICT, Oracle MERGE, SQL Server MERGE, MySQL ON DUPLICATE KEY). |
| `upsert` | upsert | Same as merge, named by intent. |

### Database → File

| Mode | Use for |
|---|---|
| `load2csv` | Export DB rows to CSV. Streaming, group-aware, splittable by partition key. |
| `load2parquet` | Same, Parquet output. |

## Features Matrix

### Performance

- Parallel multi-threaded operations (configurable per mode)
- Auto batch sizing tuned to each dialect's parameter limit (PostgreSQL 65535, SQL Server 2100, SQLite 32766, Oracle 65535)
- Per-partition routing via FNV-1a hash (no hotspot writes)
- Backpressure (won't OOM the database)
- Lock-aware batch sizing (smaller batches when target is hot)
- Per-mode TPS metrics

### Reliability

- State checkpoints — resumable after process death
- DLQ (dead-letter queue), SQLite-backed, bounded by size + TTL
- 280+ pattern retry classifier (PostgreSQL SQLSTATE, MySQL error codes, pgx wrappers, etc.)
- Per-record retries with exponential backoff + circuit breaker
- State machine with transition guards — no silent state corruption
- `state_transitions` audit table records every status change

### Multi-Dialect

| Dialect | Status | Notes |
|---|---|---|
| PostgreSQL | Full | Primary target; all 13 modes supported |
| MySQL | Full | All modes; dialect-aware MERGE syntax |
| SQLite | Full | Single-connection (file-locked); concurrent reads OK |
| SQL Server | Full | All modes |
| Oracle | Full | All modes; real `AcquireRunLock` via sentinel table |
| Neo4j | Stub | Interface in place; query path not implemented |
| Netezza | Stub | Interface in place; query path not implemented |

Cross-dialect migrations work end-to-end. The engine auto-adapts SQL generation.

### Operations

- **Daemon mode** — scheduled pipelines via cron expressions, with health/ready/live/metrics endpoints
- **Health endpoints** — `/health`, `/ready`, `/live`, `/metrics`
- **Optional pprof** — `/debug/pprof/*` gated by `MM_PPROF=1` (off by default for security)
- **systemd unit + logrotate** — production-ready scaffolding in `contrib/`
- **Cosign-signed releases + SLSA L3 provenance** — supply-chain verification

### Beyond Simple Modes (when you need them)

For the 20% of jobs that genuinely need orchestration:

- Full pipeline DSL with DAG scheduling
- 23 operation modes total (across simple + pipeline)
- 11 dataset operators: JOIN (hash + sort-merge), UNION, MINUS, INTERSECT, CROSS, LOOKUP, etc.
- 148 JavaScript transform helpers in a hardened goja sandbox (5s per-script timeout, frozen prototype chains)
- Watermark-based incremental sync: independent / incremental / overlap modes
- 4-stage pipelined batch poller (SKIP LOCKED + hash-partition)
- Cross-product partitioned execution (star-schema main × shared dimension)
- DAG-level error handlers and finalizers
- Application-level idempotency keys (default-on for relay paths)

## Architecture Principles

Every feature is audited against the 9 principles in `CLAUDE.md`:

1. **Partitioning** — explicit keys, no shared mutable state per partition
2. **Divide & Conquer** — small functions, recursive decomposition
3. **Producer-Consumer** — decoupled stages with explicit contracts
4. **Queue** — DLQ, retry/backoff, TTL on every async path
5. **Concurrency** — profile-first, bounded pools, designed for interruption
6. **State Tracking** — explicit state machines with transition guards
7. **Progress Tracking** — structured progress events, durable persistence
8. **Parameterization** — no hardcoded timeouts/sizes; units encoded in names
9. **Multi-Strategy** — strategy interface for significant algorithms (Open/Closed)

## Documentation

- **`docs/cli-reference.md`** — every mode, every flag
- **`docs/reference/5w1h-operation-modes-and-flags.md`** — all 23 modes with 5W1H structure
- **`docs/dialect-interface-reference.md`** — all 27 dialect interface methods
- **`docs/transform-helpers-reference.md`** — all 148 JavaScript helpers
- **`docs/guides/pipeline-error-handling.md`** — error handlers + finalizers (when you need pipeline mode)
- **`docs/guides/daemon-operations.md`** — systemd unit, logrotate, health endpoints, runbook, troubleshooting
- **`docs/wizard/README.md`** — interactive transform-script generator
- **`docs/plans/README.md`** — historical design docs, indexed by status
- **`SECURITY.md`** — signing, verification, known limitations
- **`CONTRIBUTING.md`** — toolchain (Go 1.25.7 + gofumpt + golangci-lint), commit convention, pre-commit checklist
- **`CHANGELOG.md`** — release notes

## Status

Production-deployable. Recently completed an 8-wave comprehensive code review closing ~60 P0/High findings and ~5,200 mechanical idiom conversions. See `CHANGELOG.md` for the full log.

Current focus areas (transparent gaps):
- One pre-existing audit test pending fix (`TestEnforcement_ExpiryValidation_AllDBPaths`)
- Pipeline god-package carve-out scheduled for a future refactor wave
- Remaining `slog` rollout in 9 state-package files (blocked by import cycle awaiting resolution)

## Why Not Pipeline-First Tools

If your work is fundamentally bulk CRUD plus lookups, a pipeline framework is overhead.

Other tools force a DSL. Mass Migrator v3 makes simple modes first-class, and the pipeline mode is there when you actually need it — cross-product partitioning, multi-source joins, complex DAG dependencies.

Pick the right tool for the job. Don't pay framework tax for a job that doesn't need a framework.

## License

Commercial. Trial license bundled with binary on first run. See `SECURITY.md` for license signing and verification details.

## Contributing

External contributions welcome. See `CONTRIBUTING.md` for toolchain setup, commit convention (Conventional Commits, enforced by commitlint in CI), and pre-commit checklist.
