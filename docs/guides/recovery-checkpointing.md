# Recovery and Checkpointing Guide

This guide explains how Mass Migrator v3 handles pipeline recovery, checkpointing, and state persistence.

## Table of Contents

1. [How Checkpointing Works](#how-checkpointing-works)
2. [State Persistence Architecture](#state-persistence-architecture)
3. [Crash Recovery Process](#crash-recovery-process)
4. [Resume from Checkpoints](#resume-from-checkpoints)
5. [State File Management](#state-file-management)
6. [Best Practices](#best-practices)

---

## How Checkpointing Works

### Checkpointing Overview

Mass Migrator v3 supports automatic checkpointing to resume pipelines after failures:

- **Record-level checkpointing:** Track progress after N records
- **Step-level checkpointing:** Mark completed steps
- **State persistence:** SQLite-based state tracking
- **Automatic resume:** Skip completed steps on restart

### Enabling Checkpointing

```yaml
pipeline:
  name: resilient_pipeline
  checkpoint:
    enabled: true
    interval: 10000  # Checkpoint every 10,000 records
    location: "./checkpoints"  # Checkpoint directory
  state:
    backend: "sqlite"
    path: "./state/pipeline.db"

  steps:
    - name: extract_data
      type: query
      database: source
      sql: "SELECT * FROM large_table"
      output: extracted
```

### Checkpoint Interval

Configure how frequently checkpoints are created:

```yaml
steps:
  - name: process_batch
    type: transform
    input: large_dataset
    output: processed
    checkpoint_interval: 50000  # Checkpoint every 50K records
    threads: 8
    script: |
      row.processed = process(row);
```

**Checkpoint Guidelines:**
- Small batches (1K): Frequent checkpoints, slower execution
- Large batches (100K): Infrequent checkpoints, faster execution
- Default: 10,000 records
- Trade-off: Checkpoint overhead vs. rework on failure

### Checkpoint Content

Each checkpoint stores:

```json
{
  "pipeline_id": "my_pipeline",
  "run_id": "2024-04-03T12:00:00Z",
  "step_id": "transform_step",
  "checkpoint_id": 5,
  "records_processed": 50000,
  "timestamp": "2024-04-03T12:15:30Z",
  "status": "completed",
  "metrics": {
    "rows_per_second": 1250,
    "memory_mb": 256,
    "cpu_percent": 45
  }
}
```

---

## State Persistence Architecture

### State Backend

Mass Migrator v3 uses SQLite for state persistence:

```yaml
pipeline:
  name: production_pipeline
  state:
    backend: "sqlite"
    path: "./state/pipeline.db"
    # Optional: Connection pool settings
    max_open_conns: 1
    max_idle_conns: 1
```

### State Schema

The state database contains:

```sql
-- Pipeline runs
CREATE TABLE pipeline_runs (
  run_id TEXT PRIMARY KEY,
  pipeline_name TEXT,
  status TEXT,  -- running, completed, failed, cancelled
  started_at TIMESTAMP,
  completed_at TIMESTAMP,
  error_message TEXT
);

-- Step execution
CREATE TABLE step_executions (
  execution_id TEXT PRIMARY KEY,
  run_id TEXT,
  step_id TEXT,
  status TEXT,  -- pending, running, completed, failed
  started_at TIMESTAMP,
  completed_at TIMESTAMP,
  records_processed INTEGER,
  error_message TEXT,
  FOREIGN KEY (run_id) REFERENCES pipeline_runs(run_id)
);

-- Checkpoints
CREATE TABLE checkpoints (
  checkpoint_id TEXT PRIMARY KEY,
  execution_id TEXT,
  checkpoint_number INTEGER,
  records_processed INTEGER,
  timestamp TIMESTAMP,
  metadata TEXT,  -- JSON
  FOREIGN KEY (execution_id) REFERENCES step_executions(execution_id)
);

-- Heartbeats (for daemon mode)
CREATE TABLE heartbeats (
  job_id TEXT PRIMARY KEY,
  last_heartbeat TIMESTAMP,
  status TEXT,
  metadata TEXT
);
```

### State Tracking Lifecycle

```
Pipeline Start
    │
    ├─→ Create run record (status: running)
    │
    ├─→ For each step:
    │   │
    │   ├─→ Create step execution (status: pending)
    │   │
    │   ├─→ Update to (status: running)
    │   │
    │   ├─→ Process records
    │   │   │
    │   │   ├─→ Every N records: Write checkpoint
    │   │   │
    │   │   └─→ Update heartbeat (every 30s)
    │   │
    │   └─→ Update to (status: completed)
    │
    ├─→ Update run to (status: completed)
    │
    └─→ Cleanup old checkpoints
```

### Heartbeat Monitoring

For long-running pipelines and daemon mode:

```yaml
pipeline:
  name: long_running_pipeline
  heartbeat:
    enabled: true
    interval: 30s  # Heartbeat every 30 seconds
    timeout: 5m    # Mark as stale after 5 minutes
```

Heartbeats prevent duplicate execution:

```go
// Pseudocode
func executeJob(job *Job) {
    if job.inFlight {
        log.Warn("Job already running, skipping")
        return
    }

    job.inFlight = true
    job.LastHeartbeat = time.Now()

    // Execute job
    execute(job)

    job.inFlight = false
}
```

---

## Crash Recovery Process

### Automatic Recovery on Restart

When a pipeline restarts:

1. **Check state database** for existing runs
2. **Identify incomplete steps** (status != completed)
3. **Resume from last checkpoint**
4. **Skip completed steps**

```bash
# Resume pipeline after crash
mass-migrator pipeline --config pipeline.yaml --resume
```

### Recovery Behavior by Step Type

| Step Type | Recovery Behavior |
|-----------|------------------|
| **query** | Re-executes (no checkpointing) |
| **load** | Respects idempotency (upsert: yes, insert: no) |
| **transform** | Resumes from last checkpoint |
| **setop** | Re-executes if not completed |
| **aggregate** | Re-executes if not completed |
| **side-effecting** | Skips if completed (write, load) |

### Idempotent Steps

Some steps are automatically skipped on resume:

```yaml
steps:
  - name: write_to_file
    type: write
    source: results
    path: ./output/results.parquet
    # On resume: Skips if file exists and step is marked completed
```

For non-idempotent steps:

```yaml
steps:
  - name: insert_records
    type: load
    database: target
    dataset: data
    target_table: facts
    strategy: insert  # NOT idempotent - will insert duplicates on resume

  - name: upsert_records
    type: load
    database: target
    dataset: data
    target_table: facts
    strategy: upsert  # Idempotent - safe to resume
    key_columns: [id]
```

### Manual Recovery

Query state to check progress:

```sql
-- Check pipeline status
SELECT
  run_id,
  status,
  started_at,
  completed_at,
  error_message
FROM pipeline_runs
WHERE pipeline_name = 'my_pipeline'
ORDER BY started_at DESC
LIMIT 5;

-- Check step status
SELECT
  step_id,
  status,
  records_processed,
  started_at,
  completed_at
FROM step_executions
WHERE run_id = '2024-04-03T12:00:00Z'
ORDER BY started_at;

-- Check checkpoints
SELECT
  checkpoint_number,
  records_processed,
  timestamp
FROM checkpoints
WHERE execution_id = 'step_exec_123'
ORDER BY checkpoint_number;
```

---

## Resume from Checkpoints

### Resuming Pipelines

```bash
# Resume last run
mass-migrator pipeline --config pipeline.yaml --resume

# Resume specific run
mass-migrator pipeline --config pipeline.yaml --resume-run-id 2024-04-03T12:00:00Z

# Force restart from beginning
mass-migrator pipeline --config pipeline.yaml --force
```

### Resume Configuration

```yaml
pipeline:
  name: resumable_pipeline
  resume:
    enabled: true
    from: "last_checkpoint"  # or "beginning", "step:step_name"
    on_error: "continue"  # or "stop", "skip_step"

  steps:
    - name: step_1
      type: query
      # ...

    - name: step_2
      type: transform
      # If this fails, pipeline continues to step_3
      on_failure: continue

    - name: step_3
      type: write
      # ...
```

### Selective Resume

Resume from specific step:

```yaml
pipeline:
  name: selective_resume
  resume:
    from: "step:transform_data"  # Start from this step

  steps:
    - name: extract_data
      type: query
      # Skipped on resume

    - name: transform_data
      type: transform
      # Starts here on resume

    - name: load_data
      type: load
      # Executes after transform completes
```

### Checkpoint Validation

Validate checkpoint integrity:

```yaml
pipeline:
  name: validated_pipeline
  checkpoint:
    enabled: true
    validate_on_resume: true  # Check checkpoint integrity
    rollback_on_error: true   # Rollback to last valid checkpoint

  steps:
    - name: critical_step
      type: transform
      input: data
      output: result
      checkpoint_interval: 10000
```

---

## State File Management

### Checkpoint Location

```yaml
pipeline:
  name: production_pipeline
  checkpoint:
    enabled: true
    location: "/data/checkpoints"  # Production location
    retention:
      max_age: 7d       # Keep checkpoints for 7 days
      max_count: 10     # Keep last 10 checkpoints
      min_free_space: 1GB  # Require 1GB free space
```

### State Database Location

```yaml
pipeline:
  name: multi_instance_pipeline
  state:
    backend: "sqlite"
    path: "/data/state/pipeline_{{INSTANCE_ID}}.db"
    # Or use environment variable
    path: "${STATE_DIR}/pipeline.db"
```

### Cleanup Strategy

Automatic cleanup of old state:

```yaml
pipeline:
  name: auto_cleanup_pipeline
  state:
    backend: "sqlite"
    path: "./state/pipeline.db"
    cleanup:
      enabled: true
      schedule: "0 2 * * *"  # Daily at 2 AM
      older_than: 30d        # Delete runs older than 30 days
      keep_n_latest: 5       # Always keep latest 5 runs
```

### Backup State

```bash
# Backup state before major changes
cp ./state/pipeline.db ./state/backup/pipeline_$(date +%Y%m%d_%H%M%S).db

# Or within pipeline
steps:
  - name: backup_state
    type: sql
    database: state_db
    sql:
      - "VACUUM INTO './state/backup/pipeline_backup.db'"
```

---

## Best Practices

### 1. Design for Idempotency

Use idempotent operations where possible:

```yaml
# Good: Idempotent
steps:
  - name: load_facts
    type: load
    database: target
    dataset: facts
    target_table: facts
    strategy: upsert  # Safe to resume
    key_columns: [fact_id, date]

# Bad: Not idempotent
steps:
  - name: load_facts
    type: load
    database: target
    dataset: facts
    target_table: facts
    strategy: insert  # Duplicates on resume
```

### 2. Checkpoint at Logical Boundaries

```yaml
steps:
  - name: process_by_partition
    type: query
    database: source
    sql: "SELECT * FROM fact_table WHERE partition_key = :key"
    partition_by: partition_key
    threads: 8
    streaming: true  # Checkpoint after each partition
    output: stream_data
```

### 3. Monitor Heartbeats

```yaml
pipeline:
  name: monitored_pipeline
  heartbeat:
    enabled: true
    interval: 30s
    timeout: 5m
    on_timeout:
      action: "mark_failed"
      notify: true
      message: "Pipeline step timeout"
```

### 4. Handle Side Effects

```yaml
steps:
  - name: write_report
    type: write
    source: analytics
    path: "./reports/daily_report_{{DATE}}.csv"
    # On resume: Checks if file exists
    skip_if_exists: true
```

### 5. Validate State on Resume

```yaml
pipeline:
  name: validated_resume
  resume:
    enabled: true
    validate_state: true
    on_validation_failure:
      action: "restart_from_beginning"
      notify: true
```

### 6. Document Checkpoint Strategy

```yaml
pipeline:
  name: documented_pipeline
  description: |
    ETL pipeline with checkpointing strategy:
    - Checkpoint every 50K records during transform
    - State stored in ./state/pipeline.db
    - Resume from last checkpoint on failure
    - Cleanup old checkpoints after 7 days

  checkpoint:
    enabled: true
    interval: 50000
```

---

## Recovery Scenarios

### Scenario 1: Network Failure

```yaml
# Pipeline fails during network outage
steps:
  - name: fetch_remote_data
    type: query
    database: remote_db
    sql: "SELECT * FROM large_table"
    output: remote_data
    retry:
      max_attempts: 3
      backoff: exponential

# On resume: Step restarts from beginning
# (No checkpointing for query steps)
```

### Scenario 2: Transform Failure

```yaml
# Pipeline fails during transform (bad data)
steps:
  - name: transform_data
    type: transform
    input: source_data
    output: transformed_data
    checkpoint_interval: 10000
    on_error:
      action: "skip_record"
      log_errors: true
    script: |
      try {
        row.transformed = transform(row);
      } catch (e) {
        log.error('Transform failed: ' + e);
        skip();  // Skip bad record
      }

# On resume: Continues from last checkpoint (before bad record)
```

### Scenario 3: Load Failure

```yaml
# Pipeline fails during load (constraint violation)
steps:
  - name: load_data
    type: load
    database: target
    dataset: data
    target_table: facts
    strategy: upsert
    key_columns: [id]
    batch_size: 10000
    on_error:
      action: "continue"  # Skip failed batch
      log_errors: true

# On resume: Continues from last successful batch
```

### Scenario 4: Full Pipeline Crash

```bash
# Pipeline crashes (system failure)
$ mass-migrator pipeline --config pipeline.yaml
# ... crash ...

# Resume from last checkpoint
$ mass-migrator pipeline --config pipeline.yaml --resume
# Resuming from checkpoint 50000 in step 'transform_data'
# Processing records 50001-100000...
```

---

## Troubleshooting

### Check: Pipeline Won't Resume

```sql
-- Check if run exists
SELECT * FROM pipeline_runs
WHERE pipeline_name = 'my_pipeline'
AND status != 'completed';

-- Check if steps are incomplete
SELECT * FROM step_executions
WHERE run_id = '...'
AND status != 'completed';
```

### Check: Stale State

```bash
# Remove stale state
rm ./state/pipeline.db

# Or use cleanup command
mass-migrator state cleanup --older-than 7d
```

### Check: Checkpoint Corruption

```bash
# Validate state database
sqlite3 ./state/pipeline.db "PRAGMA integrity_check;"

# If corrupted, restore from backup
cp ./state/backup/pipeline_backup.db ./state/pipeline.db
```

For more troubleshooting, see [Common Issues](../troubleshooting/common-issues.md).

---

## Complete Example: Resilient ETL Pipeline

```yaml
pipeline:
  name: resilient_etl
  description: "Production ETL with full recovery support"

  # Checkpoint configuration
  checkpoint:
    enabled: true
    interval: 50000  # Every 50K records
    location: "/data/checkpoints"
    retention:
      max_age: 7d
      max_count: 10

  # State persistence
  state:
    backend: "sqlite"
    path: "/data/state/pipeline.db"
    cleanup:
      enabled: true
      schedule: "0 2 * * *"
      older_than: 30d

  # Heartbeat monitoring
  heartbeat:
    enabled: true
    interval: 30s
    timeout: 5m
    on_timeout:
      action: "mark_failed"
      notify: true

  # Resume configuration
  resume:
    enabled: true
    from: "last_checkpoint"
    validate_state: true

  databases:
    source:
      url: "postgresql://source:5432/production"
      username: "user"
      password: "pass"
      type: postgresql
    target:
      url: "postgresql://target:5432/warehouse"
      username: "user"
      password: "pass"
      type: postgresql

  steps:
    # 1. Extract with retry
    - name: extract_data
      type: query
      database: source
      sql: "SELECT * FROM transactions WHERE process_date >= :last_run"
      output: raw_data
      retry:
        max_attempts: 3
        backoff: exponential

    # 2. Validate data
    - name: validate_data
      type: validate
      input: raw_data
      rules:
        - column: transaction_id
          rule: not_null
        - column: amount
          rule: range
          min: "0"
          max: "1000000"
      on_fail: filter
      output: valid_data

    # 3. Transform with checkpointing
    - name: transform_data
      type: transform
      input: valid_data
      output: transformed_data
      checkpoint_interval: 50000
      threads: 8
      on_error:
        action: skip_record
        log_errors: true
      script: |
        row.transaction_date = new Date(row.timestamp);
        row.amount_cents = Math.round(row.amount * 100);
        row.hash_code = hashCode(row.transaction_id);

    # 4. Aggregate (no checkpointing - re-executable)
    - name: aggregate_by_customer
      type: aggregate
      input: transformed_data
      output: customer_totals
      group_by: [customer_id]
      aggregations:
        - column: amount_cents
          function: SUM
          alias: total_amount_cents
        - column: transaction_id
          function: COUNT
          alias: transaction_count

    # 5. Load with upsert (idempotent)
    - name: load_facts
      type: load
      database: target
      dataset: customer_totals
      target_table: customer_daily_facts
      strategy: upsert
      key_columns: [customer_id, fact_date]
      batch_size: 10000
      threads: 4
      static_columns:
        - fact_date
        - updated_at
      static_values:
        - "=CURRENT_DATE"
        - "=NOW()"

    # 6. Write report (side-effecting, skipped on resume)
    - name: write_report
      type: write
      source: customer_totals
      path: "/reports/customer_totals_{{DATE}}.csv"
      format: csv
      skip_if_exists: true

    # 7. Update watermark (idempotent)
    - name: update_watermark
      type: sql
      database: target
      sql:
        - "INSERT INTO watermarks (pipeline_name, last_run_date) VALUES ('resilient_etl', CURRENT_DATE)"
        - "ON CONFLICT (pipeline_name) DO UPDATE SET last_run_date = CURRENT_DATE"
```

For more information, see:
- [Performance Optimization Guide](./performance-optimization.md)
- [Configuration Reference](../reference/configuration.md)
- [CLI Reference](../reference/cli-commands.md)
