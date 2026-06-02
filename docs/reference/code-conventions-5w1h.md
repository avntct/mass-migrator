# Mass Migrator v3 -- Code Conventions & Architectural Reference (5W1H)

## Table of Contents

1. [Architectural Patterns](#1-architectural-patterns)
2. [Naming Conventions](#2-naming-conventions)
3. [Error Handling Patterns](#3-error-handling-patterns)
4. [Concurrency Patterns](#4-concurrency-patterns)
5. [Security Patterns](#5-security-patterns)
6. [Testing Conventions](#6-testing-conventions)
7. [Dependencies & Build](#7-dependencies--build)

---

## 1. Architectural Patterns

### 1.1 Strategy Pattern

| Dimension | Detail |
|-----------|--------|
| **What** | A family of interchangeable SQL generation algorithms hidden behind a single `InsertModeStrategy` interface |
| **Who** | The orchestration layer (csv_migration.go) selects and uses strategies; each writer goroutine gets its own instance |
| **When** | At migration start, after the insert mode is resolved from config (`insert`, `update`, `merge`, `upsert`) |
| **Where** | `internal/strategy/` -- strategy.go (interface + factory), insert.go, update.go, merge.go, upsert.go |
| **Why** | INSERT, UPDATE, MERGE, and UPSERT generate fundamentally different SQL (single-row vs multi-row, key-clause handling, dialect-specific syntax). A switch statement in every write path would be unmaintainable |
| **How** | `NewStrategy(strategyType, dialect, table, columns, keyColumns, batchSize)` factory returns the concrete implementation |

**Interface:**

```go
// internal/strategy/strategy.go
type InsertModeStrategy interface {
    ExecuteBatch(ctx context.Context, tx *sql.Tx, records []*record.Record) error
    ExecuteBatchWithGroup(ctx context.Context, tx *sql.Tx, records []*record.Record, group *CompositeGroup) error
    ExecuteSingle(ctx context.Context, tx *sql.Tx, rec *record.Record) error
    Close() error
}
```

**Factory:**

```go
func NewStrategy(strategyType string, d dialect.DatabaseDialect, ...) (InsertModeStrategy, error) {
    switch strategyType {
    case "insert":
        return NewInsertStrategy(d, table, columns), nil
    case "update":
        return NewUpdateStrategy(d, table, columns, keyColumns), nil
    case "merge":
        return NewMergeStrategy(d, table, columns, keyColumns), nil
    case "upsert":
        return NewUpsertStrategy(d, table, columns, keyColumns), nil
    default:
        return nil, fmt.Errorf("unknown strategy type: %s", strategyType)
    }
}
```

**Key detail:** `maxParamsPerStatement = 65000` caps multi-row INSERT batch size to stay under PostgreSQL's 65535 limit. Calculated automatically via `safeMultiRowBatchSize(numColumns)`.

---

### 1.2 Segregated Interface (Dialect)

| Dimension | Detail |
|-----------|--------|
| **What** | A composite `DatabaseDialect` interface assembled from 11 fine-grained capability interfaces |
| **Who** | Each database dialect (PostgreSQL, MySQL, SQLite, SQL Server, Oracle, Neo4j, Netezza) implements the full composite |
| **When** | At connection open time via `dialect.NewDialect(dbType)` |
| **Where** | `internal/dialect/dialect.go` |
| **Why** | Dialects have heterogeneous capabilities. SQL Server and Oracle need `MergeBuilder`; SQLite does not support concurrent writes. Segregated interfaces let consumers accept only the capability they need |
| **How** | 11 interfaces composed into one via Go embedding |

**Segregated interfaces:**

```go
type DialectMetadata interface { ... }        // GetDatabaseType, GetDriverName, SupportsConcurrentWrites, SupportsUpsert
type PlaceholderProvider interface { ... }     // Placeholder(idx int) string  -- "$1" vs "?"
type IdentifierEscaper interface { ... }       // EscapeIdentifier, CastPlaceholder
type AutoIncrementDetector interface { ... }   // IsAutoIncrementColumn, GetAutoIncrementColumns
type InsertBuilder interface { ... }           // BuildInsertStatement, BuildInsertStatementWithStatic
type UpdateBuilder interface { ... }           // BuildUpdateStatement, BuildUpdateStatementWithStatic
type UpsertBuilder interface { ... }           // BuildUpsertStatement, BuildUpsertStatementWithStatic
type MergeBuilder interface { ... }            // BuildMergeStatement, BuildMergeStatementWithStatic
type TypeMapper interface { ... }              // MapDataType, BuildCreateTableStatement, GetPrimaryKeyColumns
type ReturningHandler interface { ... }        // SupportsReturningClause, SupportsBatchReturning
type IdentityHandler interface { ... }         // NeedsIdentityInsert (SQL Server IDENTITY_INSERT ON/OFF)
type StaticExpressionMapper interface { ... }  // MapStaticExpression (NOW() -> dialect-specific)

// Composite
type DatabaseDialect interface {
    DialectMetadata
    PlaceholderProvider
    IdentifierEscaper
    AutoIncrementDetector
    InsertBuilder
    UpdateBuilder
    UpsertBuilder
    MergeBuilder
    TypeMapper
    ReturningHandler
    IdentityHandler
    StaticExpressionMapper
}
```

---

### 1.3 Registry Pattern (Dataset)

| Dimension | Detail |
|-----------|--------|
| **What** | Central dataset storage with memory tracking, parent-child scoping, and three load strategies (eager, lazy, refreshable) |
| **Who** | Pipeline steps produce and consume datasets; the `ExecutionContext` owns the root registry |
| **When** | Root registry created at pipeline start; child registries created for step-scoped isolation |
| **Where** | `internal/dataset/registry.go`, `lazy.go`, `refresh.go` |
| **Why** | Prevents OOM by tracking estimated bytes per dataset, enables cross-step data sharing, and supports auto-release when datasets are no longer referenced by remaining steps |
| **How** | `Register/Get/Remove` with byte accounting; `AutoRelease(neededNames)` garbage-collects unreferenced datasets between DAG levels |

**Memory guard:**

```go
func (r *DatasetRegistry) Register(ds *Dataset) error {
    // ...
    if r.memoryThreshold > 0 && r.currentBytes+newBytes > r.memoryThreshold {
        return fmt.Errorf("memory threshold exceeded: registering %q (%d bytes) would exceed limit (%d bytes, current: %d bytes)",
            ds.Name, newBytes, r.memoryThreshold, r.currentBytes)
    }
    // ...
}
```

**Parent-child chain:** `NewChildRegistry()` creates a child that falls through to the parent on reads but keeps writes local. Used for step-scoped datasets.

**Load strategies:**
- **Eager:** `Register(ds)` -- dataset materialized immediately.
- **Lazy:** `RegisterLazy(name, loader)` -- `sync.Once` triggers loader on first `Get()`.
- **Refreshable:** `RegisterRefreshable(ctx, name, loader, interval)` -- `atomic.Pointer` swap on a background ticker; readers never block.

---

### 1.4 Object Pool (Record)

| Dimension | Detail |
|-----------|--------|
| **What** | `sync.Pool` for `Record` structs to reuse allocations in hot paths |
| **Who** | Transform engines, CSV readers, and any code processing rows at scale |
| **When** | Any per-row loop where allocation frequency would dominate GC time |
| **Where** | `internal/record/record.go` |
| **Why** | Billion-row migrations generate billions of `Record` objects. Pool reuse eliminates per-row `map[string]int` allocations |
| **How** | `AcquireRecord()` / `ReleaseRecord(r)` bracket usage; `SharedIndex` avoids even the index map rebuild |

```go
var recordPool = sync.Pool{
    New: func() interface{} {
        return &Record{
            fieldNames:  make([]string, 0, 16),
            fieldValues: make([]interface{}, 0, 16),
            fieldIndex:  make(map[string]int, 16),
        }
    },
}

func AcquireRecord() *Record { return recordPool.Get().(*Record) }

func ReleaseRecord(r *Record) {
    r.fieldNames = r.fieldNames[:0]
    r.fieldValues = r.fieldValues[:0]
    clear(r.fieldIndex)     // Go 1.21+ builtin
    recordPool.Put(r)
}
```

**SharedIndex optimization:** For CSV reads with uniform headers, `NewSharedIndex(columns)` builds the column-to-index map once and shares it (read-only) across all records via `NewRecordShared(si, values)`. This eliminates per-row map allocation entirely.

---

### 1.5 Producer-Consumer Pattern

| Dimension | Detail |
|-----------|--------|
| **What** | Single reader goroutine dispatches row batches over a buffered channel to N writer goroutines |
| **Who** | CSV migration orchestrator (`internal/orchestrator/migration/csv_migration.go`) |
| **When** | During the main migration loop (lines 370-510) |
| **Where** | `internal/orchestrator/migration/csv_migration.go` |
| **Why** | Decouples read speed from write speed; reader is I/O-bound, writers are DB-bound. N writers multiply DB throughput |
| **How** | Buffered channel (`threads*2` capacity), `sync.WaitGroup` for writer shutdown, `atomic.Int64` for progress tracking, `context.WithCancel` for error propagation |

```go
type batchMsg struct { records []*record.Record }

batchCh := make(chan batchMsg, threads*2)      // back-pressure via channel capacity
var writerWg sync.WaitGroup
writerErrCh := make(chan error, threads)
var totalWritten atomic.Int64

// Spawn writer workers -- each gets its own Strategy instance (thread safety)
for w := 0; w < threads; w++ {
    writerWg.Add(1)
    go func() {
        defer writerWg.Done()
        strat, _ := strategy.NewStrategy(...)
        for msg := range batchCh {
            recovery.WriteBatchWithRetry(ctx, db, retryHelper, func(ctx context.Context, tx *sql.Tx) error {
                return strat.ExecuteBatch(ctx, tx, msg.records)
            })
            totalWritten.Add(int64(len(msg.records)))
        }
    }()
}

// Producer loop
for { rec, _ := csvReader.Read(); batch = append(batch, rec); ... ; batchCh <- batchMsg{batch} }
```

**Error propagation:** Writers send to `writerErrCh`; producer checks it with `select/default` (non-blocking) on every iteration. `cancel()` signals all parties.

---

### 1.6 DAG Scheduler

| Dimension | Detail |
|-----------|--------|
| **What** | Event-driven step execution respecting dependency ordering, without level batching |
| **Who** | Pipeline runner for complex multi-step pipelines |
| **When** | At pipeline run time, after parsing and DAG validation |
| **Where** | `internal/pipeline/scheduler.go` |
| **Why** | Level-based execution wastes time: if step C depends only on step A, it must wait for all of level 1 (A + B) to finish. Event-driven scheduling starts C as soon as A completes |
| **How** | Semaphore (buffered channel) for concurrency cap, `findAndMarkReady()` checks dependency satisfaction, `doneCh` feeds completions back to the main loop, `releaseUnneeded()` frees datasets after each step |

```go
sem := make(chan struct{}, d.effectiveParallel())  // concurrency semaphore

for {
    ready := d.findAndMarkReady()    // steps with all deps satisfied, not yet launched
    for _, stepID := range ready {
        sem <- struct{}{}            // acquire semaphore slot
        go func(id string) {
            defer func() { <-sem }() // release on finish
            err := d.executeWithStateTracking(ctx, id, ectx)
            doneCh <- stepResult{id: id, err: err}
        }(stepID)
    }
    // Wait for at least one step to complete, which may unlock new dependents
    result := <-doneCh
    d.markCompleted(result.id)
    d.releaseUnneeded(ectx)
    ready = d.findAndMarkReady()
}
```

**Resume support:** `SetCompletedSteps(completed)` pre-marks side-effecting steps as done; idempotent steps re-execute to rebuild datasets.

---

### 1.7 Classifier (Static Values)

| Dimension | Detail |
|-----------|--------|
| **What** | Parse, classify, and route static column values into four evaluation tiers |
| **Who** | The orchestrator before the migration loop |
| **When** | At config parsing time, before any rows are processed |
| **Where** | `internal/staticval/classifier.go` |
| **Why** | Static values have four fundamentally different evaluation paths: global literals (once per migration), global DB expressions (once per SQL statement), group-level placeholders (once per partition), and record-level functions (once per row) |
| **How** | Regex-based classification with priority ordering: group `${...}` > record prefix `record.` > lowercase function calls > DB function whitelist > safe expression pattern > fallback |

**Classification levels:**

| Level | Example | Evaluated |
|-------|---------|-----------|
| `LevelGlobalLiteral` | `"WEST"`, `"42"` | Once, embedded as literal |
| `LevelGlobalExpr` | `=NOW()`, `=CURRENT_TIMESTAMP` | Once per SQL statement (DB evaluates) |
| `LevelGroup` | `=${province}`, `=${filename}` | Once per partition group |
| `LevelRecord` | `=uuid()`, `=nextSeq('id')`, `=record.name` | Once per row |

**Record evaluator** uses `atomic.Int64` for thread-safe sequence counters and `uuid.New()` for per-row UUIDs.

---

### 1.8 Background Watchdog (License)

| Dimension | Detail |
|-----------|--------|
| **What** | Periodic background re-validation of license integrity using system clock + database server clocks |
| **Who** | Started by the pipeline runner after DB connections are open |
| **When** | Every 1 hour (default `DefaultWatchdogInterval`) for the lifetime of the pipeline |
| **Where** | `internal/license/watchdog.go` |
| **Why** | Long-running pipelines (hours/days) need continuous license validation. System clock tampering can be detected by cross-referencing DB server clocks |
| **How** | Ticker goroutine with stop channel; 4-step check cycle: re-verify Ed25519 signature, collect clocks, detect drift, multi-clock consensus expiry |

```go
func (w *Watchdog) check() {
    // Step 1: Re-verify Ed25519 signature
    payload, err := VerifyLicense(w.licenseKey, w.publicKey)

    // Step 2: Collect clocks (system + DBs, concurrently)
    clocks := CollectClocks(ctx, w.config.DBClocks, w.config.ClockQueryTimeout)

    // Step 3: Drift detection (backward clock = tampering)
    drift := DetectClockDrift(w.prevClocks, clocks, w.config.ClockDriftThreshold)

    // Step 4: Multi-clock consensus expiry
    ValidateExpiry(payload.ExpiresAt, clocks, w.config.GracePeriod)
}

func (w *Watchdog) degradeToFree(reason string) {
    freeGate := NewGate(nil)
    forceSetDefaultGate(freeGate)    // bypasses write-once guard
}
```

**Graceful degradation:** On any validation failure, the watchdog degrades to free tier rather than terminating the pipeline.

---

## 2. Naming Conventions

### File Naming

| Pattern | Example | Usage |
|---------|---------|-------|
| `executor_{steptype}.go` | `executor_query.go`, `executor_load.go` | One file per pipeline step type executor |
| `helpers_{category}.go` | `helpers_string.go`, `helpers_datetime.go` | Transform helper function groups |
| `{noun}.go` | `registry.go`, `scheduler.go`, `record.go` | Primary type definition |
| `{noun}_test.go` | `registry_scoping_test.go`, `operator_test.go` | Test files paired with source |

### Package Naming

Single lowercase word, no underscores:

```
dialect/    operator/    transform/    watermark/
dataset/    pipeline/    strategy/     record/
security/   license/     staticval/    reader/
```

### Interface Naming

Capability-based (what it can do), not role-based:

```go
InsertBuilder           // builds INSERT statements
MergeBuilder            // builds MERGE statements
TypeMapper              // maps data types
PlaceholderProvider     // provides parameter placeholders
AutoIncrementDetector   // detects auto-increment columns
IdentifierEscaper       // escapes SQL identifiers
InsertModeStrategy      // strategy for insert modes
RecordGetter            // gets/sets record fields
StepExecutor            // executes pipeline steps
```

### Test Naming

Pattern: `Test{Function}_{Scenario}` or `Test{Feature}_{Scenario}`:

```go
func TestValidateExpiry_MajorityValid(t *testing.T)
func TestDetectClockDrift_SystemClockRegression(t *testing.T)
func TestValidateIdentifier_DangerousPatterns(t *testing.T)
func TestClassify_GroupPlaceholder(t *testing.T)
func TestRefreshableDataset_ReloadOnInterval(t *testing.T)
```

### Error Format

Always wrap with context using `fmt.Errorf("context: %w", err)`:

```go
return fmt.Errorf("parse pipeline: %w", err)
return fmt.Errorf("connect to %s: %w", name, err)
return fmt.Errorf("step %s has unresolvable dependency: %s", step.ID(), dep)
return fmt.Errorf("shared dataset %q: query failed: %w", sd.Name, err)
return fmt.Errorf("memory threshold exceeded: registering %q (%d bytes) would exceed limit (%d bytes, current: %d bytes)",
    ds.Name, newBytes, r.memoryThreshold, r.currentBytes)
```

### Constant Naming

Exported constants use PascalCase; unexported use camelCase:

```go
// Exported
const DefaultWatchdogInterval = 1 * time.Hour
const DefaultClockDriftThreshold = 5 * time.Minute

// Unexported
const maxParamsPerStatement = 65000
const maxIdentifierLength = 128
const parallelBufSize = 1024 * 1024
const minChunkBytes = 10 * 1024 * 1024
```

---

## 3. Error Handling Patterns

### 3.1 Retry with Exponential Backoff

**Where:** `internal/orchestrator/recovery/retry.go`

```go
type RetryConfig struct {
    MaxAttempts int           // 1 = no retry (default: 3)
    InitialWait time.Duration // doubles each retry (default: 100ms)
    MaxWait     time.Duration // cap (default: 10s)
}
```

Backoff formula: `initialWait * 2^(attempt-1)`, capped at `maxWait`, with crypto/rand jitter (0.5x to 1.5x) to prevent thundering herd.

Only retryable errors are retried (connection errors, deadlocks, timeouts, SQLite busy). Non-retryable errors fail immediately.

```go
func WriteBatchWithRetry(ctx context.Context, db *sql.DB, retry *RetryHelper, execFn func(ctx context.Context, tx *sql.Tx) error) error {
    return retry.ExecuteWithRetry(ctx, func() error {
        tx, err := db.BeginTx(ctx, nil)
        if err != nil { return fmt.Errorf("failed to begin transaction: %w", err) }
        if err := execFn(ctx, tx); err != nil { tx.Rollback(); return fmt.Errorf("batch execution failed: %w", err) }
        if err := tx.Commit(); err != nil { return fmt.Errorf("failed to commit: %w", err) }
        return nil
    })
}
```

### 3.2 Error Tracking with Threshold

**Where:** `internal/orchestrator/recovery/retry.go` (same file, `ErrorTracker` type)

```go
type ErrorTracker struct {
    mu               sync.Mutex
    maxAllowedErrors int       // -1 = unlimited, 0 = fail on first
    failFastMode     bool
    errorCount       int
}

// RecordError returns true if processing should continue
func (t *ErrorTracker) RecordError(err error) bool { ... }
```

Three modes:
- **Fail-fast** (`failFastMode=true`): Stop on first error.
- **Zero tolerance** (`maxAllowedErrors=0`): Stop on first error.
- **Threshold** (`maxAllowedErrors=N`): Allow up to N errors before stopping.

### 3.3 Fail-Fast vs Continue-On-Error (Pipeline)

The pipeline runner supports both modes via `def.Settings.ContinueOnError`:

```go
if stepErr != nil {
    if def.Settings.ContinueOnError {
        fmt.Printf("Step %s failed (continuing): %v\n", s.ID(), stepErr)
    } else {
        errCh <- fmt.Errorf("step %s failed: %w", s.ID(), stepErr)
        levelCancel()   // Cancel sibling steps in same level
    }
}
```

### 3.4 State Persistence for Resume

**Where:** `internal/pipeline/state/writer.go`

Non-blocking event emission with channel-based async persistence:

```go
func (w *StateWriter) Emit(event StateEvent) {
    select {
    case w.events <- event:
    default:
        dropped := w.dropped.Add(1)       // back-pressure: drop rather than block
        if dropped%1000 == 0 { ... }
    }
}
```

Events flush to JSONL log first (crash recovery source of truth), then SQLite. On resume, `GetCompletedSteps(runID)` queries SQLite for already-completed steps.

### 3.5 Graceful Degradation (License)

On any license validation failure, the system degrades to free tier rather than hard-stopping:

```go
func (w *Watchdog) degradeToFree(reason string) {
    freeGate := NewGate(nil)               // nil payload = free tier
    forceSetDefaultGate(freeGate)          // bypasses write-once guard
}
```

State recovery also degrades gracefully:

```go
sw, swErr := state.Recover(swConfig)
if swErr != nil {
    fmt.Printf("[WARN] State recovery failed, starting fresh: %v\n", swErr)
    sw, swErr = state.NewStateWriter(swConfig)
    if swErr != nil {
        fmt.Printf("[WARN] State writer creation failed, proceeding without state tracking: %v\n", swErr)
    }
}
```

### 3.6 Dead Letter Queue

**Where:** `internal/orchestrator/recovery/dead_letter.go`

Failed records are persisted to a CSV file for later analysis or retry. Requires enterprise license (`feature.dlq`). Thread-safe via `sync.Mutex`.

---

## 4. Concurrency Patterns

### 4.1 sync.Pool for Record Reuse

```go
// internal/record/record.go
var recordPool = sync.Pool{
    New: func() interface{} {
        return &Record{
            fieldNames:  make([]string, 0, 16),   // pre-allocate capacity 16
            fieldValues: make([]interface{}, 0, 16),
            fieldIndex:  make(map[string]int, 16),
        }
    },
}
```

Used in hot CSV/transform loops. `ReleaseRecord` clears via `clear(r.fieldIndex)` (Go 1.21+ builtin) and slice reslice to zero length.

### 4.2 sync.Once for Lazy Dataset Loading

```go
// internal/dataset/lazy.go
type LazyDataset struct {
    loader   func() (*Dataset, error)
    once     sync.Once
    dataset  *Dataset
    err      error
    resolved atomic.Bool
}

func (ld *LazyDataset) Resolve() (*Dataset, error) {
    ld.once.Do(func() {
        ld.dataset, ld.err = ld.loader()
        ld.resolved.Store(true)
    })
    return ld.dataset, ld.err
}
```

Concurrent callers block until the first load completes. `IsResolved()` is lock-free via `atomic.Bool`.

### 4.3 atomic.Pointer for Refreshable Datasets

```go
// internal/dataset/refresh.go
type RefreshableDataset struct {
    current atomic.Pointer[Dataset]    // readers never block
    // ...
}

func (rd *RefreshableDataset) Get() *Dataset {
    return rd.current.Load()           // lock-free read
}

// Background goroutine:
func (rd *RefreshableDataset) refreshLoop(ctx context.Context) {
    for {
        select {
        case <-ticker.C:
            ds, err := rd.loader()
            if err != nil { continue }   // keep previous on error
            rd.current.Store(ds)         // atomic swap
        case <-ctx.Done():
            return
        }
    }
}
```

### 4.4 atomic.Int64 for Counters and Sequences

```go
// Parallel CSV reader row counter
type ParallelCSVReader struct {
    rowCount atomic.Int64
}
rowNum := p.rowCount.Add(1)

// Producer-consumer write counter
var totalWritten atomic.Int64
totalWritten.Add(int64(len(msg.records)))

// Static value sequence generator
type recordEvalSpec struct {
    seq *atomic.Int64
}
val = spec.seq.Add(1)   // thread-safe per-row sequence

// StateWriter dropped event counter
type StateWriter struct {
    dropped atomic.Int64
}
```

### 4.5 sync.RWMutex for ExecutionContext Variables

```go
// internal/pipeline/executor.go
type ExecutionContext struct {
    Variables map[string]interface{}
    varsMu    sync.RWMutex
}

func (e *ExecutionContext) SetVariable(key string, val interface{}) {
    e.varsMu.Lock()
    defer e.varsMu.Unlock()
    e.Variables[key] = val
}

func (e *ExecutionContext) GetVariable(key string) (interface{}, bool) {
    e.varsMu.RLock()
    defer e.varsMu.RUnlock()
    v, ok := e.Variables[key]
    return v, ok
}
```

`WithRegistry()` performs a shallow copy of the Variables map (new map, same value references) to prevent concurrent map structure writes. The `varsMu` is reset to a fresh zero-value.

### 4.6 Semaphore (Buffered Channel) for Parallel Step Limit

```go
// internal/pipeline/scheduler.go
sem := make(chan struct{}, d.effectiveParallel())

// Acquire before launching step
sem <- struct{}{}

// Release when step completes
defer func() { <-sem }()
```

### 4.7 Producer-Consumer with Buffered Channels

```go
// internal/orchestrator/migration/csv_migration.go
batchCh := make(chan batchMsg, threads*2)

// Writers consume
for msg := range batchCh { ... }

// Producer sends
batchCh <- batchMsg{records: batch}

// Shutdown: close channel, WaitGroup for orderly drain
close(batchCh)
writerWg.Wait()
```

---

## 5. Security Patterns

### 5.1 SQL Injection Prevention: ValidateIdentifier

**Where:** `internal/pipeline/sql_identifier.go`

Six-layer validation for SQL identifiers (table names, column names):

1. **Empty check**
2. **Length check** (max 128 characters)
3. **Null byte detection** (truncation attacks)
4. **Non-ASCII rejection** (Unicode normalization attacks)
5. **Strict regex** (`^[a-zA-Z_][a-zA-Z0-9_]*$`)
6. **Dangerous pattern denylist** (34 patterns: `--`, `/*`, `;`, `xp_`, `exec`, `drop`, `union`, `sleep(`, `or 1=1`, etc.)

```go
var strictIdentifier = regexp.MustCompile(`^[a-zA-Z_][a-zA-Z0-9_]*$`)

func ValidateIdentifier(name string) error {
    // ... 6 layers ...
}
```

Also provides `ValidateQualifiedIdentifier(name)` for `schema.table` format and `EscapeIdentifier(name)` as ANSI double-quote escaping (last resort).

### 5.2 Static Value Escaping

**Where:** `internal/dialect/dialect.go`

```go
func escapeStaticValue(v string) string {
    return strings.ReplaceAll(v, "'", "''")
}
```

### 5.3 Expression Whitelist

**Where:** `internal/dialect/dialect.go`

```go
var safeDefaultPattern = regexp.MustCompile(
    `(?i)^(?:` +
        `-?\d+(?:\.\d+)?` +                    // numeric literals
        `|'(?:[^']*(?:''[^']*)*)'` +           // single-quoted strings
        `|NULL|TRUE|FALSE` +
        `|CURRENT_TIMESTAMP|CURRENT_DATE|CURRENT_TIME` +
        `|NOW\(\)|GETDATE\(\)|SYSDATE|NEWID\(\)|UUID\(\)|GEN_RANDOM_UUID\(\)` +
    `)$`)

func sanitizeDefaultValue(val string) string {
    if safeDefaultPattern.MatchString(trimmed) { return trimmed }
    return ""   // reject unsafe values
}
```

### 5.4 SQL Interpolation (Type-Safe)

**Where:** `internal/pipeline/interpolate.go`

Only allows known safe types for SQL variable interpolation. Rejects all others:

```go
func formatInterpolationValue(val interface{}) (string, error) {
    switch v := val.(type) {
    case string:  return "'" + escapeSQL(v) + "'", nil     // quote-escaped
    case int:     return fmt.Sprintf("%d", v), nil          // bare integer
    case int64:   return fmt.Sprintf("%d", v), nil
    case float64: return fmt.Sprintf("%g", v), nil          // bare float
    case bool:    if v { return "TRUE", nil }; return "FALSE", nil
    case nil:     return "NULL", nil
    default:      return "", fmt.Errorf("unsupported type %T for SQL interpolation ...", val)
    }
}
```

`escapeSQL` escapes both backslashes (MySQL bypass protection) and single quotes.

### 5.5 JS Sandbox

**Where:** `internal/transform/sandbox.go`

Defense-in-depth for user-provided JavaScript in transform steps:

1. **Prototype freeze:** `Object.prototype.constructor` made read-only; `Function.prototype.constructor` replaced with throw function; `__proto__` blocked
2. **Seal prototypes:** `Object.seal()` on all 9 built-in prototypes
3. **Remove dangerous globals:** `eval`, `Function`, `Reflect`, `Proxy`, `process`, `global`, `globalThis`, `__filename`, `__dirname`
4. **Call stack limit:** `vm.SetMaxCallStackSize(256)` (configurable)
5. **Execution timeout:** `time.AfterFunc` with `vm.Interrupt()` (default 5s)
6. **Module path traversal blocking:** `..`, absolute paths, and backslash rejected

### 5.6 License Integrity

- **Ed25519 binary signing:** `VerifyLicense(keyString, publicKey)` verifies signature before parsing payload
- **Write-once gate:** `SetDefaultGate` uses `atomic.Bool` CAS to prevent repeated overwrite; only `forceSetDefaultGate` (internal, used by watchdog) can bypass
- **Multi-clock validation:** System clock + N database server clocks; majority consensus for expiry
- **Drift detection:** System clock regression (moved backward) or cross-clock divergence exceeding threshold

### 5.7 DSN Redaction

**Where:** `internal/security/redact.go`

```go
func RedactDSN(dsn string) string {
    // URL-style: postgresql://user:pass@host -> postgresql://user:***@host
    // Key-value: password=secret -> password=***
}
```

---

## 6. Testing Conventions

### Framework

Standard library `testing` only. No testify, no gomock, no external assertion libraries.

```go
if got != want {
    t.Errorf("FunctionName(%v) = %v, want %v", input, got, want)
}
```

### Race Detection

All tests run with `-race`:

```bash
go test -race ./internal/...
```

### Database Tests

SQLite in-memory for unit tests:

```go
db, err := sql.Open("sqlite", ":memory:")
```

### Table-Driven Tests

```go
func TestValidateIdentifier(t *testing.T) {
    tests := []struct {
        name    string
        input   string
        wantErr bool
    }{
        {"valid simple", "users", false},
        {"injection attempt", "users; DROP TABLE users;--", true},
        // ...
    }
    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            err := ValidateIdentifier(tt.input)
            if (err != nil) != tt.wantErr {
                t.Errorf("ValidateIdentifier(%q) error = %v, wantErr %v", tt.input, err, tt.wantErr)
            }
        })
    }
}
```

### Helper Functions

Use `t.Helper()` for test utility functions. Use `t.TempDir()` for temporary file system state.

### Integration Tests

Shell scripts with colored output and verification queries in `scripts/`:

```bash
scripts/test_kafka.sh
scripts/test_all_kafka.sh
```

---

## 7. Dependencies & Build

### Key Dependencies

| Dependency | Version | Purpose |
|-----------|---------|---------|
| `github.com/spf13/cobra` | v1.8.1 | CLI framework (23 operation modes) |
| `github.com/spf13/viper` | v1.19.0 | Configuration management (profiles, interpolation) |
| `github.com/dop251/goja` | 2026-02 | JavaScript transform engine (100+ helpers) |
| `github.com/google/uuid` | v1.6.0 | UUID generation (static values, record-level) |
| `github.com/jackc/pgx/v5` | v5.8.0 | PostgreSQL driver |
| `github.com/go-sql-driver/mysql` | v1.9.3 | MySQL driver |
| `modernc.org/sqlite` | v1.46.1 | Pure-Go SQLite driver (no CGO) |
| `github.com/microsoft/go-mssqldb` | v1.9.8 | SQL Server driver |
| `github.com/sijms/go-ora/v2` | v2.9.0 | Oracle driver |
| `github.com/segmentio/kafka-go` | v0.4.50 | Kafka producer/consumer |
| `github.com/aws/aws-sdk-go-v2` | v1.41.3 | S3 client for remote I/O |
| `github.com/parquet-go/parquet-go` | v0.28.0 | Parquet file read/write with encryption |
| `golang.org/x/crypto` | v0.48.0 | Ed25519 license verification |
| `gopkg.in/yaml.v3` | v3.0.1 | Pipeline definition parsing |

### Go Version

```
go 1.25.7
```

### Build Commands

**Standard build:**

```bash
go build -o mass-migrator ./cmd/mass-migrator/
```

**Production build with license support:**

```bash
go build -ldflags "-s -w" -o mass-migrator ./cmd/mass-migrator/
```

The binary is signed with Ed25519 for license integrity verification. When the binary signature check fails (unsigned/dev build), the system falls back to `NewDevGate()` which grants enterprise tier for development.

### Dev Mode vs Production Mode

| Aspect | Dev Mode | Production |
|--------|----------|------------|
| License gate | `NewDevGate()` -- enterprise tier, ID=`dev-mode` | `VerifyLicense()` -- tier from signed payload |
| Binary signing | Skipped (integrity check fails) | Ed25519 verified |
| Watchdog | Not started (payload ID = `dev-mode`) | Started with 1h interval |
| Feature access | All features unlocked | Tier-gated (`free` < `pro` < `enterprise`) |

### Driver Registration

Database drivers are imported for side-effects in a single file:

```go
// cmd/mass-migrator/drivers.go
import (
    _ "github.com/jackc/pgx/v5/stdlib"     // PostgreSQL
    _ "github.com/go-sql-driver/mysql"      // MySQL
    _ "github.com/microsoft/go-mssqldb"     // SQL Server
    _ "github.com/sijms/go-ora/v2"          // Oracle
    _ "modernc.org/sqlite"                   // SQLite
)
```
