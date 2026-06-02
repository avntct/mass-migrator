# Mass Migrator v3 -- Pipeline Step Types: 5W1H Reference Guide

> **Version**: v3 (Go rewrite)
> **Date**: 2026-03-25
> **Total step types**: 22 (sql, query, load, transform, filter, project, sort, dedup, aggregate, window, sample, pivot, split, setop, validate, check, vars, read, write, kafka\_push, kafka\_pull, distributed\_join)

---

## Table of Contents

1. [sql](#step-sql)
2. [query](#step-query)
3. [load](#step-load)
4. [transform](#step-transform)
5. [filter](#step-filter)
6. [project](#step-project)
7. [sort](#step-sort)
8. [dedup](#step-dedup)
9. [aggregate](#step-aggregate)
10. [window](#step-window)
11. [sample](#step-sample)
12. [pivot](#step-pivot)
13. [split](#step-split)
14. [setop](#step-setop)
15. [validate](#step-validate)
16. [check](#step-check)
17. [vars](#step-vars)
18. [read](#step-read)
19. [write](#step-write)
20. [kafka\_push](#step-kafka_push)
21. [kafka\_pull](#step-kafka_pull)
22. [distributed\_join](#step-distributed_join)

---

## Step: `sql`

**What**: Executes arbitrary SQL statements (DDL or DML) against a named database connection. Supports a single statement or a list of statements executed sequentially. Does not produce a dataset.

**Why**: Used for side-effecting database operations: creating/dropping tables, truncating data, running INSERT/UPDATE/DELETE, creating indexes, or any other DDL/DML that must occur before or after data movement. This is the "do something to the database" step.

**How**:
1. Resolves the database connection from `ExecutionContext.DBPools` by name.
2. Iterates through the SQL statement list (single string is normalized to a 1-element list).
3. For each statement, interpolates `${variable}` placeholders from pipeline variables.
4. Executes via `db.ExecContext` (no result set expected).
5. Stops on first error, reporting which statement number failed.

**Where**: `internal/pipeline/executor_sql.go`

**When**: Typically placed at the beginning of a pipeline to set up target tables (CREATE TABLE, TRUNCATE) or at the end for cleanup (DROP TEMP TABLE, ANALYZE). Also used mid-pipeline for DDL that must precede a `load` step.

**Who**: Pipeline authors who need to execute DDL/DML as part of a migration workflow.

**YAML Fields**:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Unique step identifier |
| `type` | string | Yes | Must be `sql` |
| `depends_on` | []string | No | Step IDs that must complete first |
| `database` | string | Yes | Database name from `databases:` section |
| `sql` | string or []string | Yes | One or more SQL statements to execute |

**Example**:
```yaml
- id: setup_target
  type: sql
  database: target_db
  sql:
    - |
      CREATE TABLE IF NOT EXISTS orders_staging (
        id INT PRIMARY KEY,
        customer VARCHAR(100),
        amount DECIMAL(10,2)
      )
    - TRUNCATE TABLE orders_staging
```

**Execution Flow**:
```
sql list -> for each stmt: interpolate ${vars} -> db.ExecContext -> next stmt
```

**Dependencies**: Often depends on `vars` steps (for variable values). `query`, `load`, and `check` steps commonly depend on `sql` steps.

**Output**: None. This step is side-effecting only (`IsSideEffecting() = true`). On pipeline resume, completed `sql` steps are skipped entirely.

**Edge Cases / Gotchas**:
- Statements execute sequentially within the step -- there is no parallelism.
- If statement 3 of 5 fails, statements 4 and 5 are never executed. There is no rollback of statements 1 and 2.
- The `sql` field accepts both a single string and a YAML list. Use a list for multi-statement steps.
- Variable interpolation uses raw string replacement (`${var}` -> value), not parameterized queries. Do not interpolate untrusted user input.

---

## Step: `query`

**What**: Executes a SQL SELECT against a database and registers the result as a named in-memory columnar dataset. Supports partitioned queries, watermark-based incremental sync, dataset filter pushdown, and range filters.

**Why**: The primary way to bring data from a database into the pipeline's dataset registry. The most feature-rich step type, supporting bounded-memory processing of billions of rows via partitioning, incremental extraction via watermarks, and cross-database join preparation via dataset filter pushdown.

**How**:
1. Gets DB connection from `ExecutionContext.DBPools`.
2. Interpolates `${variable}` placeholders in SQL.
3. Resolves watermark configuration and injects filter clause into SQL (if configured).
4. Applies dataset filter pushdown: replaces `${dataset_filter}` / `${name}` placeholders with IN/NOT IN clauses built from source datasets.
5. If partitioned: queries distinct partition keys, pushes to a queue, N worker goroutines each fetch a key and execute the partition query. Can stream directly to a downstream `write` step for bounded memory.
6. If not partitioned: executes query via `db.QueryContext`, scans rows into columnar format (`[][]interface{}`).
7. Normalizes database driver types (e.g., `[]byte` to string/int/float).
8. Updates watermark tracker with high-water values from result.
9. Registers result dataset in `ExecutionContext.Registry`.

**Where**: `internal/pipeline/executor_query.go`, `internal/pipeline/executor_dataset_filter.go`

**When**: First step in most pipelines -- loads source data before transforms, filters, or loads. For incremental pipelines, runs on each scheduled invocation with watermark tracking.

**Who**: Pipeline authors who need to read from databases.

**YAML Fields**:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Unique step identifier |
| `type` | string | Yes | Must be `query` |
| `depends_on` | []string | No | Step IDs that must complete first |
| `database` | string | Yes | Database name from `databases:` section |
| `sql` | string | Yes | SELECT query (supports `${variable}` interpolation) |
| `output` | string | Yes | Dataset name to register result as |
| `partition_by` | string | No | Single column to partition by |
| `partition_by_columns` | []string | No | Composite columns to partition by (overrides `partition_by`) |
| `partition_source_table` | string | No | Table containing distinct partition values |
| `partition_source_column` | string | No | Column in source table with partition values |
| `partition_source_columns` | []string | No | Composite columns in source table |
| `streaming` | bool | No | Process each partition through full downstream chain (bounded memory) |
| `threads` | int | No | Parallel workers for partitioned queries (default 4) |
| `watermark` | object | No | Full watermark config (columns, mode, overlap_strategy, overlap_size) |
| `watermark_column` | string | No | Shorthand: single watermark column name |
| `watermark_type` | string | No | Shorthand: column type (string, int, timestamp, etc.) |
| `dataset_filter` | object | No | Single dataset filter pushdown config |
| `dataset_filters` | map[string]object | No | Named dataset filters (placeholder = key name) |
| `range_filter` | object | No | Range-based filter from source dataset (MIN/MAX -> BETWEEN) |

**Example**:
```yaml
- id: load_orders
  type: query
  database: source_db
  sql: |
    SELECT id, customer, amount, region
    FROM orders
    WHERE created_at > '2026-01-01'
      AND ${dataset_filter}
  output: orders_data
  partition_by: region
  partition_source_table: regions
  threads: 8
  watermark:
    columns:
      - name: created_at
        type: timestamp
    mode: incremental
  dataset_filter:
    source: valid_customers
    columns: [customer_id]
    mode: in
    chunk_size: 500
```

**Execution Flow**:
```
sql string -> interpolate ${vars} -> inject watermark filter ->
  inject dataset filters ->
  [partitioned?] get partition keys -> queue -> N workers: query + scan ->
  [standard?] db.QueryContext -> scan rows ->
  normalize values -> columnar dataset -> registry.Register(name, dataset)
```

**Dependencies**: Can depend on `sql` steps (for table setup), `vars` steps (for variable values), or `query` steps (for dataset filter source data).

**Output**: Registers a named columnar dataset (`OutputDataset() = output`).

**Edge Cases / Gotchas**:
- Partitioned queries validate column names against a regex to prevent SQL injection.
- When `streaming: true` with a downstream `write` step, each partition is queried, transformed (through dependent steps), and written to file independently. Only one partition's data is in memory at a time.
- Composite partition keys (`partition_by_columns`) take priority over `partition_by`.
- `dataset_filter.chunk_size` defaults to 1000 values per IN-list clause. PostgreSQL has a 65535 bind parameter limit; the executor caps at 60000 for safety.
- Watermark `${watermark_filter}` placeholder is replaced with the filter clause. If absent, the filter is appended as WHERE/AND before any trailing ORDER BY/GROUP BY.
- Empty partition key results cause an error, not an empty dataset.

---

## Step: `load`

**What**: Writes an in-memory dataset to a database table using parallel goroutines and configurable write strategies (insert, update, upsert, merge).

**Why**: The primary way to move data from the pipeline into a target database. Supports high-throughput parallel loading with strategy pattern for different write semantics.

**How**:
1. Resolves DB connection and dialect for the target database.
2. Retrieves the input dataset from the registry.
3. Validates static columns/values counts match if configured.
4. Resolves pipeline variable placeholders in static values.
5. Determines columns (explicit or from dataset schema).
6. Splits rows evenly across N worker goroutines.
7. Each worker: creates a strategy instance, opens a transaction, processes rows in batch-sized chunks.
8. Converts columnar rows to `Record` objects (from pool), applies static columns.
9. Calls `strategy.ExecuteBatch(ctx, tx, batch)` for each batch within the transaction.
10. Commits transaction on completion. Returns pooled records.

**Where**: `internal/pipeline/executor_load.go`

**When**: After data has been queried, transformed, filtered, and validated. Usually one of the last steps in a pipeline.

**Who**: Pipeline authors who need to write data to a target database.

**YAML Fields**:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Unique step identifier |
| `type` | string | Yes | Must be `load` |
| `depends_on` | []string | No | Step IDs that must complete first |
| `database` | string | Yes | Target database name from `databases:` section |
| `dataset` | string | Yes | Input dataset name (YAML field: `dataset`) |
| `target_table` | string | Yes | Target table name |
| `strategy` | string | No | Write strategy: `insert` (default), `update`, `upsert`, `merge` |
| `key_columns` | []string | Conditional | Required for update/upsert/merge strategies |
| `columns` | []string | No | Columns to write (defaults to dataset columns) |
| `batch_size` | int | No | Rows per batch (default 5000) |
| `threads` | int | No | Parallel writer goroutines (default 4) |
| `static_columns` | []string | No | Constant column names not in dataset |
| `static_values` | []string | No | Constant values for static columns (supports `${var}` interpolation) |

**Example**:
```yaml
- id: write_orders
  type: load
  depends_on: [transform_orders]
  database: target_db
  dataset: transformed_orders
  target_table: orders
  strategy: upsert
  key_columns: [id]
  batch_size: 10000
  threads: 8
  static_columns: [load_timestamp]
  static_values: ["${run_timestamp}"]
```

**Execution Flow**:
```
dataset -> validate -> split rows across N workers ->
  each worker: new strategy -> begin TX ->
    for each batch: rows -> Records -> strategy.ExecuteBatch(tx, batch) ->
  commit TX
```

**Dependencies**: Depends on steps that produce its input dataset (query, transform, filter, etc.) and optionally on `sql` steps that create the target table.

**Output**: None (side-effecting). On resume, completed `load` steps are skipped.

**Edge Cases / Gotchas**:
- Empty datasets are silently skipped with an INFO log.
- If `threads > totalRows`, threads is capped at 1.
- Each worker gets its own strategy instance and transaction. A single worker failure does not roll back other workers' committed transactions.
- For `upsert`/`merge`, key columns are excluded from the UPDATE SET clause.
- `static_columns` and `static_values` must have matching counts; mismatch causes an error.
- Record objects are pooled (`record.AcquireRecord` / `record.ReleaseRecord`) to reduce GC pressure.

---

## Step: `transform`

**What**: Applies a JavaScript transform to every record in a dataset using the goja JS engine. Supports four modes: one-to-one, one-to-many, many-to-one, and many-to-many.

**Why**: Enables arbitrary data transformation logic -- column renaming, type conversion, value computation, data enrichment, splitting/merging records -- using a sandboxed scripting engine with 100+ built-in helpers.

**How**:
1. Retrieves input dataset from registry.
2. Creates a `TransformEngine` with the JS script and specified mode, with 30s timeout.
3. Based on mode:
   - **one\_to\_one**: Transforms first row to infer output schema. Then transforms remaining rows, optionally in parallel across N worker goroutines.
   - **one\_to\_many**: Converts all rows to records, calls `TransformBatch` which returns multiple output records per input.
   - **many\_to\_one / many\_to\_many**: Partitions rows by `group_by` columns, then calls `TransformBatch` per group.
4. Builds output columnar dataset from transformed records.
5. Registers result in registry.

**Where**: `internal/pipeline/executor_transform.go`

**When**: After query steps and before load steps. The core data transformation step in any pipeline.

**Who**: Pipeline authors who need to transform, compute, or reshape data.

**YAML Fields**:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Unique step identifier |
| `type` | string | Yes | Must be `transform` |
| `depends_on` | []string | No | Step IDs that must complete first |
| `input` | string | Yes | Input dataset name |
| `output` | string | Yes | Output dataset name |
| `script` | string | Yes | JavaScript transform script |
| `threads` | int | No | Parallel workers for one\_to\_one mode (default 1) |
| `mode` | string | No | `one_to_one` (default), `one_to_many`, `many_to_one`, `many_to_many` |
| `group_by` | []string | No | Partition key columns for many\_to\_one / many\_to\_many modes |

**Example**:
```yaml
- id: enrich_orders
  type: transform
  input: orders_data
  output: enriched_orders
  threads: 4
  script: |
    record.total = record.amount * record.quantity;
    record.region_upper = record.region.toUpperCase();
    delete record.internal_code;
```

**Execution Flow**:
```
input dataset -> create JS engine ->
  [one_to_one] transform row 0 (infer schema) -> parallel transform rows 1..N ->
  [one_to_many] batch transform all rows -> expand to multiple outputs ->
  [many_to_one/many] partition by group_by -> batch transform per group ->
  columnar dataset -> registry.Register(output)
```

**Dependencies**: Depends on steps that produce its input dataset.

**Output**: Registers a named dataset (`OutputDataset() = output`).

**Edge Cases / Gotchas**:
- For `one_to_one` mode, parallelism only kicks in when there are >= 1000 rows AND threads > 1. Below that threshold, single-threaded execution is used.
- Output schema is inferred from the first transformed row. All subsequent rows must produce the same column set.
- Each parallel worker gets its own `TransformContext` to avoid shared state.
- Empty input datasets register an empty output dataset (no error).
- The JS engine runs in a sandbox with `eval()` and `Function` constructor blocked. Default timeout is 30 seconds per engine.
- 100+ built-in helper functions are available (string, datetime, masking, validation, JSON/XML, window).

---

## Step: `filter`

**What**: Filters records from a dataset based on a JavaScript boolean expression. Records where the expression evaluates to true (or any truthy value) are kept; others are discarded.

**Why**: Enables row-level filtering using arbitrary JS logic, including complex conditions, regex matching, and multi-column predicates. Simpler than a full transform when you only need to remove rows.

**How**:
1. Retrieves input dataset from registry.
2. Wraps the expression in a `with(record) { return { pass: (expr) }; }` scope so column names can be referenced directly.
3. Creates a sandboxed TransformEngine with the wrapped expression (5s timeout).
4. Iterates over all rows. For each row, converts to a record, evaluates the expression.
5. If `pass` is truthy (not nil and not false), the row is kept.
6. Registers output as a `ViewDataset` (shared row references, no copy).

**Where**: `internal/pipeline/executor_filter.go`

**When**: After query/transform steps to remove unwanted rows before loading or further processing.

**Who**: Pipeline authors who need conditional row filtering.

**YAML Fields**:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Unique step identifier |
| `type` | string | Yes | Must be `filter` |
| `depends_on` | []string | No | Step IDs that must complete first |
| `input` | string | Yes | Input dataset name |
| `output` | string | Yes | Output dataset name |
| `expression` | string | Yes | JavaScript boolean expression (column names accessible directly) |

**Example**:
```yaml
- id: filter_active
  type: filter
  input: customers
  output: active_customers
  expression: "status === 'ACTIVE' && balance > 0"
```

**Execution Flow**:
```
input dataset -> wrap expression in with(record) scope -> create JS engine ->
  for each row: evaluate expression ->
    truthy? keep row : discard ->
  ViewDataset (shared row refs) -> registry.Register(output)
```

**Dependencies**: Depends on steps that produce its input dataset.

**Output**: Registers a named dataset (`OutputDataset() = output`).

**Edge Cases / Gotchas**:
- Uses `ViewDataset` -- output rows are shared references to input rows, not copies. Mutating a row in the output will affect the input dataset.
- The expression is wrapped with `with(record)` so you write `amount > 100` not `record.amount > 100`.
- The JS engine has a 5-second timeout per evaluation (generous for a boolean check).
- Pre-allocates output at half input size (`len(rows)/2`) as a heuristic.

---

## Step: `project`

**What**: Selects a subset of columns from a dataset and optionally renames them. The columnar equivalent of SQL `SELECT col1, col2 AS alias`.

**Why**: Reduces dataset width by dropping unnecessary columns before a load step, or renames columns to match target schema conventions. No JS engine overhead -- pure index-based column selection.

**How**:
1. Retrieves input dataset from registry.
2. For each column in the `columns` list, checks the `rename` map for an alias.
3. Resolves source column indices from the input dataset's `ColIdx` map.
4. Builds output rows by copying only the selected column values at the resolved indices.
5. Registers result as a new columnar dataset.

**Where**: `internal/pipeline/executor_project.go`

**When**: Before a `load` step to match target table schema, or mid-pipeline to reduce memory footprint.

**Who**: Pipeline authors who need to select or rename columns.

**YAML Fields**:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Unique step identifier |
| `type` | string | Yes | Must be `project` |
| `depends_on` | []string | No | Step IDs that must complete first |
| `input` | string | Yes | Input dataset name |
| `output` | string | Yes | Output dataset name |
| `columns` | []string | Yes | Columns to keep (order determines output column order) |
| `rename` | map[string]string | No | Column rename map: `{original: alias}` |

**Example**:
```yaml
- id: select_columns
  type: project
  input: raw_orders
  output: projected_orders
  columns: [order_id, customer_name, total_amount, region]
  rename:
    order_id: id
    customer_name: customer
```

**Execution Flow**:
```
input dataset -> resolve column indices -> for each row: copy selected values ->
  new columnar dataset -> registry.Register(output)
```

**Dependencies**: Depends on steps that produce its input dataset.

**Output**: Registers a named dataset (`OutputDataset() = output`).

**Edge Cases / Gotchas**:
- If a column in `columns` does not exist in the input dataset, that column's values will be nil in the output (source index is -1).
- This is a full copy of selected column values, not a view. Each output row is a new slice.
- Column order in the output matches the order of the `columns` list, not the input dataset order.

---

## Step: `sort`

**What**: Sorts a dataset by one or more columns with configurable direction (ascending/descending) and an optional row limit (top-N).

**Why**: Provides deterministic ordering for downstream steps (dedup, window functions) or limits output to top-N rows. Uses stable sort to preserve relative order of equal elements.

**How**:
1. Retrieves input dataset from registry.
2. Builds sort specifications from `order_by` list, resolving column indices.
3. Creates an index array and sorts indices using `sort.SliceStable` with a multi-column comparator.
4. Applies `limit` if set (truncates to first N sorted indices).
5. Builds output rows from sorted indices.
6. Registers result as a `ViewDataset` (shared row references).

**Where**: `internal/pipeline/executor_sort.go`

**When**: Before `dedup` steps (to control which duplicate to keep), before `window` steps, or as a final step for ordered output.

**Who**: Pipeline authors who need sorted output.

**YAML Fields**:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Unique step identifier |
| `type` | string | Yes | Must be `sort` |
| `depends_on` | []string | No | Step IDs that must complete first |
| `input` | string | Yes | Input dataset name |
| `output` | string | Yes | Output dataset name |
| `order_by` | []object | Yes | Sort columns (each has `column`, `ascending`, `nulls`) |
| `limit` | int | No | Return only the first N rows after sorting |

Each `order_by` element:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `column` | string | Yes | Column name to sort by |
| `ascending` | bool | No | true = ASC (default), false = DESC |
| `nulls` | string | No | `FIRST` or `LAST` (null ordering) |

**Example**:
```yaml
- id: top_customers
  type: sort
  input: customers
  output: top_10_customers
  order_by:
    - column: total_spend
      ascending: false
    - column: name
      ascending: true
  limit: 10
```

**Execution Flow**:
```
input dataset -> build sort specs -> create index array ->
  sort.SliceStable(indices, multi-column comparator) ->
  apply limit -> build output rows from sorted indices ->
  ViewDataset -> registry.Register(output)
```

**Dependencies**: Depends on steps that produce its input dataset.

**Output**: Registers a named dataset (`OutputDataset() = output`).

**Edge Cases / Gotchas**:
- Uses `ViewDataset` -- rows are shared references.
- Sort is index-based (sorts an integer array, not the rows themselves) to avoid copying large row slices.
- Cross-type numeric comparison is supported (int vs float64 vs int64 all compare correctly).
- If a sort column does not exist in the dataset, it is silently ignored (index = -1).
- `nulls` field is defined in the struct but null ordering is handled by `compareValues` which puts nil before non-nil.

---

## Step: `dedup`

**What**: Removes duplicate records from a dataset based on key columns, keeping either the first or last occurrence. Supports optional pre-sort ordering.

**Why**: Essential for data quality -- removes duplicates before loading to prevent primary key violations or ensures only the most recent version of each record is kept.

**How**:
1. Retrieves input dataset from registry.
2. Resolves key column indices.
3. If `order_by` is set, sorts row indices by the specified column and direction.
4. Iterates through (optionally sorted) indices, building a composite key from key column values.
5. For `FIRST` keep: stores only the first occurrence of each key. For `LAST`: overwrites with each occurrence (last wins).
6. Collects unique row indices, sorts them back to original order.
7. Registers result as a `ViewDataset`.

**Where**: `internal/pipeline/executor_dedup.go`

**When**: After query steps to remove database-level duplicates, or after union/merge operations.

**Who**: Pipeline authors who need unique records by key.

**YAML Fields**:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Unique step identifier |
| `type` | string | Yes | Must be `dedup` |
| `depends_on` | []string | No | Step IDs that must complete first |
| `input` | string | Yes | Input dataset name |
| `output` | string | Yes | Output dataset name |
| `key_columns` | []string | Yes | Columns that define uniqueness |
| `keep` | string | No | `FIRST` (default) or `LAST` -- which duplicate to keep |
| `order_by` | string | No | Column to sort by before dedup |
| `order_dir` | string | No | `ASC` (default) or `DESC` |

**Example**:
```yaml
- id: dedup_orders
  type: dedup
  input: raw_orders
  output: unique_orders
  key_columns: [order_id]
  keep: LAST
  order_by: updated_at
  order_dir: DESC
```

**Execution Flow**:
```
input dataset -> resolve key column indices ->
  [if order_by set] sort indices by order column ->
  iterate indices: build composite key -> seen map (FIRST/LAST logic) ->
  collect unique indices -> sort by original order ->
  ViewDataset -> registry.Register(output)
```

**Dependencies**: Depends on steps that produce its input dataset.

**Output**: Registers a named dataset (`OutputDataset() = output`).

**Edge Cases / Gotchas**:
- The composite key is built by joining column values with `\x00` null-byte separator. If values contain null bytes, collisions are theoretically possible.
- After dedup, unique rows are re-sorted by their original index to preserve input order (not the dedup/order\_by order).
- Uses `ViewDataset` -- rows are shared references.
- If `order_by` column does not exist, the sort is silently skipped (index = -1).

---

## Step: `aggregate`

**What**: Groups records by key columns and computes aggregate functions (COUNT, SUM, AVG, MIN, MAX). Supports three execution paths: columnar in-memory, partitioned parallel, and SQL pushdown.

**Why**: Provides GROUP BY semantics within the pipeline. Essential for summary reporting, data validation counts, and pre-aggregation before loading.

**How**:
1. Retrieves input dataset from registry.
2. **If `threads > 0`**: Uses partitioned parallel aggregation.
   - Checks if the input dataset came from a `query` step -- if so, pushes aggregation down to the database as a SQL GROUP BY subquery (optimal path).
   - Otherwise: splits rows across N workers, each computes partial aggregates per group key. For AVG, emits `_sum` and `_count` for correct weighted merge. Main thread merges partial results.
3. **If columnar data available**: Uses fast columnar aggregation with pre-resolved column indices.
4. **Fallback**: Map-based aggregation for record-oriented datasets.

**Where**: `internal/pipeline/executor_aggregate.go`

**When**: After query/transform steps for summary data, or for validation counts.

**Who**: Pipeline authors who need grouped aggregations.

**YAML Fields**:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Unique step identifier |
| `type` | string | Yes | Must be `aggregate` |
| `depends_on` | []string | No | Step IDs that must complete first |
| `input` | string | Yes | Input dataset name |
| `output` | string | Yes | Output dataset name |
| `group_by` | []string | Yes | Columns to group by |
| `aggregations` | []object | Yes | Aggregation operations |
| `threads` | int | No | Parallel workers (enables partitioned aggregation; default 8 when set) |

Each aggregation:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `column` | string | Yes | Column to aggregate |
| `function` | string | Yes | `COUNT`, `SUM`, `AVG`, `MIN`, `MAX` |
| `alias` | string | Yes | Output column name for the result |

**Example**:
```yaml
- id: region_totals
  type: aggregate
  input: orders_data
  output: region_summary
  group_by: [region]
  aggregations:
    - column: amount
      function: SUM
      alias: total_amount
    - column: id
      function: COUNT
      alias: order_count
  threads: 4
```

**Execution Flow**:
```
input dataset ->
  [threads > 0 + source is query step] SQL pushdown: SELECT group_by, AGG() FROM (sql) GROUP BY ->
  [threads > 0] partition rows -> N workers aggregate partials -> merge partial results ->
  [columnar] group by key -> aggregate per group using column indices ->
  [fallback] map-based grouping -> compute aggregates ->
  dataset -> registry.Register(output)
```

**Dependencies**: Depends on steps that produce its input dataset.

**Output**: Registers a named dataset (`OutputDataset() = output`). Output columns: group\_by columns + aggregation aliases.

**Edge Cases / Gotchas**:
- SQL pushdown only works when the source dataset was produced by a `query` step (found by scanning `ectx.Steps`).
- For parallel AVG, partial results carry `_sum` and `_count` fields which are merged correctly. A naive average-of-averages would be incorrect.
- Aggregate function names are validated against a whitelist before SQL pushdown to prevent SQL injection.
- Column identifiers are escaped via the dialect's `EscapeIdentifier` in the pushdown path.
- Group order in output is non-deterministic (Go map iteration order).

---

## Step: `window`

**What**: Applies a window function over a dataset, partitioned by specified columns and ordered within each partition. Supports `rowNumber`, `rank`, and `denseRank`.

**Why**: Enables SQL-style window functions without a database. Commonly used for row numbering within groups, ranking, and top-N-per-group selection.

**How**:
1. Retrieves input dataset from registry.
2. Parses `order_by` strings (e.g., `"amount DESC"`) into structured specs.
3. Groups row indices by partition key (from `partition_by` columns).
4. For each partition, sorts row indices by order columns.
5. Applies the window function:
   - **rowNumber**: Sequential 1..N per partition.
   - **rank**: Same rank for ties, gaps after ties (1, 1, 3).
   - **denseRank**: Same rank for ties, no gaps (1, 1, 2).
6. Appends a new column (e.g., `_row_number`) to each output row.
7. Registers result as a new columnar dataset.

**Where**: `internal/pipeline/executor_window.go`

**When**: After query steps for ranking, row numbering within groups, or preparing data for top-N-per-group filtering.

**Who**: Pipeline authors who need window functions.

**YAML Fields**:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Unique step identifier |
| `type` | string | Yes | Must be `window` |
| `depends_on` | []string | No | Step IDs that must complete first |
| `dataset` | string | Yes | Input dataset name |
| `function` | string | Yes | `rowNumber`, `rank`, or `denseRank` |
| `partition_by` | []string | Yes | Columns to partition by |
| `order_by` | []string | Yes | Order specs (e.g., `["amount DESC", "created_at ASC"]`) |
| `output` | string | Yes | Output dataset name |

**Example**:
```yaml
- id: rank_customers
  type: window
  dataset: customers
  function: denseRank
  partition_by: [region]
  order_by: ["total_spend DESC"]
  output: ranked_customers
```

**Execution Flow**:
```
input dataset -> parse order_by specs -> group row indices by partition key ->
  for each partition: sort indices by order columns ->
    apply rowNumber/rank/denseRank ->
  append _row_number/_rank/_dense_rank column ->
  columnar dataset -> registry.Register(output)
```

**Dependencies**: Depends on steps that produce its input dataset.

**Output**: Registers a named dataset. Output columns = input columns + one new column (`_row_number`, `_rank`, or `_dense_rank`).

**Edge Cases / Gotchas**:
- Only `rowNumber`, `rank`, and `denseRank` are supported. `lag` and `lead` are listed in the struct comment but return an "unsupported function" error.
- `order_by` uses space-separated format: `"column_name DESC"`. Case-insensitive direction parsing.
- Partition order is preserved (insertion order of first-seen partition keys).
- Output column name is fixed: `_row_number`, `_rank`, or `_dense_rank`. Cannot be customized.
- Empty datasets register an empty output dataset.

---

## Step: `sample`

**What**: Randomly samples a subset of records from a dataset using Fisher-Yates shuffle. Supports both rate-based sampling (e.g., 1%) and absolute size sampling (e.g., 1000 rows).

**Why**: Useful for testing pipeline logic on a subset of data, creating representative samples for validation, or reducing dataset size for development.

**How**:
1. Retrieves input dataset from registry.
2. Determines sample size: `size` (absolute) takes priority over `rate` (proportional).
3. Creates a random number generator (seeded if `seed` is specified for reproducibility).
4. Uses Fisher-Yates partial shuffle on an index array to select `sampleSize` random indices.
5. Collects sampled rows.
6. Registers result as a new columnar dataset.

**Where**: `internal/pipeline/executor_sample.go`

**When**: During development/testing, or as a pre-processing step for validation on a representative subset.

**Who**: Pipeline authors who need random sampling.

**YAML Fields**:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Unique step identifier |
| `type` | string | Yes | Must be `sample` |
| `depends_on` | []string | No | Step IDs that must complete first |
| `dataset` | string | Yes | Input dataset name |
| `output` | string | Yes | Output dataset name |
| `rate` | float64 | No | Sampling rate 0.0-1.0 (e.g., 0.01 = 1%) |
| `size` | int | No | Absolute sample size (overrides rate if set) |
| `seed` | int64 | No | Random seed for reproducibility (0 = random) |

**Example**:
```yaml
- id: sample_orders
  type: sample
  dataset: all_orders
  output: sample_orders
  rate: 0.05
  seed: 42
```

**Execution Flow**:
```
input dataset -> determine sample size (size > rate) ->
  create RNG (seeded or random) ->
  Fisher-Yates partial shuffle on index array ->
  collect sampled rows -> columnar dataset -> registry.Register(output)
```

**Dependencies**: Depends on steps that produce its input dataset.

**Output**: Registers a named dataset (`OutputDataset() = output`).

**Edge Cases / Gotchas**:
- `size` overrides `rate` when both are set.
- If `rate` produces a sample size < 1, it is clamped to 1.
- If `size > len(rows)`, it is clamped to `len(rows)`.
- Seed of 0 means use current time (non-deterministic). Any non-zero seed produces reproducible results.
- Empty datasets produce an empty output dataset.

---

## Step: `pivot`

**What**: Transforms rows into columns (pivot/crosstab). Groups records by key columns and creates one new column for each distinct value in the pivot column, aggregating the value column.

**Why**: Converts narrow (normalized) data into wide (denormalized) format. Commonly needed for reporting, cross-tabulation, and data presentation.

**How**:
1. Retrieves input dataset from registry.
2. Resolves column indices for `pivot_column`, `value_column`, and `group_by` columns.
3. Discovers all distinct values in the pivot column (preserving first-appearance order).
4. Groups rows by the composite group-by key.
5. For each group, accumulates values per pivot value using a `pivotAggregator`.
6. Builds output columns: group\_by columns + one column per distinct pivot value.
7. Computes aggregation result (SUM, COUNT, AVG, MIN, MAX) for each cell.
8. Registers result as a columnar dataset.

**Where**: `internal/pipeline/executor_pivot.go`

**When**: After query/transform steps when data needs to be pivoted for reporting or denormalized loading.

**Who**: Pipeline authors who need cross-tabulation.

**YAML Fields**:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Unique step identifier |
| `type` | string | Yes | Must be `pivot` |
| `depends_on` | []string | No | Step IDs that must complete first |
| `dataset` | string | Yes | Input dataset name |
| `output` | string | Yes | Output dataset name |
| `group_by` | []string | Yes | Columns to group by (row keys) |
| `pivot_column` | string | Yes | Column whose distinct values become new columns |
| `value_column` | string | Yes | Column containing values for the new columns |
| `aggregate` | string | Yes | Aggregation function: `SUM`, `COUNT`, `AVG`, `MIN`, `MAX` |

**Example**:
```yaml
- id: pivot_sales
  type: pivot
  dataset: sales_data
  output: sales_matrix
  group_by: [region]
  pivot_column: product
  value_column: revenue
  aggregate: SUM
```

Given input `(region, product, revenue)`:
```
East, Widget, 100
East, Gadget, 200
West, Widget, 150
```

Output `(region, Widget, Gadget)`:
```
East, 100, 200
West, 150, nil
```

**Execution Flow**:
```
input dataset -> resolve column indices ->
  discover distinct pivot values (preserve order) ->
  group rows by group_by key ->
  for each group: accumulate values per pivot value ->
  compute aggregation per cell ->
  columnar dataset -> registry.Register(output)
```

**Dependencies**: Depends on steps that produce its input dataset.

**Output**: Registers a named dataset (`OutputDataset() = output`).

**Edge Cases / Gotchas**:
- Pivot column values become column names as-is (string representation via `fmt.Sprintf`). Special characters in values become column names.
- Missing cells (group has no rows for a pivot value) are nil.
- Empty datasets produce an empty output dataset.
- All values are converted to float64 for aggregation via `toFloat64()`.

---

## Step: `split`

**What**: Splits a dataset into multiple named datasets. Supports two modes: column-value split (one dataset per distinct value) and condition-based split (binary true/false split).

**Why**: Routes data to different downstream processing paths based on column values or conditions. Enables conditional branching in pipelines.

**How**:
1. Retrieves input dataset from registry.
2. **Condition mode** (`condition` is set):
   - Parses `output_prefix` as two comma-separated names (match, no-match).
   - Wraps the condition in a JS `with(record)` scope.
   - Evaluates condition for each row. Truthy rows go to the match dataset, others to the no-match dataset.
   - Registers both as `ViewDataset`.
3. **Column-value mode** (no condition):
   - Groups rows by distinct values in `split_column`.
   - For each group, registers a `ViewDataset` named `{output_prefix}{value}`.

**Where**: `internal/pipeline/executor_split.go`

**When**: When different subsets of data need different downstream processing (e.g., high-value vs. regular orders, different region-specific transformations).

**Who**: Pipeline authors who need conditional routing.

**YAML Fields**:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Unique step identifier |
| `type` | string | Yes | Must be `split` |
| `depends_on` | []string | No | Step IDs that must complete first |
| `input` | string | Yes | Input dataset name |
| `split_column` | string | Conditional | Column to split by (required if no condition) |
| `output_prefix` | string | Yes | Prefix for output datasets. In condition mode: comma-separated `"match,no_match"` |
| `condition` | string | No | JS boolean expression for binary split |

**Example (column-value)**:
```yaml
- id: split_by_region
  type: split
  input: orders
  split_column: region
  output_prefix: orders_
  # Creates: orders_East, orders_West, orders_North, etc.
```

**Example (condition)**:
```yaml
- id: split_high_value
  type: split
  input: orders
  condition: "amount > 5000"
  output_prefix: "high_value,regular"
  # Creates: high_value (amount > 5000), regular (amount <= 5000)
```

**Execution Flow**:
```
input dataset ->
  [condition mode] wrap expr -> JS engine -> evaluate per row ->
    truthy -> match dataset, falsy -> no_match dataset ->
  [column mode] group rows by split_column value ->
    for each group: register as {prefix}{value} ->
  ViewDataset(s) -> registry.Register()
```

**Dependencies**: Depends on steps that produce its input dataset.

**Output**: Registers multiple named datasets. Note: `OutputDataset()` returns `""` (since it produces multiple datasets). Downstream steps reference the individual split dataset names.

**Edge Cases / Gotchas**:
- In condition mode, `output_prefix` MUST be comma-separated with exactly 2 names. Anything else is an error.
- Column-value mode output names are `{prefix}{column_value}`. The value is converted to string via `fmt.Sprintf`.
- Uses `ViewDataset` -- all output datasets share row references with the input.
- In condition mode, the JS engine has a 5-second timeout.

---

## Step: `setop`

**What**: Performs set operations between two or more datasets. Supports UNION, INTERSECT, EXCEPT, JOIN, and LOOKUP.

**Why**: Combines datasets from different sources, finds common/different records, or enriches a dataset with columns from a lookup table. LOOKUP is optimized for large reference datasets with cached hash maps.

**How**:
- **LOOKUP**: Builds a hash map on the right dataset (keyed by join columns), then enriches each left row with lookup columns from matching right rows. The hash map is cached in `ExecutionContext.Results` for reuse across streaming partitions.
- **UNION**: Concatenates all input datasets' records.
- **INTERSECT**: Keeps only records that exist in ALL input datasets (by deterministic key).
- **EXCEPT**: Keeps left-side records not found in the right-side dataset.
- **JOIN**: Inner hash join on specified key columns.

**Where**: `internal/pipeline/executor_setop.go`

**When**: After query steps to combine data from multiple sources, or to enrich a dataset with reference data.

**Who**: Pipeline authors who need set operations or lookup joins.

**YAML Fields**:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Unique step identifier |
| `type` | string | Yes | Must be `setop` |
| `depends_on` | []string | No | Step IDs that must complete first |
| `operation` | string | Yes | `UNION`, `INTERSECT`, `EXCEPT`, `JOIN`, or `LOOKUP` |
| `inputs` | []string | Conditional | Dataset names (required for UNION/INTERSECT/EXCEPT/JOIN) |
| `output` | string | Yes | Output dataset name |
| `join_keys` | []string | Conditional | Join key columns (for JOIN operation) |
| `left` | object | Conditional | Left side config for LOOKUP: `{dataset, key}` |
| `right` | object | Conditional | Right side config for LOOKUP: `{dataset, key}` |
| `lookup_columns` | []string | Conditional | Columns to add from right dataset (for LOOKUP) |

**Example (LOOKUP)**:
```yaml
- id: enrich_orders
  type: setop
  operation: LOOKUP
  left:
    dataset: orders
    key: customer_id
  right:
    dataset: customers
    key: id
  lookup_columns: [name, email, tier]
  output: enriched_orders
```

**Example (UNION)**:
```yaml
- id: combine_regions
  type: setop
  operation: UNION
  inputs: [orders_east, orders_west]
  output: all_orders
```

**Execution Flow**:
```
[LOOKUP] build/cache right hash map -> for each left row: O(1) lookup ->
  add lookup columns to left -> register as new dataset
[UNION] concatenate all input records
[INTERSECT] intersect by deterministic key
[EXCEPT] left minus right by deterministic key
[JOIN] build right index -> for each left: find matches -> merge
```

**Dependencies**: Depends on steps that produce all input datasets.

**Output**: Registers a named dataset (`OutputDataset() = output`).

**Edge Cases / Gotchas**:
- LOOKUP modifies the left dataset in-place (adds columns), then registers a new dataset from the modified data. The original left dataset in the registry is unaffected since a new dataset object is registered.
- LOOKUP hash maps are cached on `ectx.Results` with key `"lookup_{right_dataset_name}"`. In streaming mode, this avoids rebuilding an 850MB hash map per partition.
- LOOKUP supports composite keys (multiple key columns, joined with `\x00`).
- UNION/INTERSECT/EXCEPT use map-based record comparison (less efficient than LOOKUP's columnar path).
- For INTERSECT, records are matched by a deterministic key built from all column values (sorted columns, `\x00` separated).
- JOIN requires at least 2 inputs.

---

## Step: `validate`

**What**: Validates dataset records against a set of rules (not\_null, format, range). Can fail the pipeline or filter out invalid rows.

**Why**: Data quality enforcement before loading. Catches null values, format violations, and out-of-range values either as hard failures or soft filters.

**How**:
1. Retrieves input dataset from registry.
2. Resolves rule column indices and parses min/max values.
3. Iterates over all rows, checking each rule:
   - **not\_null**: Fails if value is nil.
   - **format**: Fails if string representation does not contain the pattern.
   - **range**: Fails if numeric value is outside min/max bounds.
4. In **error mode** (default): If `fail_on: any`, fails immediately on first violation. If `fail_on: threshold:N`, fails if violations exceed N.
5. In **filter mode** (`on_fail: filter`): Collects valid rows and registers them as output dataset.

**Where**: `internal/pipeline/executor_validate.go`

**When**: Before load steps as a data quality gate.

**Who**: Pipeline authors who need data validation.

**YAML Fields**:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Unique step identifier |
| `type` | string | Yes | Must be `validate` |
| `depends_on` | []string | No | Step IDs that must complete first |
| `input` | string | Yes | Input dataset name |
| `rules` | []object | Yes | Validation rules |
| `fail_on` | string | Yes | `any` (fail on first violation) or `threshold:N` |
| `on_fail` | string | No | `error` (default, fail pipeline) or `filter` (remove invalid rows) |
| `output` | string | No | Output dataset name (for `on_fail: filter` mode) |

Each rule:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `column` | string | Yes | Column to validate |
| `rule` | string | Yes | `not_null`, `format`, `range`, `referential` |
| `pattern` | string | Conditional | Substring pattern (for `format` rule) |
| `min` | string | Conditional | Minimum value (for `range` rule) |
| `max` | string | Conditional | Maximum value (for `range` rule) |
| `reference` | string | Conditional | Reference dataset (for `referential` rule) |
| `ref_column` | string | Conditional | Column in reference dataset |

**Example**:
```yaml
- id: validate_orders
  type: validate
  input: orders
  rules:
    - column: customer_id
      rule: not_null
    - column: amount
      rule: range
      min: "0"
      max: "1000000"
    - column: email
      rule: format
      pattern: "@"
  fail_on: any
  on_fail: filter
  output: valid_orders
```

**Execution Flow**:
```
input dataset -> resolve rule column indices -> parse min/max ->
  for each row: check all rules ->
    [error mode] fail_on: any -> immediate error | threshold:N -> count violations
    [filter mode] valid rows -> ViewDataset -> registry.Register(output)
```

**Dependencies**: Depends on steps that produce its input dataset.

**Output**: In filter mode, registers a named dataset. In error mode, no output dataset.

**Edge Cases / Gotchas**:
- `format` rule uses `strings.Contains`, not regex. It checks if the string representation contains the pattern substring.
- `range` rule converts values to float64 for comparison. Non-numeric values become 0.
- `referential` rule type is defined in the struct but not implemented in the executor.
- In filter mode, if `output` is empty, defaults to `{input}_valid`.
- `threshold:N` fail\_on is parsed from the `fail_on` string but the threshold comparison is not shown in the current code for error mode (only `any` triggers immediate failure).

---

## Step: `check`

**What**: Executes a SQL query and evaluates a JavaScript condition against the first result row. Fails the pipeline if the condition is false.

**Why**: Pipeline-level assertions -- verify row counts, data integrity conditions, or prerequisite states before proceeding. Acts as a gate/guard step.

**How**:
1. Gets DB connection, interpolates variables in SQL.
2. Executes query and scans the first row.
3. If `condition` is set, builds a JS script that exposes all result columns as local variables.
4. Evaluates the condition using the sandboxed transform engine.
5. If the result is falsy (nil or false), returns an error with the configured message.

**Where**: `internal/pipeline/executor_check.go`

**When**: Between query and load steps as assertions, or at pipeline start to verify prerequisites.

**Who**: Pipeline authors who need conditional pipeline gates.

**YAML Fields**:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Unique step identifier |
| `type` | string | Yes | Must be `check` |
| `depends_on` | []string | No | Step IDs that must complete first |
| `database` | string | Yes | Database name |
| `sql` | string | Yes | SQL query (should return one row) |
| `condition` | string | No | JS boolean expression evaluated against query result |
| `message` | string | No | Custom error message on failure |

**Example**:
```yaml
- id: verify_source_count
  type: check
  database: source_db
  sql: "SELECT COUNT(*) AS cnt FROM orders WHERE status = 'PENDING'"
  condition: "cnt > 0"
  message: "No pending orders found -- aborting migration"
```

**Execution Flow**:
```
sql -> interpolate ${vars} -> db.QueryContext -> scan first row ->
  [if condition set] build JS script with column vars ->
    evaluate condition -> falsy? return error with message : success
```

**Dependencies**: Typically depends on `sql` steps that set up data, or runs early in the pipeline.

**Output**: None. Purely a gate/assertion step.

**Edge Cases / Gotchas**:
- Only the first row of the query result is used. Additional rows are ignored.
- If the query returns no rows, the step fails with "query returned no rows".
- Column names are only exposed as JS variables if they pass `ValidateIdentifier` (valid JS identifier). Column names with special characters are accessible via `record["column-name"]`.
- The JS engine has a 5-second timeout.
- If `condition` is empty, the step succeeds as long as the query returns at least one row.

---

## Step: `vars`

**What**: Sets pipeline variables from static values and/or a database query. Variables are available to all subsequent steps via `${variable}` interpolation.

**Why**: Centralizes configuration values, derives runtime parameters from database queries (e.g., max date, batch ID), and supports dynamic pipeline parameterization.

**How**:
1. If `database` and `sql` are set: executes the query, reads the first row, and sets each column as a variable (column name = variable name).
2. Sets static variables from the `variables` map. Static values override DB-loaded values with the same name.
3. All variables are set via `ectx.SetVariable` (thread-safe with mutex).

**Where**: `internal/pipeline/executor_vars.go`

**When**: First steps in a pipeline, before any step that uses `${variable}` interpolation.

**Who**: Pipeline authors who need dynamic configuration.

**YAML Fields**:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Unique step identifier |
| `type` | string | Yes | Must be `vars` |
| `depends_on` | []string | No | Step IDs that must complete first |
| `variables` | map[string]any | No | Static variable key-value pairs |
| `database` | string | No | Database name for query-based variables |
| `sql` | string | No | SQL query (first row columns become variables) |

**Example**:
```yaml
- id: set_params
  type: vars
  database: source_db
  sql: "SELECT MAX(updated_at) AS max_date, COUNT(*) AS total FROM orders"
  variables:
    batch_id: "batch_2026_03"
    target_schema: "staging"
```

**Execution Flow**:
```
[if database+sql set] db.QueryContext -> scan first row ->
  for each column: ectx.SetVariable(column_name, value) ->
[for each static var] ectx.SetVariable(key, value) (overrides DB values)
```

**Dependencies**: Usually no dependencies (runs first). Other steps depend on vars for interpolation.

**Output**: None. Sets variables in the execution context.

**Edge Cases / Gotchas**:
- Database values are normalized via `NormalizeValue` (e.g., `[]byte` to string/int/float).
- Only the first row of the query is used. If the query returns no rows, no DB variables are set (no error).
- Static variables override DB-loaded variables with the same name.
- `database` and `sql` are both required for query mode. Setting only one is a no-op for the query path.

---

## Step: `read`

**What**: Reads files (CSV or Parquet) into an in-memory dataset. Supports glob patterns for multi-file reads. When paired with a downstream `load` step, uses a partitioned read-load queue pattern for bounded-memory processing.

**Why**: Brings file-based data into the pipeline. Essential for loading CSV/Parquet exports, data lake files, or files from previous pipeline runs.

**How**:
1. Validates file path against path traversal attacks.
2. **If a downstream `load` step exists for this dataset**: Uses partitioned read-load pattern.
   - Expands glob, loads file paths into a queue.
   - N workers each: read a file, convert to records, batch insert directly to DB.
   - Memory bounded to one file per worker.
   - Registers an empty placeholder dataset (load step should skip).
3. **Otherwise**: Reads all files, materializes all rows in memory.
   - Expands glob pattern, reads each file.
   - Concatenates all rows, registers as columnar dataset.

**Where**: `internal/pipeline/executor_read.go`

**When**: As source steps when data comes from files rather than databases.

**Who**: Pipeline authors reading from file-based sources.

**YAML Fields**:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Unique step identifier |
| `type` | string | Yes | Must be `read` |
| `depends_on` | []string | No | Step IDs that must complete first |
| `path` | string | Yes | File path or glob pattern (e.g., `/data/orders/*.parquet`) |
| `format` | string | Yes | `csv` or `parquet` |
| `output` | string | Yes | Output dataset name |
| `chunk_size` | int | No | Rows per chunk for streaming (default 100000) |
| `queue_size` | int | No | Chunks in queue for backpressure (default 100) |
| `threads` | int | No | Worker threads (default 8) |

**Example**:
```yaml
- id: read_exports
  type: read
  path: "/data/exports/orders_*.parquet"
  format: parquet
  output: orders_data
  threads: 4
```

**Execution Flow**:
```
validate path -> expand glob ->
  [downstream load exists] file queue -> N workers: read file -> batch insert to DB ->
  [no downstream load] read all files -> concatenate rows -> columnar dataset ->
  registry.Register(output)
```

**Dependencies**: Usually no dependencies (source step). Downstream transform/filter/load steps depend on read.

**Output**: Registers a named dataset. In partitioned read-load mode, registers an empty placeholder.

**Edge Cases / Gotchas**:
- Path traversal is validated (prevents `../../etc/passwd` style attacks).
- If no files match the glob pattern, the step fails.
- Streaming parameters (`chunk_size`, `queue_size`, `threads`) without a downstream `load` step emit a warning and materialize all data in memory.
- In partitioned read-load mode, the `load` step is automatically executed by the `read` step -- the separate `load` step in the pipeline will see an empty dataset and skip.
- CSV reader uses comma delimiter and assumes headers on first row.

---

## Step: `write`

**What**: Writes a dataset to files (CSV or Parquet). Supports splitting output by column value and parallel writing.

**Why**: Exports pipeline results to files for downstream consumption, archival, or data lake integration.

**How**:
1. Validates output path against path traversal.
2. Retrieves source dataset from registry.
3. Skips if dataset is empty and files already exist (from partitioned query).
4. Creates output directory.
5. **If `split_by` is set**: Groups rows by split column value, writes one file per group. Parallel writing with N worker threads.
6. **Otherwise**: Writes all rows to a single `output.{format}` file.
7. For CSV: Direct columnar write (values to strings inline).
8. For Parquet: Uses `WriteColumnarBatch` with configurable compression and row group size.

**Where**: `internal/pipeline/executor_write.go`

**When**: End of pipeline for file export, or paired with partitioned query for streaming output.

**Who**: Pipeline authors who need file output.

**YAML Fields**:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Unique step identifier |
| `type` | string | Yes | Must be `write` |
| `depends_on` | []string | No | Step IDs that must complete first |
| `source` | string | Yes | Source dataset name |
| `path` | string | Yes | Output directory path |
| `format` | string | No | `csv` (default) or `parquet` |
| `split_by` | string | No | Column to split output files by |
| `threads` | int | No | Parallel writer threads (default 4) |
| `compression` | string | No | Parquet compression type |
| `row_group_size` | int64 | No | Parquet row group size |

**Example**:
```yaml
- id: export_results
  type: write
  depends_on: [transform_orders]
  source: final_orders
  path: /output/orders
  format: parquet
  split_by: region
  threads: 8
  compression: snappy
```

**Execution Flow**:
```
validate path -> get source dataset ->
  [empty + files exist] skip (partitioned query already wrote) ->
  create output dir ->
  [split_by set] group rows by column -> parallel write files per group ->
  [no split] write single output.{format} file
```

**Dependencies**: Depends on steps that produce its source dataset.

**Output**: None (side-effecting: `IsSideEffecting() = true`).

**Edge Cases / Gotchas**:
- Path traversal is validated.
- If the dataset is empty but the output directory already has files, the step assumes a partitioned query wrote them and skips.
- When `split_by` is set, each file is named `{value}.{format}`.
- If `threads > number_of_groups`, threads is capped at group count.
- CSV nil values are written as empty strings.
- Parquet writes use batched `WriteColumnarBatch` to avoid materializing all rows as maps.

---

## Step: `kafka_push`

**What**: Publishes dataset records to a Kafka topic. Supports parallel writers, multiple serialization formats, compression, SASL/TLS authentication, and configurable ack policies.

**Why**: Enables pipelines to publish data to Kafka for event-driven architectures, change data capture (CDC) streams, or inter-system messaging.

**How**:
1. Retrieves input dataset from registry.
2. Applies defaults (batch size 100, 4 threads, ack=all, snappy compression, JSON serialization).
3. Interpolates `${variable}` placeholders in brokers and topic.
4. Returns early if dataset is empty.
5. Creates N Kafka writer instances (one per worker thread), configured with SASL/TLS if specified.
6. Partitions rows across workers.
7. Each worker: converts rows to Kafka messages (using `BuildMessageFromMap`), writes in batches via `writer.WriteMessages`.
8. Closes all writers, collects errors.

**Where**: `internal/pipeline/executor_kafka_push.go`

**When**: End of pipeline to publish processed data to Kafka topics.

**Who**: Pipeline authors integrating with Kafka-based systems.

**YAML Fields**:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Unique step identifier |
| `type` | string | Yes | Must be `kafka_push` |
| `depends_on` | []string | No | Step IDs that must complete first |
| `dataset` | string | Yes | Input dataset name |
| `brokers` | []string | Yes | Kafka broker addresses |
| `topic` | string | Yes | Target Kafka topic |
| `serialization` | string | No | `json` (default), `string`, `bytes` |
| `key_column` | string | No | Column to use as message key |
| `value_columns` | []string | No | Columns to include in message value |
| `header_columns` | []string | No | Columns to include as message headers |
| `timestamp_column` | string | No | Column to use as message timestamp |
| `partition` | int | No | Fixed partition number |
| `batch_size` | int | No | Messages per batch (default 100) |
| `batch_timeout` | string | No | Batch flush timeout (default 10ms) |
| `threads` | int | No | Parallel writer threads (default 4) |
| `ack` | string | No | Ack policy: `all` (default), `none`, `one` |
| `compression` | string | No | `snappy` (default), `gzip`, `lz4`, `zstd` |
| `max_retries` | int | No | Max retry attempts (default 3) |
| `retry_backoff` | string | No | Backoff duration between retries |
| `sasl` | object | No | SASL auth config (enabled, mechanism, username, password) |
| `tls` | object | No | TLS config (enabled, ca\_cert\_file, client\_cert\_file, client\_key\_file) |

**Example**:
```yaml
- id: publish_events
  type: kafka_push
  dataset: processed_orders
  brokers: ["kafka-1:9092", "kafka-2:9092"]
  topic: order-events
  key_column: order_id
  serialization: json
  batch_size: 500
  threads: 8
  compression: snappy
  sasl:
    enabled: true
    mechanism: SCRAM-SHA-256
    username: producer
    password: "${KAFKA_PASSWORD}"
```

**Execution Flow**:
```
dataset -> apply defaults -> interpolate vars in brokers/topic ->
  create N writer instances (with SASL/TLS) ->
  partition rows across workers ->
  each worker: rows -> BuildMessageFromMap -> writer.WriteMessages(batch) ->
  close writers -> collect errors
```

**Dependencies**: Depends on steps that produce its input dataset.

**Output**: None (side-effecting: `IsSideEffecting() = true`).

**Edge Cases / Gotchas**:
- Each worker gets its own Kafka writer instance (not shared).
- Empty datasets return immediately without creating writers.
- If `threads > len(records)`, threads is capped to record count.
- SASL mechanism supports PLAIN, SCRAM-SHA-256, and SCRAM-SHA-512.
- If SASL mechanism creation fails, a warning is logged and the writer proceeds without SASL (not recommended for production).
- The writer factory is a package-level variable for testability (tests inject mocks).

---

## Step: `kafka_pull`

**What**: Consumes messages from a Kafka topic into a dataset. Supports multiple consumers, manual commit, multiple serialization formats, and SASL/TLS.

**Why**: Brings Kafka event data into the pipeline for processing, transformation, and loading to databases or files.

**How**:
1. Applies defaults (30s poll duration, 10000 max records, 1 consumer, JSON, latest offset).
2. Interpolates variables in brokers, topic, and consumer group.
3. Builds Kafka dialer with SASL/TLS if configured.
4. Launches N consumer goroutines, each with its own Kafka reader.
5. Each consumer reads messages up to its record limit within the poll duration.
6. **Manual commit mode** (default): Messages are committed in batches after successful deserialization. On read/deserialize error, uncommitted messages will be reprocessed.
7. **Auto-commit mode**: When `commit_interval` is explicitly set, uses legacy auto-commit behavior.
8. Merges all consumer results, converts to columnar dataset.

**Where**: `internal/pipeline/executor_kafka_pull.go`

**When**: As a source step when data comes from Kafka.

**Who**: Pipeline authors consuming from Kafka topics.

**YAML Fields**:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Unique step identifier |
| `type` | string | Yes | Must be `kafka_pull` |
| `depends_on` | []string | No | Step IDs that must complete first |
| `output` | string | Yes | Output dataset name |
| `brokers` | []string | Yes | Kafka broker addresses |
| `topic` | string | Yes | Source Kafka topic |
| `consumer_group` | string | No | Consumer group ID (default `mass-migrator-group`) |
| `serialization` | string | No | `json` (default), `string`, `bytes` |
| `offset` | string | No | `latest` (default) or `earliest` |
| `poll_duration` | string | No | Max time to poll (default `30s`) |
| `max_records` | int | No | Max records to consume (default 10000) |
| `drain` | bool | No | Consume until topic is empty within poll window |
| `consumers` | int | No | Number of consumer goroutines (default 1) |
| `include_metadata` | bool | No | Include `_kafka_partition`, `_kafka_offset`, `_kafka_timestamp` |
| `commit_strategy` | string | No | Commit strategy |
| `commit_interval` | string | No | Auto-commit interval (empty = manual commit) |
| `commit_batch_size` | int | No | Batch size for manual commit (default 100) |
| `session_timeout` | string | No | Kafka session timeout |
| `heartbeat_interval` | string | No | Kafka heartbeat interval |
| `rebalance_timeout` | string | No | Kafka rebalance timeout |
| `max_bytes` | int | No | Max bytes per fetch (default 1MB) |
| `sasl` | object | No | SASL auth config |
| `tls` | object | No | TLS config |

**Example**:
```yaml
- id: consume_events
  type: kafka_pull
  brokers: ["kafka:9092"]
  topic: user-events
  consumer_group: migrator-consumers
  output: events_data
  serialization: json
  offset: earliest
  poll_duration: "60s"
  max_records: 50000
  consumers: 3
  include_metadata: true
  commit_batch_size: 500
```

**Execution Flow**:
```
apply defaults -> interpolate vars -> build SASL/TLS dialer ->
  launch N consumer goroutines ->
  each consumer: create reader -> read messages within poll duration ->
    [manual commit] accumulate processed msgs -> commit in batches ->
    [auto-commit] reader handles commits ->
  merge all consumer results -> extract columns from first row ->
  columnar dataset -> registry.Register(output)
```

**Dependencies**: Usually no dependencies (source step).

**Output**: Registers a named dataset (`OutputDataset() = output`).

**Edge Cases / Gotchas**:
- `maxRecords` is split evenly across consumers (`recordsPerConsumer = maxRecords / consumers`).
- Manual commit is the default (prevents message loss). Auto-commit only activates when `commit_interval` is explicitly set.
- On deserialization error in manual commit mode, uncommitted messages are NOT committed -- they will be reprocessed on next pull.
- Column names in the output are sorted alphabetically (from `sort.Strings(columns)` on the first row's keys).
- If `output` is empty, defaults to `{step_id}_output`.
- The `string` serialization produces a single `value` column. The `bytes` serialization produces a single `data` column.
- The reader factory is a package-level variable for testability.

---

## Step: `distributed_join`

**What**: Performs a hash-distributed join between two datasets from potentially different databases. Hash-partitions both sides into K temp CSV bucket files, then joins each bucket pair in parallel. Memory usage is O(max\_bucket\_size), not O(total\_data).

**Why**: Enables cross-database joins that would be impossible in SQL alone. The hash-bucketing approach allows joining datasets that are too large to fit in memory, with memory bounded to the largest single bucket.

**How**:
1. Resolves join keys (supports different key names on left and right sides).
2. Creates a temp directory for bucket files.
3. **Phase 1a**: Executes left SQL, scans rows, distributes to K CSV bucket files using FNV-1a hash.
4. **Phase 1b**: Same for right SQL.
5. **Phase 2**: Launches N worker goroutines. Each reads a bucket pair (left + right), builds a hash map on the right side, performs inner hash join.
6. Merges all bucket join results.
7. **Phase 3**: Cleans up temp directory (deferred).
8. Registers result dataset.

**Where**: `internal/pipeline/executor_distributed_join.go`

**When**: When joining large datasets across different databases that cannot be loaded into memory simultaneously.

**Who**: Pipeline authors doing cross-database joins on large datasets.

**YAML Fields**:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Unique step identifier |
| `type` | string | Yes | Must be `distributed_join` |
| `depends_on` | []string | No | Step IDs that must complete first |
| `left_database` | string | Yes | Left-side database name |
| `left_sql` | string | Yes | Left-side SELECT query |
| `right_database` | string | Yes | Right-side database name |
| `right_sql` | string | Yes | Right-side SELECT query |
| `join_key` | string | Conditional | Join column name (when same on both sides) |
| `left_join_key` | string | Conditional | Left-side join column (overrides `join_key`) |
| `right_join_key` | string | Conditional | Right-side join column (overrides `join_key`) |
| `lookup_columns` | []string | Yes | Columns to add from right side to output |
| `output` | string | Yes | Output dataset name |
| `buckets` | int | No | Number of hash buckets (default 50) |
| `threads` | int | No | Parallel workers for Phase 2 (default 4) |
| `temp_dir` | string | No | Directory for bucket files (default: system temp) |

**Example**:
```yaml
- id: cross_db_join
  type: distributed_join
  left_database: oracle_prod
  left_sql: "SELECT id, name, dept_id FROM employees"
  right_database: postgres_hr
  right_sql: "SELECT dept_id, dept_name, location FROM departments"
  join_key: dept_id
  lookup_columns: [dept_name, location]
  output: employees_with_dept
  buckets: 100
  threads: 8
```

**Execution Flow**:
```
Phase 1: SQL -> scan rows -> hash(key) % K -> write to bucket CSV files
  Phase 1a: left_sql -> left_0.csv .. left_K.csv
  Phase 1b: right_sql -> right_0.csv .. right_K.csv

Phase 2: N workers:
  for each bucket: read left_i.csv + right_i.csv ->
    build hash map on right -> inner hash join -> collect results

Phase 3: cleanup temp dir

Merge all results -> columnar dataset -> registry.ForceRegister(output)
```

**Dependencies**: Depends on `vars` steps for variable interpolation or `sql` steps for table setup.

**Output**: Registers a named dataset (`OutputDataset() = output`). Uses `ForceRegister` (overwrites existing).

**Edge Cases / Gotchas**:
- This is an **inner join** only -- rows without matches on either side are dropped.
- All values are stored as strings in the CSV bucket files. Type information is lost (everything becomes string in the output).
- FNV-1a hash is used for bucket assignment. Skewed key distributions can cause uneven bucket sizes, reducing parallelism benefit.
- Temp files are cleaned up via `defer os.RemoveAll(tempDir)`, even on error.
- The join supports 1:N (one left row matching multiple right rows) -- the right-side hash map stores lists of row indices.
- At least one of `join_key` or both `left_join_key`/`right_join_key` must be set.
- Output columns are: all left columns + lookup columns from right side.
- Empty bucket files (no matches in a bucket) are handled gracefully (nil return, no error).

---

## Cross-Reference: Step Type Summary

| Step Type | Side-Effecting | Produces Dataset | Parallel | Uses JS Engine |
|-----------|:--------------:|:----------------:|:--------:|:--------------:|
| `sql` | Yes | No | No | No |
| `query` | No | Yes | Yes (partitioned) | No |
| `load` | Yes | No | Yes (threads) | No |
| `transform` | No | Yes | Yes (threads) | Yes |
| `filter` | No | Yes | No | Yes |
| `project` | No | Yes | No | No |
| `sort` | No | Yes | No | No |
| `dedup` | No | Yes | No | No |
| `aggregate` | No | Yes | Yes (threads) | No |
| `window` | No | Yes | No | No |
| `sample` | No | Yes | No | No |
| `pivot` | No | Yes | No | No |
| `split` | No | Yes (multiple) | No | Yes (condition) |
| `setop` | No | Yes | No | No |
| `validate` | No | Yes (filter mode) | No | No |
| `check` | No | No | No | Yes |
| `vars` | No | No | No | No |
| `read` | No | Yes | Yes (threads) | No |
| `write` | Yes | No | Yes (threads) | No |
| `kafka_push` | Yes | No | Yes (threads) | No |
| `kafka_pull` | No | Yes | Yes (consumers) | No |
| `distributed_join` | No | Yes | Yes (threads) | No |

---

## Pipeline Execution Model

Steps are executed by the **DAG Scheduler** (`internal/pipeline/scheduler.go`), which:

1. Builds a dependency graph from `depends_on` declarations.
2. Launches steps whose dependencies are all satisfied (no level-based batching).
3. Caps concurrency with a semaphore (`maxParallel`).
4. Supports per-step timeouts, continue-on-error mode, and resume from completed steps.
5. Side-effecting completed steps are skipped on resume; idempotent steps are re-executed to rebuild datasets.

The **Runner** (`internal/pipeline/runner.go`) orchestrates:
1. Pipeline YAML parsing and DAG construction.
2. Database connection pool setup.
3. State writer initialization and recovery.
4. Watermark tracker initialization.
5. DAG scheduler execution.
6. Cleanup and timing reports.
