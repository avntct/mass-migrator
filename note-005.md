./tests/test-6step-simple-mode-go.sh -r 10000000


================================================================================
  Mass Migrator v3 (Go) - 6-Step Equivalent WITHOUT pipeline mode
  Binary: ./mass-migrator
================================================================================

Replaces pipeline YAML with: psql DDL/DML + simple modes only
  Step 0:  Create province-district map (psql)
  Step 1:  Generate CSV          [gencsv]
  Step 2:  CSV → import_table    [csv2db]
  Step 3a: Create clone table    (psql DDL)
  Step 3b: Create staging table  (psql CREATE TABLE AS SELECT JOIN)
  Step 3c: staging → clone       [insert]  (DB-to-DB, replaces pipeline load step)
  Step 3d: Mass UPDATE balance   (psql DML)
  Step 3e: Restore from CSV      [update-ind]  (partition routed)
  Step 4:  Verify results        (psql)

  Database:  postgresql://localhost:5432/appdb
  Records:  10000000 | Threads: 8 | Batch: 5000
  Partition: key=province parts=4 | Backpressure: 0.8 | Lock-aware: true
================================================================================

▶ Validating environment...
✓ Test directory: /Users/dev/Projects/mass-migrator/tests/test_output_simple
✓ Go binary: ./mass-migrator
✓ PostgreSQL connection verified


══════════════════════════════════════════════════════════════
 STEP 0: Create Province-District Map Table 
════════════════════════════════════════════════════════════════

ℹ Dropped existing map table: province_district_map_simple
▶ Creating and populating map table...
CREATE TABLE
INSERT 0 9999
✓ Step 0 Completed! Created 9999 map records
⏱ TPS: Map creation                           9999 records/sec (1s)


══════════════════════════════════════════════════════════════
 STEP 1: Generate CSV (10000000 Records) 
════════════════════════════════════════════════════════════════

▶ Starting CSV generation...
[2026-06-01T10:59:19] File logging enabled: /Users/dev/.mass-migrator/logs/go-mass-migrator-20260601.log

[2026-06-01T10:59:19] [WARN] Binary is unsigned (dev build) — skipping integrity check
[2026-06-01T10:59:19] [WARN] Dev build — enterprise access (time-limited)
# Dev build — enterprise access until 2026-07-31 (61 days remaining)
Generated 10000000 records in 8.406s (1189593 records/sec) -> /Users/dev/Projects/mass-migrator/tests/test_output_simple/test_records.csv [816.64 MB]
=== Summary ===
Mode:       gencsv
Time:       8s
✓ Step 1 Completed! 10000000 records (829M)
⏱ TPS: CSV generation                      1250000 records/sec (8s)


══════════════════════════════════════════════════════════════
 STEP 2: Import CSV → PostgreSQL (test_simple_go) 
════════════════════════════════════════════════════════════════

▶ Starting CSV import...
[2026-06-01T10:59:28] File logging enabled: /Users/dev/.mass-migrator/logs/go-mass-migrator-20260601.log

[2026-06-01T10:59:28] [WARN] Binary is unsigned (dev build) — skipping integrity check
[2026-06-01T10:59:28] [WARN] Dev build — enterprise access (time-limited)
# Dev build — enterprise access until 2026-07-31 (61 days remaining)
[INFO] No --profile specified. Using defaults (batch-size=50000, threads=4, state-mgmt=off).
       Use --profile=dev for testing or --profile=production for large workloads.
2026/06/01 10:59:28 [dialect.limits] applied pool config to "pgx": MaxOpen=20, MaxIdle=5, MaxLifetime=5m0s, MaxIdleTime=2m0s
[INFO] Using parallel CSV reader (8 chunks for 816.6 MB file)
[INFO] Using bulk loader for postgresql (pure insert mode)
Progress: 4990000 records processed, 5s elapsed, 997417 records/sec
[backpressure] channel 81% full, throttling producer for 12.499999ms
[backpressure] channel 100% full, throttling producer for 49.999999ms
Progress: 9460000 records processed, 10s elapsed, 945454 records/sec
Imported 10000000 records into test_simple_go from /Users/dev/Projects/mass-migrator/tests/test_output_simple/test_records.csv
=== Summary ===
Mode:       insert-ind
Source:     /Users/dev/Projects/mass-migrator/tests/test_output_simple/test_records.csv
Time:       12s
Output:     test_simple_go
✓ Step 2 Completed! 10000000 records
  Balance sum: 255000144167.10
⏱ TPS: CSV import                           769230 records/sec (13s)


══════════════════════════════════════════════════════════════
 STEP 3a: Create Clone Table (psql DDL) 
════════════════════════════════════════════════════════════════

CREATE TABLE
✓ Step 3a Completed! Clone table created: clone_simple_go


══════════════════════════════════════════════════════════════
 STEP 3b: Materialize Enrichment via JOIN → Staging Table 
════════════════════════════════════════════════════════════════

SELECT 10000000
✓ Step 3b Completed! Staging table populated: 10000000 rows
✓ All rows enriched (no NULL province_name)
⏱ TPS: JOIN+materialize (psql)              344827 records/sec (29s)


══════════════════════════════════════════════════════════════
 STEP 3c: Copy Staging → Clone via [insert] DB-to-DB mode 
════════════════════════════════════════════════════════════════

▶ Starting DB-to-DB insert...
[2026-06-01T11:00:14] File logging enabled: /Users/dev/.mass-migrator/logs/go-mass-migrator-20260601.log

[2026-06-01T11:00:14] [WARN] Binary is unsigned (dev build) — skipping integrity check
[2026-06-01T11:00:14] [WARN] Dev build — enterprise access (time-limited)
# Dev build — enterprise access until 2026-07-31 (61 days remaining)
[INFO] No --profile specified. Using defaults (batch-size=50000, threads=4, state-mgmt=off).
       Use --profile=dev for testing or --profile=production for large workloads.
2026/06/01 11:00:14 [dialect.limits] applied pool config to "pgx": MaxOpen=20, MaxIdle=5, MaxLifetime=5m0s, MaxIdleTime=2m0s
2026/06/01 11:00:14 [dialect.limits] applied pool config to "pgx": MaxOpen=20, MaxIdle=5, MaxLifetime=5m0s, MaxIdleTime=2m0s
[INFO] Using bulk loader for postgresql (pure insert mode)
Progress: 1175000 records processed, 5s elapsed, 234452 records/sec
Progress: 2200000 records processed, 11s elapsed, 199990 records/sec
Progress: 2810000 records processed, 16s elapsed, 175384 records/sec
Progress: 3640000 records processed, 21s elapsed, 172996 records/sec
Progress: 4380000 records processed, 26s elapsed, 168108 records/sec
Progress: 5500000 records processed, 31s elapsed, 177047 records/sec
Progress: 7055000 records processed, 36s elapsed, 195585 records/sec
Progress: 8300000 records processed, 41s elapsed, 202051 records/sec
Progress: 9665000 records processed, 46s elapsed, 209695 records/sec
Progress: 10000000 records processed, 47s elapsed, 212005 records/sec
=== Summary ===
Mode:       insert
Source:     jdbc:postgresql://localhost:5432/appdb
Time:       47s
Output:     clone_simple_go
✓ Step 3c Completed! 10000000 records in clone
  Balance sum (pre-mass-update): 255000144167.10
⏱ TPS: insert (DB-to-DB)                    212765 records/sec (47s)


══════════════════════════════════════════════════════════════
 STEP 3d: Mass UPDATE balance = 999999 (psql DML) 
════════════════════════════════════════════════════════════════

UPDATE 10000000
✓ Step 3d Completed! All balances set to 999999
  Balance sum (post-mass-update): 9999990000000.00
  Expected:                       9999990000000
⏱ TPS: Mass UPDATE (psql)                   114942 records/sec (87s)


══════════════════════════════════════════════════════════════
 STEP 3e: Restore Balances from CSV via [update-ind] 
════════════════════════════════════════════════════════════════

ℹ Rows at mass-update value before restore: 10000000
▶ Starting update-ind (partition-routed CSV → DB update)...
[2026-06-01T11:02:32] File logging enabled: /Users/dev/.mass-migrator/logs/go-mass-migrator-20260601.log

[2026-06-01T11:02:32] [WARN] Binary is unsigned (dev build) — skipping integrity check
[2026-06-01T11:02:32] [WARN] Dev build — enterprise access (time-limited)
# Dev build — enterprise access until 2026-07-31 (61 days remaining)
[INFO] No --profile specified. Using defaults (batch-size=50000, threads=4, state-mgmt=off).
       Use --profile=dev for testing or --profile=production for large workloads.
2026/06/01 11:02:32 [dialect.limits] applied pool config to "pgx": MaxOpen=20, MaxIdle=5, MaxLifetime=5m0s, MaxIdleTime=2m0s
[INFO] Using parallel CSV reader (8 chunks for 816.6 MB file)
[INFO] Hash-partition routing enabled: 8 partitions by [id]
[2026-06-01T11:02:35] UpdateStrategy: using batched UPDATE fast path on postgresql.clone_simple_go (8 column types)
[2026-06-01T11:02:35] UpdateStrategy: using batched UPDATE fast path on postgresql.clone_simple_go (8 column types)
[2026-06-01T11:02:35] UpdateStrategy: using batched UPDATE fast path on postgresql.clone_simple_go (8 column types)
[2026-06-01T11:02:35] UpdateStrategy: using batched UPDATE fast path on postgresql.clone_simple_go (8 column types)
[2026-06-01T11:02:35] UpdateStrategy: using batched UPDATE fast path on postgresql.clone_simple_go (8 column types)
[2026-06-01T11:02:35] UpdateStrategy: using batched UPDATE fast path on postgresql.clone_simple_go (8 column types)
[backpressure] channel 100% full, throttling producer for 49.999999ms
[2026-06-01T11:02:35] UpdateStrategy: using batched UPDATE fast path on postgresql.clone_simple_go (8 column types)
[2026-06-01T11:02:35] UpdateStrategy: using batched UPDATE fast path on postgresql.clone_simple_go (8 column types)
[backpressure] channel 97% full, throttling producer for 43.749999ms
[backpressure] channel 81% full, throttling producer for 12.499999ms
Progress: 560000 records processed, 5s elapsed, 111595 records/sec
[backpressure] channel 84% full, throttling producer for 18.749999ms
[backpressure] channel 100% full, throttling producer for 49.999999ms
[backpressure] channel 84% full, throttling producer for 18.749999ms
[backpressure] channel 84% full, throttling producer for 18.749999ms
[backpressure] channel 84% full, throttling producer for 18.749999ms
Progress: 2290000 records processed, 10s elapsed, 228580 records/sec
[backpressure] channel 81% full, throttling producer for 12.499999ms
[backpressure] channel 100% full, throttling producer for 49.999999ms
[backpressure] channel 84% full, throttling producer for 18.749999ms
[backpressure] channel 84% full, throttling producer for 18.749999ms
[backpressure] channel 84% full, throttling producer for 18.749999ms
Progress: 3940000 records processed, 15s elapsed, 261886 records/sec
[backpressure] channel 100% full, throttling producer for 49.999999ms
[backpressure] channel 84% full, throttling producer for 18.749999ms
[backpressure] channel 100% full, throttling producer for 49.999999ms
[backpressure] channel 100% full, throttling producer for 49.999999ms
[backpressure] channel 100% full, throttling producer for 49.999999ms
Progress: 5670000 records processed, 20s elapsed, 282321 records/sec
[backpressure] channel 100% full, throttling producer for 49.999999ms
[backpressure] channel 84% full, throttling producer for 18.749999ms
[backpressure] channel 84% full, throttling producer for 18.749999ms
[backpressure] channel 84% full, throttling producer for 18.749999ms
Progress: 7400000 records processed, 25s elapsed, 294798 records/sec
[backpressure] channel 84% full, throttling producer for 18.749999ms
[backpressure] channel 84% full, throttling producer for 18.749999ms
[backpressure] channel 100% full, throttling producer for 49.999999ms
[backpressure] channel 100% full, throttling producer for 49.999999ms
[backpressure] channel 84% full, throttling producer for 18.749999ms
Progress: 9310000 records processed, 30s elapsed, 309271 records/sec
[backpressure] channel 84% full, throttling producer for 18.749999ms
[backpressure] channel 100% full, throttling producer for 49.999999ms
Imported 10000000 records into clone_simple_go from /Users/dev/Projects/mass-migrator/tests/test_output_simple/test_records.csv
=== Summary ===
Mode:       update-ind
Source:     /Users/dev/Projects/mass-migrator/tests/test_output_simple/test_records.csv
Time:       34s
Output:     clone_simple_go
✓ update-ind restored all balances (none still at mass-update value)
  Balance sum (after restore): 255000144167.10
⏱ TPS: update-ind (partitioned)             285714 records/sec (35s)


══════════════════════════════════════════════════════════════
 STEP 4: Verify Results 
════════════════════════════════════════════════════════════════

Record Count Verification:
  CSV generated:     10000000
  Import table:      10000000
  Staging table:     10000000
  Clone table:       10000000
✓ Import count matches CSV (10000000)
✓ Staging count matches import (10000000)
✓ Clone count matches staging (10000000)

Balance Sum Verification:
  Original (import):    255000144167.10
  Pre-mass-update:      255000144167.10
  Post-mass-update:     9999990000000.00 (expected 9999990000000)
  After restore:        255000144167.10
✓ Pre-mass-update clone sum matches import (enrichment preserved balance)
✓ Restored balance sums match original

Enrichment Verification:
  NULL province_name: 0
  NULL district_name: 0
✓ All province_names populated
✓ All district_names populated

Province Distribution Verification:
✓ Province distribution: 99 distinct provinces (>= expected 95 for N=10000000)

Sample Data (first 5 rows from clone table):
1|45|prov_70|4129|dist_4129|27109.77
2|34|prov_16|1204|dist_1204|14127.82
3|67|prov_9|5355|dist_5355|21744.44
4|46|prov_49|3712|dist_3712|27166.95
5|43|prov_51|5595|dist_5595|19991.47

Cleanup Commands:
  PGPASSWORD=Tct#$123 psql -h localhost -p 5432 -U appuser -d appdb -c "DROP TABLE IF EXISTS province_district_map_simple, test_simple_go, enriched_staging_simple, clone_simple_go CASCADE"
  rm -rf /Users/dev/Projects/mass-migrator/tests/test_output_simple


================================================================================
✓ Simple-mode equivalent completed at Mon Jun  1 11:03:13 +07 2026
================================================================================

Performance Metrics (TPS):
⏱ TPS: Map creation                           9999 records/sec (1s)
⏱ TPS: CSV generation                      1250000 records/sec (8s)
⏱ TPS: CSV import [csv2db]                  769230 records/sec (13s)
⏱ TPS: JOIN+materialize (psql)              344827 records/sec (29s)
⏱ TPS: insert (DB-to-DB)                    212765 records/sec (47s)
⏱ TPS: Mass UPDATE (psql)                   114942 records/sec (87s)
⏱ TPS: update-ind (partitioned)             285714 records/sec (35s)

Total Duration:       3m 55s

  \033[0;32mPASS: 21\033[0m  \033[0;31mFAIL: 0\033[0m

Modes Used (no pipeline mode):
  gencsv                   — Step 1 (test data generation)
  csv2db                   — Step 2 (CSV → import_table)
  insert  (DB-to-DB)       — Step 3c (staging → clone, replaces pipeline load step)
  update-ind               — Step 3e (CSV → clone with key matching + partition routing)
  + psql for DDL (CREATE TABLE), the enrichment JOIN, and the mass UPDATE — these are
    not mode-able operations in mass-migrator regardless of whether pipeline is used.

Pipeline → Simple-Mode Mapping:
  Pipeline shared_datasets + set_op lookup  →  psql CREATE TABLE AS SELECT ... JOIN
  Pipeline load step (insert strategy)      →  insert subcommand (DB-to-DB)
  Pipeline sql step (UPDATE)                →  psql UPDATE
  Pipeline sql step with key_columns        →  update-ind (CSV-driven)
  Pipeline DAG dependencies                 →  shell script execution order
  Pipeline staged partitioning              →  partition routing via MM_NUM_PARTITIONS

================================================================================

