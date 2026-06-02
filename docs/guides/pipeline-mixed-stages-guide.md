# Guidelines — Authoring Complex Pipelines with Mixed Single + Fan-Out Steps

> How to design a Mass Migrator v3 pipeline that alternates
> **single → fan-out → single → fan-out → single** with shared global datasets,
> without fighting the engine.

This guide is for pipeline authors. For engine internals see
`docs/marketing/...` and the staged-partitioning design doc at
`docs/plans/2026-04-10-pipeline-staged-partitioning-design.md`.

---

## 1. The three shapes you can put in a step

Every step in your pipeline takes one of three shapes. Pick the right one and the engine will lay out stages correctly without further instruction.

| Shape | What it means | Default for | When to use |
|---|---|---|---|
| **Single (wide)** | One global invocation; sees the full dataset; one worker | `sql`, `set_op` (lookup/join/etc.), `aggregate`, `sort`, `window`, `dedup`, `pivot`, `multi_join`, `rel_migrate`, `rel_write` | DDL, bulk UPDATE, validation, aggregation, anything needing the full view |
| **Fan-out (narrow)** | One invocation **per partition key value**; per-partition workers | `query`, `load`, `transform`, `filter`, `validate`, `project`, `check`, `split`, `read`, `read_from_dataset`, `rel_fetch`, `rel_scan` | Per-region extract, per-customer transform, per-tenant load |
| **Shared dataset** | Reference data **loaded once** at pipeline start; available to all stages and partitions | `shared_datasets:` top-level section | Master tables, dimension lookups, code-list joins |

When you mix shapes, the engine groups consecutive narrow steps with the same partition key into one fan-out stage, and emits a single-worker stage for each wide step. Stage boundaries become barriers (reshuffles).

## 2. The five-question decision tree (run this for every step)

For each step in your design:

```
1. Does this step need the FULL dataset to compute correctly?
       (DDL, bulk UPDATE, aggregate, validate count, …)
   ─── yes ─► Use a WIDE step type, do nothing special. It becomes a single stage.
   ─── no ──► Continue to Q2.

2. Does this step operate INDEPENDENTLY per partition?
       (extract one region, transform one tenant, load one partition, …)
   ─── yes ─► Use a NARROW step type. It joins the current fan-out stage
              IF the partition key matches the previous narrow step.
   ─── no ──► Reconsider — usually means it should be wide.

3. Does this step need a DIFFERENT partition key than the previous step?
   ─── yes ─► Set `partition_by: <new_col>` explicitly. The compiler will
              insert a reshuffle barrier between stages.
   ─── no ──► Inherits from `settings.partition_by`.

4. Is this step normally wide but you NEED it narrow (or vice versa)?
   ─── yes ─► Use `partition_scope: partition` to force narrow,
              or `partition_scope: global` to force wide.
   ─── no ──► Leave it alone.

5. Does this step want a different worker count?
   ─── yes ─► Set `max_parallel_partitions: N` on the step.
   ─── no ──► Inherits from `settings.max_parallel_partitions`.
```

Answer those 5 questions for each step in your pipeline and the YAML almost writes itself.

## 3. The repeatable five-shape pattern

A typical complex pipeline alternates shapes like this:

```
┌────────────────────────────────────────────────────────────────────┐
│  Shared datasets (loaded once, reused everywhere)                   │
│      • customer_master                                              │
│      • product_catalog                                              │
└────────────────────────────────────────────────────────────────────┘
       │
       ▼
┌────────────────────────────────────────────────────────────────────┐
│  Stage 0 — SINGLE 1  (wide, 1 worker)                              │
│      setup_target  (sql DDL)                                       │
└────────────────────────────────────────────────────────────────────┘
       │   barrier (key=∅ → key=region)
       ▼
┌────────────────────────────────────────────────────────────────────┐
│  Stage 1 — FAN-OUT 1  (narrow, K workers, partition_by=region)    │
│      extract_source  (query)                                      │
│      filter_active   (filter)                                     │
└────────────────────────────────────────────────────────────────────┘
       │   barrier (narrow → wide)
       ▼
┌────────────────────────────────────────────────────────────────────┐
│  Stage 2 — SINGLE 2  (wide, 1 worker)                              │
│      compute_region_metrics  (aggregate)                          │
│        writes shared dataset region_metrics                        │
└────────────────────────────────────────────────────────────────────┘
       │   barrier (wide → key=region)
       ▼
┌────────────────────────────────────────────────────────────────────┐
│  Stage 3 — FAN-OUT 2  (narrow, K workers, partition_by=region)    │
│      enrich_with_customer  (set_op lookup, partition_scope=partition)│
│      enrich_with_metrics   (set_op lookup, partition_scope=partition)│
│      load_target           (load)                                  │
└────────────────────────────────────────────────────────────────────┘
       │   barrier (narrow → wide)
       ▼
┌────────────────────────────────────────────────────────────────────┐
│  Stage 4 — SINGLE 3  (wide, 1 worker)                              │
│      validate_counts  (sql)                                        │
│      reconcile_totals (sql)                                        │
└────────────────────────────────────────────────────────────────────┘
```

The engine compiles this layout automatically from your YAML. You don't write barriers; you write the per-step partition declarations and the compiler insets barriers between stage boundaries.

## 4. Worked example — five alternations with two shared datasets

```yaml
name: customer_orders_migration
description: Single → Fan-out → Single → Fan-out → Single, two shared datasets

databases:
  src: { url: "postgresql://...", type: postgresql, pool_size: 20 }
  tgt: { url: "postgresql://...", type: postgresql, pool_size: 20 }

# -----------------------------------------------------------------------------
# Shared datasets — loaded ONCE before stage 0, accessible to every partition
# -----------------------------------------------------------------------------
shared_datasets:
  - name: customer_master
    source: src
    sql: SELECT customer_id, region, tier, segment FROM customer_master
    index: [customer_id]

  - name: product_catalog
    source: src
    sql: SELECT product_id, category, price_band FROM product_catalog
    index: [product_id]

settings:
  partition_by: region                # default partition key for narrow stages
  partition_source_table: orders_src  # where to enumerate distinct regions
  partition_source_column: region
  max_parallel_partitions: 8
  memory_threshold_mb: 4096
  retry_max_attempts: 3
  retry_initial_wait: 100ms

steps:
  # ─── SINGLE 1 — setup target schema (wide; sql is wide by default) ─────────
  - id: setup_target
    type: sql
    database: tgt
    sql:
      - DROP TABLE IF EXISTS orders_clean CASCADE
      - |-
        CREATE TABLE orders_clean (
            order_id BIGINT PRIMARY KEY,
            customer_id BIGINT, region VARCHAR(32),
            customer_tier VARCHAR(16), customer_segment VARCHAR(32),
            product_id BIGINT, product_category VARCHAR(64),
            price_band VARCHAR(16),
            amount DECIMAL(12,2), region_avg_amount DECIMAL(12,2),
            created_at TIMESTAMP
        )

  # ─── FAN-OUT 1 — extract + filter, partitioned by region ───────────────────
  - id: extract_orders
    type: query
    database: src
    sql: |-
      SELECT order_id, customer_id, region, product_id, amount, created_at
      FROM orders_src
    output: orders_raw
    depends_on: [setup_target]

  - id: filter_active
    type: filter
    dataset: orders_raw
    where: "amount > 0 AND created_at >= '2025-01-01'"
    output: orders_active
    depends_on: [extract_orders]
    # both steps run as a SINGLE narrow stage — same partition key (region),
    # same partition source. Stage 1 is the first fan-out.

  # ─── SINGLE 2 — aggregate region-level metrics (wide) ──────────────────────
  # `aggregate` is wide by default → forces a stage boundary + barrier.
  # The output dataset is registered globally so Stage 3 can lookup against it.
  - id: compute_region_metrics
    type: aggregate
    dataset: orders_active
    group_by: [region]
    metrics:
      - { column: amount, function: avg, alias: region_avg_amount }
      - { column: amount, function: sum, alias: region_total }
    output: region_metrics              # becomes globally visible
    depends_on: [filter_active]

  # ─── FAN-OUT 2 — enrich (2 lookups) + load, partitioned by region ──────────
  # `set_op: lookup` defaults to WIDE. We FORCE narrow with partition_scope so
  # both lookups stay in the same fan-out stage as the load. Without this
  # override the engine would emit 3 separate stages with 2 reshuffle barriers.
  - id: enrich_with_customer
    type: set_op
    operation: lookup
    partition_scope: partition          # ← force narrow (the key knob)
    left:  { dataset: orders_active, key: customer_id }
    right: { dataset: customer_master, key: customer_id }
    lookup_columns: [region, tier, segment]
    output: orders_with_customer
    depends_on: [compute_region_metrics]

  - id: enrich_with_metrics
    type: set_op
    operation: lookup
    partition_scope: partition
    left:  { dataset: orders_with_customer, key: region }
    right: { dataset: region_metrics, key: region }
    lookup_columns: [region_avg_amount, region_total]
    output: orders_enriched
    depends_on: [enrich_with_customer]

  - id: load_target
    type: load
    database: tgt
    dataset: orders_enriched
    target_table: orders_clean
    strategy: insert
    batch_size: 5000
    threads: 8
    depends_on: [enrich_with_metrics]

  # ─── SINGLE 3 — validation (wide; sql is wide) ─────────────────────────────
  - id: validate_counts
    type: sql
    database: tgt
    sql: |-
      SELECT COUNT(*) AS loaded, COUNT(DISTINCT region) AS regions,
             SUM(amount) AS total_amount
      FROM orders_clean
    depends_on: [load_target]

  - id: reconcile_totals
    type: sql
    database: tgt
    sql: |-
      DO $$
      DECLARE src_total DECIMAL; tgt_total DECIMAL;
      BEGIN
        SELECT SUM(amount) INTO tgt_total FROM orders_clean;
        SELECT SUM(amount) INTO src_total FROM orders_src;
        IF tgt_total != src_total THEN
          RAISE EXCEPTION 'Total mismatch: src=% tgt=%', src_total, tgt_total;
        END IF;
      END $$;
    depends_on: [validate_counts]
```

What the compiler does with this:

| Stage | Workers | Steps | Barrier on entry? |
|---|---|---|---|
| 0 | 1 | setup_target | none (first stage) |
| 1 | 8 | extract_orders → filter_active | yes (key changed ∅→region) |
| 2 | 1 | compute_region_metrics | yes (wide step) |
| 3 | 8 | enrich_with_customer → enrich_with_metrics → load_target | yes (wide→narrow) |
| 4 | 1 | validate_counts → reconcile_totals | yes (narrow→wide) |

Five alternations. Four barriers. Two shared datasets (`customer_master`, `product_catalog`) plus one dataset built in-flight (`region_metrics`) that becomes a de-facto shared dataset for the second fan-out.

## 5. Shared datasets — the glue between stages

Three rules:

1. **`shared_datasets:` is loaded once, before stage 0.** Use it for reference data your fan-out partitions read but never write. The data lives in memory for the whole run.

2. **A dataset produced mid-pipeline becomes implicitly shared.** When `compute_region_metrics` writes `region_metrics`, every downstream partition can look it up. You don't need to redeclare it under `shared_datasets:`.

3. **For lookup joins, declare `partition_scope: partition` on the `set_op` step.** Otherwise the lookup defaults to wide and runs once globally — which (a) defeats parallelism and (b) drops the per-partition child registry data the downstream load needs.

The third rule is the most common foot-gun and worth saying twice. The `test-6step-pipeline-go.sh` test script comments it explicitly at line 425.

## 6. Per-step controls — the full cheat sheet

These five keys (all on `baseStep` and available on every step type) control fan-out vs single classification:

| Key | Values | Purpose |
|---|---|---|
| `partition_by` | column name | Single-column key override; new key forces a stage boundary |
| `partition_by_columns` | `[col1, col2]` | Composite key override; takes precedence over `partition_by` |
| `partition_scope` | `partition` \| `global` \| `""` | Force narrow / force wide / use default |
| `reshuffle_strategy` | `barrier` \| `requery` \| `stream` | Strategy for the entry barrier of the stage this step starts |
| `max_parallel_partitions` | int ≥ 1 | Per-step worker count override |

Pipeline-level defaults under `settings:`:

| Setting | Effect |
|---|---|
| `partition_by` | Default partition key for all narrow steps |
| `partition_source_table` + `partition_source_column` | Where to enumerate distinct partition values |
| `partition_source_columns` | Composite enumeration source (rare) |
| `max_parallel_partitions` | Default worker count for partitioned stages |
| `reshuffle_strategy` | Default barrier strategy |
| `memory_threshold_mb` | Per-stage memory cap before spill |

## 7. Anti-patterns — common mistakes and how the engine reacts

| You wrote | Engine does | Fix |
|---|---|---|
| Two adjacent narrow steps with different `partition_by` values | Inserts an entry barrier between them; reshuffles data | Make keys match, or accept the barrier cost |
| `set_op: lookup` without `partition_scope: partition` | Treats it as wide → stage boundary → barrier → lookup runs once globally | Add `partition_scope: partition` |
| A `sql` step you intended to run once, no `partition_by` on it, but the pipeline declares a default | `sql` is wide by default — it still runs once because wide overrides the inherited key | Nothing to fix — this is correct behavior |
| `aggregate` step you wanted to run per-partition | Wide by default; runs once globally | Add `partition_scope: partition` to force narrow |
| Shared dataset that only one partition reads | Loaded into memory for all workers regardless | Move to a per-partition `query` step instead of `shared_datasets:` |
| `max_parallel_partitions: 100` on a partition source with 5 distinct values | Engine clamps to `min(100, 5) = 5` | Either fix the partition column choice or accept the clamp |
| `partition_scope: global` on a `load` step | Forces wide stage; entire dataset materialized in one worker | Usually wrong — leave load as narrow |

## 8. Debugging mixed pipelines — observability hooks

Every staged execution emits `state.StateEvent`s you can read from the state DB:

| Event kind | When it fires | What to check |
|---|---|---|
| `EventStageStarted` | Before each stage runs | `ParallelWorkers` (worker count), `Total` (partition count) |
| `EventStageCompleted` | After stage finishes | `PartitionsProcessed`, `DurationMs` |
| `EventBarrierStarted` | Before entry barrier of a stage | `BarrierStrategy` (`barrier` / `requery` / `stream`) |
| `EventBarrierCompleted` | After barrier finishes | `DurationMs` |
| `EventPartitionProgress` | After each partition completes within a stage | Resume cursor — also tells you which partition is slow |

Read these via the state DB or by tailing the run log. If your "5 alternation" pipeline produced 3 stages instead of 5, look at `EventStageStarted` to see the actual layout — you'll spot which steps got fused or wedged into the wrong shape.

### Quick diagnostic checklist

When a pipeline doesn't compile to the shape you expected:

1. **Wrong stage count?** Walk through each step's `NarrowOp()` answer + `partition_scope` override + `partition_by` and apply the compiler rules (Section 2 above) on paper. The compiler is deterministic — you can predict the layout exactly.
2. **A "single" step ran N times?** It's actually narrow + inherited the pipeline-level partition key. Either set `partition_scope: global` or add the step as wide-by-default type.
3. **A "fan-out" step ran with 1 worker?** Either `max_parallel_partitions: 1` somewhere, or the partition source has only 1 distinct value, or the step type is wide-by-default.
4. **A lookup join lost per-partition data?** You forgot `partition_scope: partition` on the `set_op` step. This is the most common bug.
5. **A barrier took longer than the work?** Try `reshuffle_strategy: stream` if downstream consumes sequentially, or `requery` if the upstream output is regenerable from the source table.

## 9. Performance tuning per stage

| Symptom | Stage type | Knob to try |
|---|---|---|
| Stage taking too long, CPU idle | narrow | Increase `max_parallel_partitions` |
| Stage taking too long, CPU pinned | narrow | Already saturated; check partition skew (one big partition holds the rest hostage) |
| Stage taking too long, single worker | wide | This is wide by definition; can you decompose into a fan-out + single? |
| Barrier dominates stage time | any | Try `reshuffle_strategy: stream` (no materialization) |
| Memory pressure during fan-out | narrow | Lower `max_parallel_partitions`; raise `memory_threshold_mb` per stage |
| One partition straggles | narrow | Partition skew. Either change `partition_by` to a higher-cardinality column or add a hash-based salt |
| Shared dataset loads too slowly | n/a | Restrict the SQL with a `WHERE` clause; don't load columns you don't reference |

## 10. Quick reference — when in doubt

| You want | Use |
|---|---|
| Run something once globally | Wide step type (`sql`, `aggregate`, …) — no extra config |
| Run something per partition | Narrow step type (`query`, `load`, `transform`, …) — inherits pipeline `partition_by` |
| Run a normally-wide step per-partition | `partition_scope: partition` |
| Run a normally-narrow step globally | `partition_scope: global` |
| Partition this step by a different key | `partition_by: <new_col>` (and pay the reshuffle cost) |
| Use composite key | `partition_by_columns: [c1, c2]` |
| Give one step more workers than the pipeline default | `max_parallel_partitions: N` on that step |
| Reference data many partitions need | `shared_datasets:` at the top |
| Mid-pipeline data many partitions need | An aggregate step writing to `output: <name>` (becomes implicitly shared) |

## 11. Test it before you ship it

Run the pipeline with a small `RECORD_COUNT` first and read the state events to confirm the stage layout matches your design:

```
tests/test-6step-pipeline-go.sh -r 1000   # canonical 6-step example
```

That test exercises the canonical pattern: setup → extract → enrich (with shared dataset lookup) → load → mass-update → restore. It hits all three shapes plus shared datasets and has working `partition_scope: partition` overrides for reference. Use it as a template.

For the no-pipeline-mode equivalent see `tests/test-6step-simple-mode-go.sh`.

---

## See also

- `internal/pipeline/runtime/stage_compiler.go` — the compiler source. Reading lines 33-162 (the `Compile` function) is the fastest way to understand stage boundary rules at the source-of-truth level.
- `docs/plans/2026-04-10-pipeline-staged-partitioning-design.md` — original design doc.
- `internal/pipeline/runtime/stage_compiler_test.go` — every rule in this guide is pinned by a test there.
- `tests/test-6step-pipeline-go.sh` — canonical worked example.
