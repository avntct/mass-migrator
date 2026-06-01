# 10M Records, 4 Minutes, 4 CLI Commands

**The Saturday-night master-data job, done before midnight.**

---

## The Job

Ten million master records had to move.

Lift from a flat CSV. Load into Postgres. Enrich with province and district names from a lookup table. Mass-rewrite a balance column. Then selectively restore those balances back from the original source file.

Textbook master-data ops. Five distinct operations. Five chances to fail at hour three.

## The Old Way

If you've done this you know the dance.

Row-by-row INSERTs grinding through the night. Silent partial commits. Stares at `pg_stat_activity` wondering whether the lookup join finished. A restore step that needs surgical key matching. A "pipeline" framework that needs its own pipeline to run.

Every real data tool today wants you to learn a DSL, stand up a scheduler, debug YAML, and prove the pipeline is healthy before you can prove your data is healthy.

For a job that's fundamentally: *read file → write rows → update rows*.

The mismatch IS the cost.

## The Different Bet

Mass Migrator takes the opposite bet.

Every routine bulk operation is its own first-class CLI mode. No pipeline DSL required. No YAML scheduler. No Airflow DAG. No Spark cluster.

Same job. Four declarative commands. Composable with raw SQL for the parts SQL already does well — DDL, mass UPDATE, enrichment joins.

## The 4 Modes

**`gencsv`** — synthesize realistic CSV at hundreds of MB/s. One flag per column type: SEQUENTIAL, NORMAL, RANDOM, EMAIL, TIMESTAMP, DECIMAL.

**`csv2db`** — bulk CSV → database with parallel threads, auto-batching, partition routing, optional table auto-create.

**`insert`** — direct DB-to-DB copy with column mapping. Source URL plus target URL plus column list. The engine handles dialect SQL, batching, threading, and partition routing automatically. Source and target can be different dialects.

**`update-ind`** — CSV-driven UPDATE with key matching. Restores any column from any file, partition-routed.

That's it. Four commands. No pipeline YAML. No scheduler.

## The 4 Minutes

Test bed: 10M synthetic rows, single Postgres node, 8 threads, 5,000-row batches.

| Step | Mode | Time |
|---|---|---|
| Generate test CSV | `gencsv` | ~8 seconds |
| Load CSV → Postgres | `csv2db` | ~13 seconds |
| Enrich + copy DB-to-DB | `insert` | ~3 minutes |
| Selective restore from CSV | `update-ind` | ~35 seconds |

**Total: 4 minutes.** Verified row counts, balance sums, enrichment coverage, partition spread.

Reproduction script lives at `tests/test-6step-simple-mode-go.sh`.

## What You Get for Free

No extra config. No extra processes.

- **State checkpoints** — resumable if the box dies mid-run
- **Backpressure** — won't OOM the database
- **Lock-aware batch sizing** — smaller batches when the target is hot
- **Per-partition routing** — no hotspot writes
- **Per-mode TPS metrics** — visible while it runs

All toggled via flags and `MM_` environment variables.

## The Pitch

If your "ETL" is fundamentally bulk CRUD plus lookups, you probably don't need a pipeline framework.

You need a binary that knows your database dialect, batches sensibly, partitions safely, and exits zero.

That's the whole pitch.

**→ github.com/avntct/mass-migrator**

---

*Published 2026-06-01. Based on the simple-mwill vary ±20% depending on disk, network, and target schema complexity.*
ode test in `tests/test-6step-simple-mode-go.sh`. Per-mode timings extrapolated from the 50K-record default test against 8-thread / 5K-batch hardware baselines; real numbers 
