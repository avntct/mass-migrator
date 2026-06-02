# Pipeline Error Handling Guide

This guide covers the pipeline engine's error handling features: `on_error` handlers, finalizers, and the recovery sweeper.

## Table of Contents

1. [Overview](#overview)
2. [on_error Basics](#on_error-basics)
3. [Pipeline Finalizers](#pipeline-finalizers)
4. [Recovery Sweeper](#recovery-sweeper)
5. [Best Practices](#best-practices)
6. [Example: Full HDR/DTL Pipeline](#example-full-hdrdtl-pipeline)

---

## Overview

### The Problem

In claim-process-update workflows, a common failure mode leaves records stuck in an intermediate state. Consider a pipeline that:

1. Claims records by setting `status = 'P'` (processing)
2. Transforms the data
3. Marks records as `status = 'Y'` (completed)

If step 2 or 3 fails -- due to a bug, a timeout, or a crash -- the records remain in `status = 'P'` indefinitely. No one is coming back to clean them up. Operators must manually reset these records, and downstream systems stall waiting for data that will never arrive.

### The Solution

Mass Migrator v3 provides three complementary mechanisms to prevent stuck records:

- **on_error handlers**: Inline error recovery that runs immediately when a step fails. Use these to roll back status changes and log errors at the point of failure.

- **Pipeline finalizers**: Always-run blocks that execute after the pipeline completes, regardless of success or failure. Use these for audit logging and resource cleanup.

- **Recovery sweeper**: A background goroutine that periodically scans for records stuck in intermediate states beyond a timeout threshold. This is the last-resort safety net for cases where even the error handler fails.

Together, these three layers ensure that no record is left behind.

---

## on_error Basics

### YAML Syntax

Attach an `on_error` block to any step that needs error recovery:

```yaml
steps:
  - id: process_orders
    type: transform
    engine: goja
    script: scripts/process.js
    on_error:
      - id: rollback_status
        type: sql
        database: main
        sql: "UPDATE order_header SET status = 'E' WHERE id IN (:claimed_ids)"
      - id: log_error
        type: sql
        database: main
        sql: |
          INSERT INTO error_log (step_id, error_message, error_type, occurred_at)
          VALUES (:_error_step, :_error_message, :_error_type, NOW())
```

### How It Works

When a step with an `on_error` block fails:

1. The pipeline engine captures the error context (step ID, message, error type).
2. The `on_error` handlers execute **sequentially** in the order they are declared.
3. Each handler receives the error context as variables that can be referenced in SQL and scripts.
4. After all handlers complete (or fail), the pipeline marks the original step as failed and continues with DAG evaluation -- steps that depend on the failed step are skipped, but independent branches proceed.

### Depth Limit

Error handlers have a **depth limit of 1**. An `on_error` block cannot itself have an `on_error` block. This prevents infinite error-handling chains and keeps the execution model predictable.

```yaml
# VALID: on_error on a regular step
steps:
  - id: process
    type: transform
    on_error:
      - id: handle_error    # This is an error handler
        type: sql
        sql: "UPDATE ..."
        # on_error: [...]   # NOT VALID: no nesting allowed
```

### Error Context Variables

Inside `on_error` handlers, the following context variables are available:

| Variable | Type | Description |
|----------|------|-------------|
| `_error_step` | string | The `id` of the step that failed |
| `_error_message` | string | The error message from the failed step |
| `_error_type` | string | The category of error (e.g., `timeout`, `sql_error`, `transform_error`, `connection_error`) |

Use these in SQL or scripts:

```yaml
on_error:
  - id: log_failure
    type: sql
    database: main
    sql: |
      INSERT INTO step_errors (step_id, message, error_type, ts)
      VALUES (:_error_step, :_error_message, :_error_type, NOW())
```

### When an Error Handler Fails

If an `on_error` handler itself fails, the failure is recorded in the **dead-letter queue (DLQ)**. The DLQ entry includes:

- The original step that failed
- The error handler that failed
- Both error messages
- A timestamp

DLQ entries are written to the pipeline state store and can be queried for monitoring. The pipeline continues execution (skipping dependent steps) even if the error handler fails.

---

## Pipeline Finalizers

### YAML Syntax

Finalizers are declared at the top level of the pipeline, alongside `steps`:

```yaml
name: order_pipeline
databases:
  main: { url: "...", type: postgresql }

steps:
  - id: claim
    type: sql
    # ...
  - id: process
    type: transform
    # ...

finalizers:
  - id: audit_log
    type: sql
    database: main
    sql: |
      INSERT INTO pipeline_audit (name, status, error, failed_steps, run_id, completed_at)
      VALUES (:_pipeline_name, :_pipeline_status, :_pipeline_error, :_failed_steps, :_run_id, NOW())

  - id: cleanup_temp
    type: sql
    database: main
    sql: "DELETE FROM temp_staging WHERE run_id = :_run_id"

settings:
  finalizer_timeout: 30s
```

### Always-Run Guarantee

Finalizers are designed to run under all circumstances:

- **Normal completion**: Finalizers run after all steps finish successfully.
- **Step failure**: Finalizers run after failure handling completes, even if some steps were skipped.
- **Pipeline cancellation**: Finalizers run when the pipeline is cancelled via context cancellation.
- **SIGTERM**: Finalizers use a **detached context** that survives the original context's cancellation. When the process receives SIGTERM, the pipeline cancels running steps but still executes finalizers within the `finalizer_timeout` window.

Finalizers execute sequentially in declaration order. If a finalizer fails, the remaining finalizers still execute.

### Pipeline Context Variables

Finalizers have access to pipeline-level context variables:

| Variable | Type | Description |
|----------|------|-------------|
| `_pipeline_name` | string | The pipeline `name` from the YAML |
| `_pipeline_status` | string | `success`, `failed`, or `cancelled` |
| `_pipeline_error` | string | The error message if the pipeline failed; empty on success |
| `_failed_steps` | string | Comma-separated list of step IDs that failed; empty on success |
| `_run_id` | string | A unique identifier for this pipeline execution |

### Configuring Finalizer Timeout

The `finalizer_timeout` setting controls how long the pipeline waits for finalizers to complete after the main execution finishes. The default is 30 seconds.

```yaml
settings:
  finalizer_timeout: 30s   # Default
  finalizer_timeout: 2m    # For slow audit inserts
  finalizer_timeout: 5s    # For fast cleanup only
```

If a finalizer exceeds the timeout, it is forcefully cancelled and the remaining finalizers are attempted within the remaining time budget.

---

## Recovery Sweeper

### Enabling the Recovery Sweeper

The recovery sweeper is disabled by default. Enable it in the `settings` block:

```yaml
settings:
  recovery_enabled: true
  recovery_timeout: 5m
  recovery_sweep_interval: 1m
```

### Configuration Options

| Setting | Default | Description |
|---------|---------|-------------|
| `recovery_enabled` | `false` | Enable the background recovery sweeper |
| `recovery_timeout` | `5m` | How long a record can stay in "processing" state before being considered stuck |
| `recovery_sweep_interval` | `1m` | How often the sweeper checks for stuck records |

### How It Works

The recovery sweeper runs as a background goroutine alongside the pipeline daemon:

1. Every `recovery_sweep_interval`, the sweeper queries for records that have been in "processing" state longer than `recovery_timeout`.
2. It **skips records that are actively being handled** by a current pipeline run. This prevents conflicts between the sweeper and in-progress error handlers.
3. For each stuck record, the sweeper resets the status to the error state and logs the recovery action.
4. The sweeper runs with its own database connection to avoid contention with pipeline steps.

### Last-Resort Safety Net

The recovery sweeper is intentionally the last line of defense:

```
Step fails
  --> on_error handler runs (immediate, inline)
    --> on_error fails? DLQ entry created
      --> Recovery sweeper catches it (background, periodic)
```

In normal operation, `on_error` handlers resolve failures within milliseconds. The recovery sweeper only activates when both the step and its error handler have failed, or when the process crashed before error handling could run.

---

## Best Practices

### 1. Always Use on_error for Claim-Process-Update Patterns

Any step that modifies record state (especially claim steps that set a "processing" status) should have a corresponding `on_error` handler to roll back the state change on failure.

```yaml
- id: process
  type: transform
  on_error:
    - id: rollback
      type: sql
      sql: "UPDATE orders SET status = 'E' WHERE id IN (:claimed_ids)"
```

### 2. Keep Error Handlers Simple

Error handlers should do one thing: update the status and optionally log the error. Avoid complex logic, external API calls, or multi-step operations in error handlers. The simpler the handler, the less likely it is to fail.

```yaml
# Good: simple status update
on_error:
  - id: mark_failed
    type: sql
    sql: "UPDATE orders SET status = 'E' WHERE id IN (:claimed_ids)"

# Avoid: complex multi-step error handling
on_error:
  - id: notify_slack
    type: http           # External dependency -- may also fail
    url: "https://..."
  - id: retry_transform
    type: transform      # Retrying the failed operation -- risky
    script: retry.js
```

### 3. Use Finalizers for Audit Logging

Finalizers are the right place for audit trails because they run regardless of outcome. Do not rely on a regular step for audit logging, as it will be skipped if a previous step fails.

```yaml
finalizers:
  - id: audit
    type: sql
    database: main
    sql: |
      INSERT INTO pipeline_audit (name, status, run_id, completed_at)
      VALUES (:_pipeline_name, :_pipeline_status, :_run_id, NOW())
```

### 4. Enable the Recovery Sweeper in Production

The recovery sweeper costs almost nothing (one lightweight query per interval) and prevents records from being stuck indefinitely. Always enable it in production:

```yaml
settings:
  recovery_enabled: true
  recovery_timeout: 5m
```

### 5. Monitor the DLQ

If error handlers are failing, the DLQ captures the evidence. Set up monitoring or periodic queries against the DLQ to catch systemic issues early -- for example, a database connection pool exhaustion that causes both the step and its error handler to fail.

### 6. Set Recovery Timeout Appropriately

The recovery timeout should be significantly longer than your expected processing time. A good rule of thumb is 2-3x the maximum expected batch processing duration. Too short causes false positives; too long delays recovery.

---

## Example: Full HDR/DTL Pipeline

This example shows a complete header/detail (HDR/DTL) processing pipeline with error handling at every layer.

### Scenario

- An `order_header` table contains orders with a `status` column.
- An `order_detail` table contains line items linked by `order_id`.
- The pipeline claims unprocessed orders, validates them, processes the details, and marks completion.

### Pipeline YAML

```yaml
name: hdr_dtl_processing

databases:
  main:
    url: "postgres://user:pass@localhost:5432/orders"
    type: postgresql

daemon:
  schedule: "*/1 * * * *"

steps:
  # Step 1: Claim a batch of unprocessed orders
  - id: claim_orders
    type: sql
    database: main
    sql: |
      UPDATE order_header SET status = 'P', updated_at = NOW()
      WHERE id IN (
        SELECT id FROM order_header
        WHERE status = 'N'
        ORDER BY created_at
        LIMIT 50
        FOR UPDATE SKIP LOCKED
      )
      RETURNING id
    output_dataset: claimed_ids

  # Step 2: Fetch full header records
  - id: fetch_headers
    type: query
    depends_on: [claim_orders]
    database: main
    query: "SELECT * FROM order_header WHERE id IN (:claimed_ids)"
    output_dataset: headers

  # Step 3: Fetch detail records for claimed orders
  - id: fetch_details
    type: query
    depends_on: [claim_orders]
    database: main
    query: "SELECT * FROM order_detail WHERE order_id IN (:claimed_ids)"
    output_dataset: details

  # Step 4: Validate headers (business rules)
  - id: validate_headers
    type: transform
    depends_on: [fetch_headers]
    engine: goja
    script: scripts/validate_order_header.js
    input_dataset: headers
    output_dataset: validated_headers
    on_error:
      - id: mark_validation_failed
        type: sql
        database: main
        sql: |
          UPDATE order_header
          SET status = 'E', error_message = :_error_message, updated_at = NOW()
          WHERE id IN (:claimed_ids)

  # Step 5: Process details (calculate totals, apply discounts)
  - id: process_details
    type: transform
    depends_on: [validated_headers, fetch_details]
    engine: goja
    script: scripts/process_order_details.js
    input_dataset: details
    output_dataset: processed_details
    on_error:
      - id: mark_processing_failed
        type: sql
        database: main
        sql: |
          UPDATE order_header
          SET status = 'E', error_message = :_error_message, updated_at = NOW()
          WHERE id IN (:claimed_ids)

  # Step 6: Write processed details back
  - id: save_details
    type: sql
    depends_on: [process_details]
    database: main
    sql: |
      UPDATE order_detail
      SET processed = true, discount_amount = :discount, net_total = :net_total
      WHERE id = :detail_id
    on_error:
      - id: mark_save_failed
        type: sql
        database: main
        sql: |
          UPDATE order_header
          SET status = 'E', error_message = 'Detail save failed', updated_at = NOW()
          WHERE id IN (:claimed_ids)

  # Step 7: Mark orders as completed
  - id: mark_completed
    type: sql
    depends_on: [save_details]
    database: main
    sql: |
      UPDATE order_header
      SET status = 'Y', completed_at = NOW(), updated_at = NOW()
      WHERE id IN (:claimed_ids)

finalizers:
  - id: audit_log
    type: sql
    database: main
    sql: |
      INSERT INTO pipeline_audit
        (pipeline_name, status, error, failed_steps, run_id, completed_at)
      VALUES
        (:_pipeline_name, :_pipeline_status, :_pipeline_error, :_failed_steps, :_run_id, NOW())

  - id: metrics
    type: sql
    database: main
    sql: |
      INSERT INTO pipeline_metrics
        (pipeline_name, run_id, records_claimed, status, duration_ms, completed_at)
      VALUES
        (:_pipeline_name, :_run_id,
         (SELECT count(*) FROM order_header WHERE id IN (:claimed_ids)),
         :_pipeline_status, :_pipeline_duration_ms, NOW())

settings:
  recovery_enabled: true
  recovery_timeout: 5m
  recovery_sweep_interval: 1m
  finalizer_timeout: 30s
```

### How This Pipeline Handles Failures

| Failure scenario | What happens |
|-----------------|-------------|
| Database unreachable at claim time | `claim_orders` fails, no records claimed, no cleanup needed. Finalizer logs the failure. |
| Validation logic error in step 4 | `on_error` sets `status = 'E'` on all claimed orders. Steps 5-7 are skipped (they depend on step 4). Finalizer logs which step failed. |
| Detail processing fails in step 5 | `on_error` sets `status = 'E'`. Steps 6-7 are skipped. Finalizer logs the failure. |
| Detail save fails in step 6 | `on_error` sets `status = 'E'`. Step 7 is skipped. Finalizer logs the failure. |
| Process crashes mid-execution | No `on_error` runs. Records remain in `status = 'P'`. Recovery sweeper detects them after 5 minutes and resets to `status = 'E'`. |
| Error handler itself fails | DLQ entry created. Records remain in `status = 'P'`. Recovery sweeper catches them after timeout. |
