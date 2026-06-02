# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Mass Migrator v3 — a Go CLI tool for database migration, ETL, and incremental sync across 7 database dialects. Module: `github.com/massmigrator/mass-migrator`, Go 1.25.7.

## Build & Test Commands

```bash
# Build
make build                    # → dist/mass-migrator
go build -o mass-migrator ./cmd/mass-migrator

# Test
make test                     # go test -v -race ./...
make test-unit                # go test -v -race -short ./...
make test-integration         # go test -v -race -tags=integration ./...
go test ./internal/pipeline/ -run TestSpecificName -v -race   # single test

# Lint (CI uses golangci-lint with 30+ linters — see .golangci.yml)
go vet ./...
# gofumpt formatting with lang-version 1.25
```

## Architecture

### Execution Flow

```
CLI (cobra) → cmd/mass-migrator/ (23 operation modes)
  → config/ (YAML + env var interpolation + profiles)
  → pipeline/runner.go RunDefinition()
    → DAG topological sort → parallel level execution
    → per-step ExecuteStep() dispatch via PipelineStep interface
    → dialect/ generates SQL → strategy/ executes write pattern
```

### Core Abstractions

**PipelineStep interface** (`internal/pipeline/step.go`): All 23 step types implement this. `baseStep` provides common fields. Parser uses type discriminator (`rawStepEntry.Type`) → `stepRegistry` factory map → concrete type decode.

**DatabaseDialect** (`internal/dialect/`): Segregated interfaces (PlaceholderProvider, IdentifierEscaper, StatementBuilder, etc.) composed per dialect. 7 implementations: PostgreSQL, MySQL, SQLite, SQL Server, Oracle, Neo4j (stub), Netezza (stub). Key method: `Placeholder(idx)` returns `$1` / `?` / `:1` depending on dialect.

**Write Strategies** (`internal/pipeline/strategy/`): `insert` / `update` / `merge` / `upsert` — each takes `*sql.Tx`, auto-calculates batch size from dialect param limits × column count.

**ExecutionContext** (`internal/pipeline/executor.go`): Shared state for all steps — DB pools, dialects, dataset registry, variables (thread-safe via mutex), transform engine, state writer, watermark tracker, retry helper, DLQ.

### Key Packages

| Package | Purpose |
|---------|---------|
| `internal/pipeline/` | DAG engine, 23 step executors, parser, runner, error handlers, finalizers |
| `internal/pipeline/batch_poller/` | High-throughput incremental sync: claim→fetch→process→update pipeline |
| `internal/dataset/` | In-memory dataset registry with parent-child scoping, lazy/refresh strategies |
| `internal/dialect/` | 7 database dialect implementations with segregated interfaces |
| `internal/transform/` | goja JS engine with 100+ helpers, 20 action types, 5s timeout, sandbox hardening |
| `internal/watermark/` | Incremental sync state: independent/incremental/overlap modes, composite columns |
| `internal/operator/` | 11 dataset set operators (JOIN, UNION, MINUS, etc.), hash-join + sort-merge |
| `internal/kafka/` | Producer/consumer with bounded reader, async producer |
| `internal/retry/` | Error classification (280+ patterns), exponential backoff, circuit breaker |
| `internal/orchestrator/recovery/` | DLQ (dead letter queue), retry helper |
| `internal/pipeline/state/` | Event-based state tracking, SQLite/PostgreSQL/MySQL/SQL Server/Oracle backends |
| `internal/memory/enclave/` | Per-step memory quotas with spill-to-disk |

### Pipeline Error Handling (recently added)

Steps can declare `on_error:` handlers (sequential, depth-1) and pipelines can declare `finalizers:` (run on detached context, survive SIGTERM). Runner has 3 phases: DAG loop → error handler phase → finalizer phase. See `runner_error_handlers.go`.

### Batch Poller Pipelined Mode

4-stage producer-consumer: `PartitionedClaimer` (SKIP LOCKED, hash-partition) → `BulkFetcher` (accumulate + bulk SELECT) → `ProcessorPool` (W workers, per-record) → `BatchedUpdater` (timer + batch flush). All parameters runtime YAML config. See `docs/plans/2026-04-07-high-throughput-batch-poller-design.md`.

## Conventions

- **Testing**: stdlib only (no testify). Table-driven tests with `t.Run`. Integration tests use `//go:build integration` tag.
- **SQL safety**: All identifiers via `ValidateIdentifier()` regex + `dialect.EscapeIdentifier()`. All values via parameterized queries (`Placeholder(idx)`). Never string-interpolate user values into SQL.
- **Error wrapping**: Always `fmt.Errorf("context: %w", err)`.
- **Formatting**: gofumpt with lang-version 1.25. Imports ordered: stdlib, external, local (`github.com/massmigrator/mass-migrator`).
- **Secrets**: Use `config.SecretString` type — auto-redacts in logs.
- **DB drivers wired in**: `cmd/mass-migrator/drivers.go` (blank imports for pgx, mysql, mssql, ora, sqlite).
- **Upsert/Merge**: Key columns excluded from UPDATE SET clause.
- **SQLite**: `SupportsConcurrentWrites()=false`, `MaxOpenConns=1`, WAL mode pragmas applied automatically.

## Architecture Principles

> From `architecture-principles.md`. Apply to ALL features. When writing, refactoring, or reviewing code — audit against every principle.

1. **Partitioning** — Partition data/workload by explicit key (range, hash, list). Each partition fully independent, no shared mutable state. Document the key choice and reasoning.
2. **Divide & Conquer** — Decompose large problems into independent sub-problems with clear input/output. No function exceeds 50 lines. Recursive decomposition if still too large.
3. **Producer-Consumer** — Producer and consumer completely decoupled, zero direct calls. Explicit contract (interface, schema, message format) at the boundary. Each side independently scalable.
4. **Queue** — Every async task routes through a queue. Every queue defines: dead-letter policy, retry with backoff, TTL. Consumer must be idempotent.
5. **Concurrency** — Profile bottleneck before adding goroutines. All shared state protected (mutex, atomic, or immutable). Always use bounded pools. Design for interruption at any point.
6. **State Tracking** — Every stateful entity has an explicit state machine. Every transition logged with timestamp, actor, previous/new state. Invalid transitions rejected at the boundary.
7. **Progress Tracking** — Long-running ops emit structured progress events (current_step, total_steps, percent, ETA). Progress persisted to durable store.
8. **Parameterized** — Never hardcode timeouts, batch sizes, retry counts, thresholds, URLs, or limits. Every parameter has a documented default and is overridable. Names encode units: `timeout_ms`, `batch_size_rows`.
9. **Multi-strategy** — Significant algorithms implement a strategy interface selected via runtime parameter. Default strategy documented with rationale. Adding strategies must not modify existing ones (Open/Closed).

**When reviewing code**, audit against the checklist: partitioning, divide & conquer, producer-consumer, queue contract, concurrency safety, state machine, progress tracking, parameterization, strategy extensibility. If a principle cannot be applied, explain why in a code comment.

## Error Root Cause Analysis Framework

> From `error-rca-framework.md`. When any error, bug, or failure is encountered, perform the full RCA before proposing any fix.

**Step 1 — 5W1H**: What failed (observed vs expected)? When (first occurrence, intermittent/consistent)? Where (module, function, line)? Who (actor, process, thread)? Why (initial hypothesis)? How (error message, stack trace, data state)?

**Step 2 — 5 Whys**: From symptom, ask "Why?" recursively until reaching a systemic root cause (design or assumption failure), not just a surface bug. Stop before 5 if genuine root cause reached; continue past 5 if needed.

**Step 3 — Chain of Thought**: Step-by-step trace from root cause → observed failure. Each step follows from the previous. Mark unverifiable steps as `[HYPOTHESIS]`.

**Step 4 — Tree of Thought**: Generate 3+ independent hypotheses. Evaluate each with evidence for/against. Select most probable with justification. Do not collapse to single hypothesis prematurely.

**Step 5 — Causes & Consequences**: Map upstream causal chain AND downstream impact chain. Assess blast radius: scope, severity, recurrence risk, latent failures.

**Step 6 — Fix Proposal**: Only after Steps 1-5. Structure as: Immediate Fix (stop the bleeding) → Root Fix (eliminate root cause) → Regression Guard (test to prevent recurrence) → Monitoring (alert/metric for early detection). Fixing symptoms without addressing root cause is not acceptable.

## graphify

This project has a graphify knowledge graph at graphify-out/.

Current state (2026-04-28): 11,116 nodes, 43,118 edges, 129 communities. AST-only (no semantic extraction).

Rules:
- Before answering architecture or codebase questions, read graphify-out/GRAPH_REPORT.md for god nodes and community structure
- If graphify-out/wiki/index.md exists, navigate it instead of reading raw files
- **Known artifact:** Top 4 god nodes (Errorf, Join, Now, contains) are AST fan-out from utility functions — not real architectural bridges. The actual finding is that `internal/log`, `internal/transform`, and `internal/dsl` form the project's utility spine.
- After modifying code files in this session, run `python3 -c "from graphify.watch import _rebuild_code; from pathlib import Path; _rebuild_code(Path('.'))"` to keep the graph current
- Semantic extraction for 298 non-code files is pending — run `/graphify --update` after adding significant documentation

## Agent skills

### Issue tracker

Issues live as GitHub issues, managed via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Uses default triage labels: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context layout: `CONTEXT.md` and `docs/adr/` at repo root. See `docs/agents/domain.md`.
