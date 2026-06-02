# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

No tagged release exists yet; entries below are grouped by the comprehensive
review cycle that produced them. Dates refer to the cycle close date, not a
release date.

## [Unreleased]

### Added
- Cosign keyless signing and SLSA L3 provenance generation for release artifacts
- Daemon control socket peer-credential authentication (`SO_PEERCRED` on Linux, `getpeereid` on Darwin) plus `0o600` socket mode
- Real `AcquireRunLock` implementation for the Oracle and SQLite state backends (sentinel `run_locks` table with unique `run_id`)
- State-machine transition guards and a `state_transitions` audit table across all state-store backends
- Batch poller idempotency-key support, default-on for the relay path
- `Verifying releases` section in `SECURITY.md` documenting the Cosign and `slsa-verifier` flows
- `Known Limitations` section in `SECURITY.md` recording the three remediated Phase 2A criticals
- Comprehensive code review and security hardening pass (2026-05-31)
- SQL injection prevention for MySQL bulk loader table names
- Memory guard for sort-merge join to prevent OOM
- Identifier validation for load/write step executors
- Test coverage for `internal/genpipeline` (27 tests) and `internal/agentstate` (22 tests)
- Shared `internal/action/params` package for deduplicated helper functions

### Changed
- `CONTRIBUTING.md` toolchain updated: `gofumpt` (lang-version 1.25) and `golangci-lint` replace `gofmt`/`golint`; Go version bumped to 1.25.7 to match `go.mod`
- Pre-commit checklist (`gofumpt -l .`, `golangci-lint run`, `go test -race ./...`, `go vet ./...`) added to `CONTRIBUTING.md`

### Fixed
- `CompileStep` interface methods now implemented on `baseStep` (commit c57bd61)
- Keyless retry path now guarded; keyless key-requiring write strategies are rejected up front (commit cec7d99)
- Three test failures: shutdown deadlock, test wait windows, and `run_immediately` handling (commit 3d2da1c)
- Cron parse error no longer silently falls back to hourly schedule
- Kafka producer/consumer stubs now log warnings when called
- `Config.Load()` now wraps errors with context
- `time.Sleep` in retry path now respects context cancellation
- SQL Server bulk insert now uses dialect `EscapeIdentifier` consistently

### Security
- Removed test scaffolding from the production binary; `go list -deps ./cmd/mass-migrator` no longer includes the `testing` package
- Daemon PID file mode tightened to `0o600`
- HTTP health server now sets read/write/idle timeouts (Slowloris mitigation)

## [Pre-release - 2026-05]

### Added
- Cross-product partitioned execution: star-schema main x shared dimension model with `SharedPartitionCache` (lazy / probe / preload modes), grouped and fanout scheduling, and `CrossProductScheduler` with incremental result merge
- `{{.partition_filter}}` template injection for cross-product WHERE-clause generation
- Scheduled pipeline daemon integrated into the `mass-migrator` binary
- DAG-level `on_error` handlers (depth-1, sequential) and pipeline-level `finalizers` that run on a detached context and survive `SIGTERM`
- 4-stage pipelined batch poller: `PartitionedClaimer` (SKIP LOCKED, hash partitioned), `BulkFetcher`, `ProcessorPool` (W workers), `BatchedUpdater` (timer + batch flush)
- `TupleINBuilder` dialect interface with 5-dialect support
- Pipeline `init` command, templates, lint engine, and DB type detection
- Browser-based config wizard for all modes and pipeline steps (with advanced settings, group processing, dynamic JDBC placeholders)
- Maeda Laws of Simplicity work: profiles, validation, defaults, dry-run split, ETA, tiered help, trust touches
- Decomposed relationship migration steps (`rel_scan`, `rel_fetch`, `rel_write`) plus composite-key relationship migration engine
- Multi-dialect relationship support: PostgreSQL, MySQL, SQL Server, Oracle with lifecycle test
- TPC-H full lifecycle test (9 stages, 96 validation checks)
- Group-query execution, parallel file import, parquet batch tuning
- Declarative query builder with 5-dialect SQL generation
- Staged partitioning runtime with 3 reshuffle strategies
- Batch state tracking, WAL, resume, progress (3-phase implementation)
- Unified poller step

### Fixed
- DAG context cancellation propagation in parallel execution (SD-002, SD-003, SD-004)
- Test setup panic in DAG cancellation tests (SD-005)
- Cross-product finalizer: double-query eliminated, noise warnings suppressed
- 32 findings from Round 3 comprehensive review (2026-05-06): 7 fixed (P0-1, P1-1/2/3/5/6/8), 2 accepted-risk
  - Key fixes: sort-merge data race, context leak, unbounded memory, variables-map race, interpolation bypass, spill type loss, `scanRows` cap
- `csv2db`: auto-discover columns from file headers when `--columns` not provided
- `MigrateParallel` relationship: single scanner, fan-out fetch, serialized writes
- Composite-key duplicate INSERT and multi-column continuation in relationship migration
- `--help-all` flag must be persistent; help function iterates `PersistentFlags`

### Security
- Daemon control socket and run-lock hardening landed in Wave 1A / 2A (carried through to Unreleased)

## [Pre-release - 2026-04]

### Added
- Flink-inspired features (Phase 1 + Phase 2 + Phase 3)
- Modes upgrade: resume, checkpoint, parallel export
- Dataset-driven file loading plus state-tracking enhancements

### Fixed
- 48 findings from Round 2 comprehensive review (2026-04-18); 47 fixed, 1 deferred (P1-13 persistent flags)
  - Notable items: context leak, sort-merge data race, variables-map race, interpolation bypass
- Dotted identifier escaping in query, plus declarative args wiring
- Per-partition child registries and `colTypesCache` sharing

## [Pre-release - 2026-03]

### Added
- Initial Mass Migrator v3 Go codebase: 7 dialects (PostgreSQL, MySQL, SQLite, SQL Server, Oracle, Neo4j, Netezza), 23 operation modes, 11 dataset operators
- 100+ JavaScript transform helpers running in a goja sandbox (5s timeout, prototype-chain freezing)
- Watermark system with independent, incremental, and overlap modes (composite columns, hash detection)
- Pipeline engine improvements: job execution dedup, dataset dependency cycle detection, job heartbeat / watchdog, queue fairness with aging, skew-aware join strategy
- Data engine T1-T7: watermark, dataset scoping, operators, drivers, scripting, security, executor refactor
- Kafka push and pull paths with 82 new tests and mock interfaces for cluster-free testing
- License enforcement: thread limits, expiry validation, anti-tamper across all execution paths
- SHA-256 binary self-hash integrity check

### Fixed
- 43 findings from Round 1 comprehensive review (2026-03-27); all Critical and High items resolved

### Security
- Closed 7 remaining what-if vulnerabilities identified in the 50-item security analysis
- Closed 3 remaining dev-period attack vectors; eliminated `MM_DEV_MODE` in favour of a time-bound dev period
- Mutex-during-I/O fix (WI-17)
