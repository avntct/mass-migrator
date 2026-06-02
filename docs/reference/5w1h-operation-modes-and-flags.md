# Mass Migrator v3 — 5W1H Reference Guide

## Table of Contents

- [PART 1: Operation Modes](#part-1-operation-modes)
  - [Data Generation](#data-generation)
  - [File Import (CSV/Parquet to DB)](#file-import-csvparquet-to-db)
  - [Database Migration (DB to DB)](#database-migration-db-to-db)
  - [Database Export](#database-export)
  - [Kafka Integration](#kafka-integration)
  - [Pipeline and Orchestration](#pipeline-and-orchestration)
  - [Query and DDL](#query-and-ddl)
  - [JSON Operations](#json-operations)
  - [Verification](#verification)
  - [Rule Engine](#rule-engine)
- [PART 2: CLI Flags](#part-2-cli-flags)
  - [Database Flags](#database-flags)
  - [Performance Flags](#performance-flags)
  - [CSV / File Processing Flags](#csv--file-processing-flags)
  - [Table Management Flags](#table-management-flags)
  - [Transform Flags](#transform-flags)
  - [Data Generation Flags](#data-generation-flags)
  - [Group Processing Flags](#group-processing-flags)
  - [Static Column Flags](#static-column-flags)
  - [Column Mapping Flags](#column-mapping-flags)
  - [Parquet Flags](#parquet-flags)
  - [Metrics and Progress Flags](#metrics-and-progress-flags)
  - [State Management Flags](#state-management-flags)
  - [Error Handling Flags](#error-handling-flags)
  - [Debug Flags](#debug-flags)
  - [Pipeline Flags](#pipeline-flags)
  - [License Flags](#license-flags)
  - [Config Flags](#config-flags)

---

# PART 1: Operation Modes

Mass Migrator v3 defines 28 operation modes in `pkg/types/mode.go`. The 23 primary modes are documented below; the 5 key management modes (keygen, keyrotate, keyassess, keylist, keyinfo) are reserved for encryption key lifecycle and are not yet implemented.

Mode routing is handled by `internal/app/router.go`, which parses the mode string via `types.ParseMode()` and dispatches to the appropriate orchestrator. Modes can be activated via `--mode <name>` on the root command or through dedicated subcommands (`csv2db`, `gencsv`, `pipeline`, `query`, `kafka-push`, `kafka-pull`, `daemon`).

---

## Data Generation

### Mode: `gencsv`

- **What**: Generate synthetic CSV test data from column definition DSL. Supports typed columns (BIGINT, STRING, TIMESTAMP, UUID, DECIMAL, etc.) with distribution control (SEQUENTIAL, RANDOM, GAUSSIAN, ZIPF).
- **Why**: Create realistic test datasets for benchmarking imports, validating transforms, and load-testing migration pipelines without access to production data.
- **How**: `CSVGeneratorOrchestrator` parses `--column-definitions` DSL string, initializes a seeded RNG, iterates `record-count` times writing rows via Go's `encoding/csv` writer. Sequential counters maintain monotonic IDs. The delimiter from config is applied to the CSV writer.
- **Where**: `internal/generator/csv_generator.go` (orchestrator), `internal/generator/column_def.go` (DSL parser), `internal/generator/generator.go` (value generators).
- **When**: Before integration tests, to populate staging tables, or to generate reference files for CSV import validation.
- **Who**: QA engineers, developers building test harnesses, CI/CD pipelines needing deterministic test data.
- **Parameters**: `--output-csv-path` (or `--output-file`), `--record-count`, `--column-definitions`, `--seed`, `--csv-include-header`, `--delimiter`
- **Subcommand**: `mass-migrator gencsv --output test.csv --records 100000 --columns "id:BIGINT:SEQUENTIAL:1:1000000,name:STRING,ts:TIMESTAMP"`
- **Example (legacy)**: `mass-migrator --mode gencsv --output-csv-path test.csv --record-count 100000 --column-definitions "id:BIGINT:SEQUENTIAL:1:1000000,name:STRING"`

---

### Mode: `genparquet`

- **What**: Generate synthetic Parquet test data from the same column definition DSL used by `gencsv`. Outputs a columnar Parquet file with configurable compression and row group size.
- **Why**: Test Parquet-based import pipelines, validate Parquet reader/writer round-trips, and benchmark columnar storage performance without real data.
- **How**: `ParquetGeneratorOrchestrator` parses column definitions, initializes `writer.NewParquetWriter` with compression and row group config, then generates records in batches of `batch-size`, converting each to a `record.Record` before writing. Uses the same RNG and sequential counter logic as CSV generation.
- **Where**: `internal/generator/parquet_generator.go` (orchestrator), `internal/writer/parquet_writer.go` (Parquet output).
- **When**: Before testing Parquet import paths, or when benchmarking Parquet vs CSV throughput.
- **Who**: Data engineers evaluating columnar formats, developers testing Parquet reader compatibility.
- **Parameters**: `--output-parquet-path` (or `--output-file`), `--record-count`, `--column-definitions`, `--seed`, `--parquet-compression`, `--parquet-row-group-size`, `--batch-size`
- **Example**: `mass-migrator --mode genparquet --output-parquet-path test.parquet --record-count 500000 --column-definitions "id:BIGINT:SEQUENTIAL,amount:DECIMAL:RANDOM:0:10000:2" --parquet-compression SNAPPY`

---

## File Import (CSV/Parquet to DB)

All four file import modes share the `CSVImportOrchestrator` (`internal/orchestrator/migration/csv_migration.go`). The orchestrator detects Parquet vs CSV by file extension (`.parquet`/`.pqt`), opens the appropriate reader, optionally applies a JS transform, batches records, and dispatches them to parallel writer goroutines using the strategy pattern. Supports multi-file mode via `--csv-file-pattern` + `--group-values`.

### Mode: `insert-ind`

- **What**: Import CSV/Parquet file into a database table using INSERT strategy. Each batch becomes a multi-row INSERT statement.
- **Why**: Fastest path for initial data loads where no existing data conflicts. Multi-row INSERT minimizes round-trips. Supports auto-increment detection and auto-table creation.
- **How**: `CSVImportOrchestrator.Run()` resolves target DSN, creates connection pool, parses columns from `--csv-mapping` or `--columns`, optionally auto-creates the table, initializes `InsertStrategy` (batch size 2000 rows per multi-row INSERT), then runs a producer-consumer pipeline: reader goroutine reads records into a channel, N worker goroutines each pull batches and call `strategy.ExecuteBatch()` within a transaction. Static columns are injected via 3-level evaluation (SQL literal, function, record expression). Retry helper wraps each batch with exponential backoff.
- **Where**: `internal/orchestrator/migration/csv_migration.go`, `internal/strategy/insert.go`, `internal/reader/csv_reader.go`, `internal/reader/parquet_reader.go`.
- **When**: Use for initial loads, staging tables, or when target table is empty/truncated. Not suitable when rows may already exist (use merge/upsert instead).
- **Who**: Data engineers loading CSV exports, ETL pipelines importing flat files, CI jobs seeding test databases.
- **Parameters**: `--input-file`, `--target-table`, `--csv-mapping`, `--columns`, `--batch-size`, `--threads`, `--jdbc-url`, `--db-type`, `--auto-create-table`, `--force-recreate`, `--transform-script`, `--static-update-columns`, `--static-update-values`
- **Subcommand**: `mass-migrator csv2db --input data.csv --db-url "sqlite:./mydb.db" --table users --mapping "id:id:BIGINT,name:name:VARCHAR"`
- **Example (legacy)**: `mass-migrator --mode insert-ind --input-file data.csv --target-table users --jdbc-url "jdbc:postgresql://localhost:5432/mydb" --csv-mapping "id:id:BIGINT,name:name:VARCHAR" --batch-size 100000 --threads 8`

---

### Mode: `update-ind`

- **What**: Import CSV/Parquet file into a database table using UPDATE strategy. Each record generates an UPDATE ... SET ... WHERE key_column = ? statement.
- **Why**: Apply corrections or modifications to existing rows. Batch UPDATE via VALUES is supported on PostgreSQL and SQL Server for higher throughput. Key columns are required to match existing rows.
- **How**: Same `CSVImportOrchestrator` pipeline as `insert-ind`, but with `UpdateStrategy`. For PostgreSQL/SQL Server with column types set, uses batch UPDATE via CTE (`WITH vals AS (VALUES ...)`) to update multiple rows in one statement. Falls back to per-row UPDATE for other dialects. Key columns define the WHERE clause.
- **Where**: `internal/orchestrator/migration/csv_migration.go`, `internal/strategy/update.go`.
- **When**: Correcting data in-place (e.g., patching email addresses, updating statuses). Requires rows to already exist.
- **Who**: Data ops teams applying corrections, migration scripts fixing data quality issues.
- **Parameters**: `--input-file`, `--target-table`, `--csv-mapping`, `--columns`, `--key-columns` (required), `--batch-size`, `--threads`, `--jdbc-url`, `--db-type`, `--transform-script`
- **Example**: `mass-migrator --mode update-ind --input-file corrections.csv --target-table users --key-columns "id" --columns "email,phone" --jdbc-url "jdbc:postgresql://localhost/mydb"`

---

### Mode: `merge-ind`

- **What**: Import CSV/Parquet file into a database table using MERGE strategy (INSERT if not exists, UPDATE if exists). Uses dialect-native MERGE syntax (SQL Server/Oracle MERGE, PostgreSQL INSERT ON CONFLICT via CTE).
- **Why**: Handle mixed inserts and updates in a single pass. Ideal for incremental loads where some rows are new and others need updating. Uses key columns to determine match criteria.
- **How**: `CSVImportOrchestrator` with `MergeStrategy`. Constructs dialect-specific MERGE SQL: SQL Server/Oracle use `MERGE INTO ... USING (VALUES ...) ON ... WHEN MATCHED THEN UPDATE WHEN NOT MATCHED THEN INSERT`; PostgreSQL falls back to a CTE-based approach. Key columns are excluded from the UPDATE SET clause. Auto-increment columns detected and excluded.
- **Where**: `internal/orchestrator/migration/csv_migration.go`, `internal/strategy/merge.go`.
- **When**: Incremental file loads where the file may contain both new and updated records. Replaces separate insert + update passes.
- **Who**: ETL developers building incremental load pipelines, data engineers syncing file exports to databases.
- **Parameters**: `--input-file`, `--target-table`, `--csv-mapping`, `--columns`, `--key-columns` (required), `--batch-size`, `--threads`, `--jdbc-url`, `--db-type`, `--transform-script`
- **Example**: `mass-migrator --mode merge-ind --input-file daily_export.csv --target-table accounts --key-columns "account_id" --csv-mapping "account_id:account_id:BIGINT,balance:balance:DECIMAL,status:status:VARCHAR" --jdbc-url "jdbc:sqlserver://host:1433;database=fin"`

---

### Mode: `upsert-ind`

- **What**: Import CSV/Parquet file into a database table using UPSERT strategy (INSERT ON CONFLICT UPDATE). Uses dialect-native upsert syntax: PostgreSQL `INSERT ... ON CONFLICT DO UPDATE`, MySQL `INSERT ... ON DUPLICATE KEY UPDATE`, SQLite `INSERT OR REPLACE`.
- **Why**: Simpler and often faster than MERGE for databases that support native upsert. Single-statement atomicity per batch. Key columns excluded from UPDATE SET clause.
- **How**: `CSVImportOrchestrator` with `UpsertStrategy`. Batch size defaults to 2000. Constructs a single multi-row INSERT with an ON CONFLICT clause. Auto-increment detection skips identity columns. Dialect `SupportsUpsert()` check ensures the database supports native upsert.
- **Where**: `internal/orchestrator/migration/csv_migration.go`, `internal/strategy/upsert.go`.
- **When**: PostgreSQL/MySQL/SQLite incremental loads. Preferred over merge-ind when the database natively supports upsert syntax (cleaner SQL, often faster).
- **Who**: Application developers syncing data from files, microservice data import pipelines.
- **Parameters**: `--input-file`, `--target-table`, `--csv-mapping`, `--columns`, `--key-columns` (required), `--batch-size`, `--threads`, `--jdbc-url`, `--db-type`, `--transform-script`
- **Example**: `mass-migrator --mode upsert-ind --input-file users.csv --target-table users --key-columns "email" --jdbc-url "jdbc:postgresql://localhost/app" --batch-size 50000`

---

## Database Migration (DB to DB)

All four database migration modes share the `DbMigrationOrchestrator` (`internal/orchestrator/migration/db_migration.go`). The orchestrator opens both source and target connection pools, resolves column mapping (source-to-target), parses static columns, builds a dynamic SQL query from the source, and writes to the target using the strategy pattern. Supports column mapping, static columns, group processing, and retry/error tracking.

### Mode: `insert`

- **What**: Database-to-database migration using INSERT strategy. Reads from a source database query and inserts records into a target database table.
- **Why**: Migrate data between databases (e.g., Oracle to PostgreSQL) with full type mapping and optional column renaming. Multi-row INSERT for throughput.
- **How**: `DbMigrationOrchestrator.Run()` creates source and target pools, parses `--column-mapping` (srcCol:tgtCol:TYPE) or `--columns` for same-name mapping, resolves static columns via dialect classifier, executes source query with fetch-size cursor, batches rows, and dispatches to `InsertStrategy` workers writing to target. Multi-clock license validation checks expiry against both source and target DB server clocks.
- **Where**: `internal/orchestrator/migration/db_migration.go`, `internal/strategy/insert.go`, `internal/orchestrator/builder/` (dynamic SQL).
- **When**: Initial data migration between heterogeneous databases. Schema must exist on target (or use DDL mode first).
- **Who**: DBAs performing cross-platform migrations, data engineers building data warehouse feeds.
- **Parameters**: `--source-jdbc-url`, `--source-db-type`, `--source-username`, `--source-password`, `--source-query`, `--target-jdbc-url` (or `--jdbc-url`), `--target-db-type` (or `--db-type`), `--target-table`, `--column-mapping`, `--columns`, `--batch-size`, `--threads`, `--fetch-size`, `--static-update-columns`, `--static-update-values`
- **Example**: `mass-migrator --mode insert --source-jdbc-url "jdbc:oracle:thin:@prod:1521/ORCL" --source-query "SELECT id, name, email FROM users" --jdbc-url "jdbc:postgresql://target:5432/app" --target-table users --column-mapping "id:user_id:BIGINT,name:full_name:VARCHAR,email:email:VARCHAR" --threads 8`

---

### Mode: `update`

- **What**: Database-to-database migration using UPDATE strategy. Reads from source and updates matching rows in the target.
- **Why**: Synchronize changes from a source system to a target. Batch UPDATE via VALUES on PostgreSQL/SQL Server for throughput; per-row fallback on others.
- **How**: Same `DbMigrationOrchestrator` pipeline as `insert`, but dispatches to `UpdateStrategy`. Key columns are required for WHERE clause matching. Column type map is set for batch UPDATE casting on supported dialects.
- **Where**: `internal/orchestrator/migration/db_migration.go`, `internal/strategy/update.go`.
- **When**: Applying incremental changes where only existing rows need updating (e.g., syncing price changes from ERP to data warehouse).
- **Who**: Data engineers maintaining replicated tables, ETL pipelines applying deltas.
- **Parameters**: Same as `insert` mode plus `--key-columns` (required).
- **Example**: `mass-migrator --mode update --source-jdbc-url "jdbc:mysql://src:3306/erp" --source-query "SELECT product_id, price, updated_at FROM products WHERE updated_at > '2026-01-01'" --jdbc-url "jdbc:postgresql://dw:5432/warehouse" --target-table dim_products --key-columns "product_id" --column-mapping "product_id:product_id:BIGINT,price:unit_price:DECIMAL"`

---

### Mode: `merge`

- **What**: Database-to-database migration using MERGE strategy. Reads from source, inserts new rows and updates existing rows in target.
- **Why**: Handle mixed new/changed records in a single pass. Dialect-native MERGE SQL for atomicity and performance.
- **How**: `DbMigrationOrchestrator` with `MergeStrategy`. Same pipeline as other db-to-db modes. Key columns excluded from UPDATE SET clause. Auto-increment detection via `dialect.GetAutoIncrementColumns()`.
- **Where**: `internal/orchestrator/migration/db_migration.go`, `internal/strategy/merge.go`.
- **When**: Incremental cross-database sync where source contains both new and updated records.
- **Who**: Enterprise data integration teams, migration projects with ongoing sync requirements.
- **Parameters**: Same as `insert` mode plus `--key-columns` (required).
- **Example**: `mass-migrator --mode merge --source-jdbc-url "jdbc:oracle:thin:@src:1521/PROD" --source-query "SELECT * FROM orders WHERE order_date >= TRUNC(SYSDATE-1)" --jdbc-url "jdbc:postgresql://target/dw" --target-table orders --key-columns "order_id" --batch-size 100000`

---

### Mode: `upsert`

- **What**: Database-to-database migration using UPSERT strategy. Reads from source and performs INSERT ON CONFLICT UPDATE on target.
- **Why**: Simpler syntax than MERGE on databases that support native upsert. Single-statement atomicity per batch with conflict resolution.
- **How**: `DbMigrationOrchestrator` with `UpsertStrategy`. Checks `dialect.SupportsUpsert()` on target. Constructs multi-row INSERT with ON CONFLICT clause. Key columns define the conflict target.
- **Where**: `internal/orchestrator/migration/db_migration.go`, `internal/strategy/upsert.go`.
- **When**: Cross-database sync to PostgreSQL/MySQL/SQLite targets. Preferred over merge when the target supports native upsert.
- **Who**: Application teams migrating between cloud databases, developers building sync pipelines.
- **Parameters**: Same as `insert` mode plus `--key-columns` (required).
- **Example**: `mass-migrator --mode upsert --source-jdbc-url "jdbc:mysql://legacy:3306/app" --source-query "SELECT * FROM customers" --jdbc-url "jdbc:postgresql://new:5432/app" --target-table customers --key-columns "customer_id" --threads 4`

---

## Database Export

### Mode: `load2csv`

- **What**: Export data from a database query to one or more CSV files. Supports group-based splitting (one file per group value) and all CSV formatting options.
- **Why**: Extract data from databases for file-based processing, data sharing, archival, or downstream CSV-based ETL. 256KB write buffer for high-throughput output (5-10x improvement over default 4KB).
- **How**: `ExportCSVOrchestrator` resolves source DSN, creates connection pool, validates license against DB clock, determines output path, then either runs a single export query or iterates over group values to produce per-group files. For each query, uses `builder.NewDynamicSqlBuilderWithEscaper` to inject group predicates. Results are streamed through a buffered CSV writer.
- **Where**: `internal/orchestrator/export/csv_export.go`, `internal/orchestrator/builder/` (dynamic SQL), `internal/orchestrator/util/` (utilities).
- **When**: Regular database exports for data feeds, creating CSV snapshots for auditing, extracting subsets by group for distributed processing.
- **Who**: Data engineers building export pipelines, analysts extracting datasets, DBAs creating backups.
- **Parameters**: `--source-jdbc-url`, `--source-db-type`, `--source-username`, `--source-password`, `--source-query`, `--output-file` (or `--output-csv-path`), `--delimiter`, `--group-columns`, `--group-values`, `--split-output-by-group`, `--threads`
- **Example**: `mass-migrator --mode load2csv --source-jdbc-url "jdbc:postgresql://db:5432/app" --source-query "SELECT id, name, region FROM customers" --output-file customers.csv --delimiter "|" --source-username admin --source-password secret`

---

### Mode: `load2parquet`

- **What**: Export data from a database query to one or more Parquet files. Supports group-based splitting, configurable compression (SNAPPY, GZIP, LZ4, ZSTD), and row group size control.
- **Why**: Columnar Parquet format offers superior compression and analytical query performance compared to CSV. Ideal for data lake ingestion, Spark/Presto consumption, and long-term archival.
- **How**: `ExportParquetOrchestrator` follows the same pattern as CSV export but uses `writer.NewParquetWriter` for output. Records are buffered as `record.Record` objects and written in batches. Group-based splitting creates separate Parquet files with group value substitution in the output path.
- **Where**: `internal/orchestrator/export/parquet_export.go`, `internal/writer/parquet_writer.go`.
- **When**: Building data lake feeds, creating Parquet snapshots for analytical workloads, exporting to S3 for Athena/Spark consumption.
- **Who**: Data platform engineers, analytics teams, data lake architects.
- **Parameters**: `--source-jdbc-url`, `--source-db-type`, `--source-username`, `--source-password`, `--source-query`, `--output-parquet-path` (or `--output-file`), `--parquet-compression`, `--parquet-row-group-size`, `--group-columns`, `--group-values`, `--split-output-by-group`, `--threads`
- **Example**: `mass-migrator --mode load2parquet --source-jdbc-url "jdbc:postgresql://dw:5432/warehouse" --source-query "SELECT * FROM fact_sales WHERE sale_date >= '2026-01-01'" --output-parquet-path sales_2026.parquet --parquet-compression ZSTD --parquet-row-group-size 134217728`

---

## Kafka Integration

### Mode: `kafka-push`

- **What**: Push data from a database query or file to a Kafka topic. Operates as a pipeline wrapper that validates a YAML file contains exactly one `kafka_push` step, then executes it via the pipeline engine.
- **Why**: Stream database extracts to Kafka for real-time downstream consumption. Supports key column routing, serialization (JSON, Avro), compression, batching, SASL/TLS security, and configurable ack levels.
- **How**: The `kafka-push` subcommand parses the pipeline YAML, validates exactly one `kafka_push` step exists, then delegates to `pipeline.Run()`. The `KafkaPushStep` executor creates a `kafka.MessageWriter`, partitions the input dataset by row ranges across `threads` workers, each serializing records and writing to Kafka with batch size and timeout controls.
- **Where**: `cmd/mass-migrator/kafka_cmd.go` (CLI), `internal/pipeline/executor_kafka_push.go` (executor), `internal/kafka/message.go` (producer).
- **When**: Building CDC pipelines, streaming database changes to event-driven architectures, feeding Kafka-based data pipelines.
- **Who**: Platform engineers building event streaming systems, integration teams connecting databases to Kafka.
- **Parameters**: `--file` (pipeline YAML, required). All Kafka configuration is in the YAML step definition (brokers, topic, serialization, key_column, ack, compression, SASL, TLS).
- **Example**: `mass-migrator kafka-push --file push-pipeline.yaml`

---

### Mode: `kafka-pull`

- **What**: Pull data from a Kafka topic into a database table or dataset. Operates as a pipeline wrapper that validates a YAML file contains exactly one `kafka_pull` step.
- **Why**: Consume Kafka events and materialize them into a database for queryable state. Supports consumer groups, offset management (earliest/latest), commit strategies, session timeouts, and bounded consumption (max_records, drain mode).
- **How**: The `kafka-pull` subcommand validates and delegates to the pipeline engine. The `KafkaPullStep` executor creates a `kafka.MessageReader` (bounded reader wrapping kafka-go consumer), reads messages up to max_records or poll_duration, deserializes to records, and stores as a dataset. Downstream load steps write to database.
- **Where**: `cmd/mass-migrator/kafka_cmd.go` (CLI), `internal/pipeline/executor_kafka_pull.go` (executor), `internal/kafka/bounded_reader.go` (consumer).
- **When**: Materializing Kafka event streams into operational databases, building Kafka-to-database sync pipelines.
- **Who**: Backend engineers building event sourcing, data engineers building stream-to-batch bridges.
- **Parameters**: `--file` (pipeline YAML, required). Kafka configuration is in the YAML step definition (brokers, topic, consumer_group, offset, poll_duration, max_records, SASL, TLS).
- **Example**: `mass-migrator kafka-pull --file pull-pipeline.yaml`

---

## Pipeline and Orchestration

### Mode: `pipeline`

- **What**: Execute a multi-step YAML pipeline definition. Supports 21 step types (sql, query, load, setop, transform, check, split, vars, filter, dedup, aggregate, project, sort, validate, sample, pivot, write, read, window, kafka_push, kafka_pull, distributed_join) with DAG-based dependency resolution, parallel execution, watermark tracking, dataset registry, and variable interpolation.
- **Why**: Orchestrate complex data flows that require multiple queries, transformations, validations, and loads across heterogeneous databases. Single declarative YAML replaces hundreds of lines of scripting. Built-in DAG scheduling, error handling, and resume/checkpoint support.
- **How**: `pipeline.Run()` parses the YAML file via `ParsePipelineFile()`, runs DAG validation (`ValidatePipeline()` for cycle detection), resolves database connections, initializes the dataset registry and variable store, then hands off to the `Scheduler`. The scheduler performs topological ordering, dispatches ready steps to a worker pool (respecting `depends_on`), tracks completion, and manages shared datasets between steps. Each step type has a dedicated executor file (e.g., `executor_query.go`, `executor_load.go`).
- **Where**: `internal/pipeline/` (22+ files: parser.go, scheduler.go, executor.go, executor_*.go, validate_dag.go, step.go, dataset_registry.go, etc.).
- **When**: Any multi-step data flow: ETL pipelines, data warehouse loads, cross-database joins, incremental sync with watermarks, data quality validation chains.
- **Who**: Data engineers, platform teams, anyone building repeatable data workflows.
- **Parameters**: `--pipeline-file` (required), `--pipeline-memory-threshold-mb`, `--progress-interval`
- **Subcommand**: `mass-migrator pipeline --config pipeline.yaml`
- **Example (legacy)**: `mass-migrator --mode pipeline --pipeline-file etl_pipeline.yaml --pipeline-memory-threshold-mb 1024 --progress-interval 5`

---

### Mode: `daemon`

- **What**: Run a pipeline YAML on a cron schedule with configurable overlap policies and concurrency limits. Long-running process that repeatedly executes pipelines.
- **Why**: Automate recurring data pipelines (e.g., every 5 minutes, hourly, daily) without external schedulers like cron or Airflow. Built-in overlap handling prevents duplicate runs.
- **How**: The `daemon` subcommand parses the pipeline YAML, extracts or overrides the daemon config (schedule, max-concurrent, overlap-policy), and enters the scheduler loop. The `Scheduler` from `internal/pipeline/` uses `inFlight` tracking to prevent duplicate executions. Three overlap policies: `skip` (drop if running), `queue` (wait), `cancel_previous` (abort current and start new). Job heartbeat and watchdog detect stale jobs.
- **Where**: `cmd/mass-migrator/kafka_cmd.go` (CLI), `internal/pipeline/scheduler.go` (scheduler), `internal/pipeline/` (pipeline execution).
- **When**: Production data sync jobs that run continuously (e.g., every 5 minutes replicate changes from OLTP to OLAP).
- **Who**: Platform operators, SREs managing data pipelines, teams replacing Airflow/cron for simple schedules.
- **Parameters**: `--file` (pipeline YAML, required), `--schedule` (cron expression, required unless in YAML), `--max-concurrent` (default 1), `--overlap-policy` (skip/queue/cancel_previous, default skip), `--shutdown-timeout` (default 60s)
- **Example**: `mass-migrator daemon --file sync_pipeline.yaml --schedule "*/5 * * * *" --max-concurrent 2 --overlap-policy skip`

---

### Mode: `workflow-scheduler`

- **What**: Reserved mode for advanced workflow scheduling with complex dependency graphs, conditional branching, and multi-pipeline orchestration.
- **Why**: Planned for scenarios requiring inter-pipeline dependencies, conditional execution based on external signals, and enterprise workflow management features.
- **How**: Not yet implemented. Currently returns an error: "workflow scheduler not yet implemented".
- **Where**: `pkg/types/mode.go` (mode constant), `internal/app/router.go` (dispatch stub).
- **When**: Future release. Intended for enterprise deployments requiring multi-pipeline orchestration.
- **Who**: Enterprise data platform teams with complex scheduling requirements.
- **Parameters**: TBD.
- **Example**: N/A (not yet implemented).

---

## Query and DDL

### Mode: `query`

- **What**: Execute an arbitrary SQL query against a database and display results in configurable formats (single value, JSON, CSV, table).
- **Why**: Quick ad-hoc database queries from the command line without a separate SQL client. Useful for validation checks, row counts, and data inspection during migration projects.
- **How**: The `query` subcommand accepts SQL as a positional argument or from a file (`--file`). Connects via pgx (currently PostgreSQL-specific in the query command), executes the query, reads all results, and formats output based on `--format`. Supports file output via `--output`.
- **Where**: `cmd/mass-migrator/query_cmd.go`.
- **When**: Quick data validation during migration (row counts, spot checks), scripted health checks, CI/CD verification steps.
- **Who**: DBAs, data engineers, migration project leads verifying data integrity.
- **Parameters**: SQL query (positional arg), `--file` (-f, read query from file), `--format` (-F, single/json/csv/table), `--output` (-o, output file), `--jdbc-url`, `--db-user`, `--db-password`
- **Example**: `mass-migrator query "SELECT COUNT(*) FROM users" --jdbc-url "jdbc:postgresql://localhost:5432/app" --db-user admin`
- **Example (CSV output)**: `mass-migrator query --format csv "SELECT id, name FROM users LIMIT 100" --output users_sample.csv`

---

### Mode: `ddl`

- **What**: Execute DDL statements (CREATE TABLE, ALTER TABLE, DROP TABLE, CREATE INDEX, etc.) against a target database.
- **Why**: Prepare target schema before data migration. Part of the migration lifecycle: DDL first, then data load.
- **How**: Routed through the default mode dispatch. Requires target database connection. Not yet implemented as a standalone mode in the router (returns "unsupported mode"); DDL execution is available within pipeline mode via `sql` steps.
- **Where**: `pkg/types/mode.go` (mode constant), `internal/app/router.go` (dispatch). Functional via pipeline `sql` step in `internal/pipeline/executor_sql.go`.
- **When**: Schema preparation before migration. Use pipeline mode with `sql` steps for DDL until standalone mode is implemented.
- **Who**: DBAs preparing target schemas, automated migration scripts.
- **Parameters**: `--jdbc-url`, `--db-type`, `--db-user`, `--db-password`, `--target-table`
- **Example (via pipeline)**: Create a pipeline YAML with a `sql` step containing the DDL statements.

---

## JSON Operations

### Mode: `json-encapsulate`

- **What**: Encapsulate database query results or dataset records into structured JSON documents (batch, aggregation, metadata patterns).
- **Why**: Transform relational data into JSON structures for API responses, document store ingestion, or event payloads. Supports batch encapsulation with aggregations, metadata headers, and custom DSL-defined structures.
- **How**: Routed through the default mode dispatch. Related functionality is available via the `gen-script --encapsulate` command which generates JavaScript encapsulation code, and via pipeline `transform` steps with many_to_one mode. Not yet implemented as standalone router mode.
- **Where**: `pkg/types/mode.go` (mode constant), `cmd/mass-migrator/gen_script_cmd.go` (gen-script encapsulation), `internal/dsl/` (template engine).
- **When**: Building JSON document feeds from relational data, preparing data for MongoDB/Elasticsearch ingestion, creating API response payloads.
- **Who**: API developers, document store migration teams, data engineers building JSON feeds.
- **Parameters**: `--jdbc-url`, `--db-type`, `--target-table`. Encapsulation templates: json_batch, json_aggregation, json_metadata.
- **Example (gen-script)**: `mass-migrator gen-script --encapsulate json_batch`

---

### Mode: `json-query`

- **What**: Query and extract data from JSON columns or JSON documents stored in database tables using JSON path expressions.
- **Why**: Extract structured data from semi-structured JSON columns during migration. Useful when source data includes JSON blobs that need to be flattened or filtered.
- **How**: Not yet implemented as a standalone router mode. JSON extraction is available through pipeline transform steps using the built-in `jsonParse()`, `jsonExtract()`, and `jsonStringify()` helpers in the JS transform engine.
- **Where**: `pkg/types/mode.go` (mode constant), `internal/transform/helpers_json_xml.go` (JSON helpers).
- **When**: Migrating JSON-heavy schemas, flattening nested JSON into relational columns, filtering records based on JSON field values.
- **Who**: Data engineers working with JSON-heavy databases, NoSQL-to-SQL migration teams.
- **Parameters**: `--jdbc-url`, `--db-type`, `--target-table`, `--source-query`
- **Example (via transform)**: Use pipeline mode with a `transform` step calling `jsonExtract(record.data, '$.address.city')`.

---

## Verification

### Mode: `verify`

- **What**: Verify data integrity between source and target after migration. Compares row counts, checksums, or sample-based validation.
- **Why**: Post-migration validation is critical for data quality assurance. Detects missing rows, data corruption, and transformation errors.
- **How**: Not yet implemented as a standalone router mode. Verification can be achieved through pipeline mode using `query` + `check` steps (e.g., compare counts, checksums).
- **Where**: `pkg/types/mode.go` (mode constant). Functional via pipeline `check` steps in `internal/pipeline/executor_check.go`.
- **When**: After every migration run to validate completeness and correctness. Part of the migration acceptance criteria.
- **Who**: QA engineers, migration project leads, data governance teams.
- **Parameters**: `--source-jdbc-url`, `--source-db-type`, `--jdbc-url` (target), `--target-table`, `--source-query`
- **Example (via pipeline)**: Create a pipeline with query steps on both source and target, followed by a check step comparing counts.

---

## Rule Engine

### Mode: `rule-apply`

- **What**: Apply business rules against database data for validation, transformation, or classification. Rules are defined in CSV format with conditions and expected values.
- **Why**: Enforce data quality rules at scale during migration. Validate that migrated data meets business constraints (e.g., "if product_type = 'LOAN', then rate must be positive").
- **How**: Not yet implemented as a standalone router mode (returns "rule apply not yet implemented"). Requires both source and target database connections per `RequiresSourceDatabase()` and `RequiresTargetDatabase()` predicates. Rule engine infrastructure exists in test fixtures.
- **Where**: `pkg/types/mode.go` (mode constant), `internal/app/router.go` (dispatch stub).
- **When**: Post-migration business rule validation, data quality audits, compliance checks.
- **Who**: Data governance teams, compliance officers, QA engineers validating business logic.
- **Parameters**: `--source-jdbc-url`, `--source-db-type`, `--jdbc-url` (target), `--target-table`
- **Example**: N/A (not yet implemented).

---

# PART 2: CLI Flags

All flags are registered in `cmd/mass-migrator/main.go` lines 123-261 as persistent flags on the root command and bound to viper. Configuration values can also be set via environment variables (prefix `MM_`, e.g., `MM_BATCH_SIZE=100000`) or YAML config file (`--config-file`). Defaults are set in `internal/config/config.go` `SetDefaults()`.

---

## Database Flags

### Flag: `--jdbc-url`

- **What**: Target database JDBC-style connection URL.
- **Why**: Specifies the primary database connection for write operations. All import, migration, DDL, query, and verification modes use this as the target.
- **How**: Parsed by DSN resolver which converts JDBC URLs to Go driver-specific DSNs (e.g., `jdbc:postgresql://host:5432/db` becomes `host=host port=5432 dbname=db`). Also accepts native Go DSN formats and SQLite paths.
- **Where**: `Config.JDBCUrl`, used in `CSVImportOrchestrator.resolveDSN()`, `DbMigrationOrchestrator.ResolveTargetDSN()`, `query_cmd.go`.
- **When**: Required for all modes that write to a database (`RequiresTargetDatabase() == true`).
- **Who**: All database-writing modes.
- **Default**: `""` (empty, required when mode needs target DB)
- **Valid values**: Any JDBC-style URL or native Go DSN. Examples: `jdbc:postgresql://host:5432/db`, `jdbc:mysql://host:3306/db`, `jdbc:oracle:thin:@host:1521/SID`, `jdbc:sqlserver://host:1433;database=db`, `sqlite:./local.db`
- **Modes**: insert-ind, update-ind, merge-ind, upsert-ind, insert, update, merge, upsert, ddl, query, json-encapsulate, json-query, verify, rule-apply, kafka-pull (via pipeline)
- **Example**: `--jdbc-url "jdbc:postgresql://localhost:5432/mydb"`

---

### Flag: `--db-type`

- **What**: Target database type/dialect identifier.
- **Why**: Selects the correct SQL dialect for placeholder syntax, DDL generation, auto-increment detection, MERGE/UPSERT syntax, and type mapping. Required when the JDBC URL alone is ambiguous.
- **How**: Maps to one of 7 dialect implementations via `dialect.NewDialect()`. Controls placeholder style ($1 vs ? vs :p1), identifier quoting, and dialect-specific SQL generation.
- **Where**: `Config.DbType`, used in dialect resolution throughout `internal/dialect/`.
- **When**: Usually auto-detected from JDBC URL prefix, but can be explicitly set to override.
- **Who**: All target-database modes.
- **Default**: `"postgresql"`
- **Valid values**: `postgresql`, `mysql`, `sqlite`, `sqlserver`, `oracle`, `neo4j`, `netezza`
- **Modes**: All modes requiring target database.
- **Example**: `--db-type oracle`

---

### Flag: `--db-user`

- **What**: Target database username for authentication.
- **Why**: Provides credentials separately from the JDBC URL. Useful when the URL is shared in config but credentials are injected from environment/secrets.
- **How**: Injected into the DSN during connection setup. URL-encoded to handle special characters. In query command, injected into parsed URL via `url.UserPassword()`.
- **Where**: `Config.DbUser`, used in DSN resolution.
- **When**: When credentials are not embedded in the JDBC URL.
- **Who**: All target-database modes.
- **Default**: `""` (empty)
- **Valid values**: Any string. Special characters are URL-encoded automatically.
- **Modes**: All modes requiring target database.
- **Example**: `--db-user admin`

---

### Flag: `--db-password`

- **What**: Target database password for authentication. Stored as `SecretString` type to prevent accidental logging.
- **Why**: Secure credential injection separate from the URL. The `SecretString` type redacts the value in log output and serialization.
- **How**: Same as `--db-user`. The `SecretString` type implements `fmt.Stringer` to return `"***"` instead of the actual password.
- **Where**: `Config.DbPassword` (type `SecretString`), used in DSN resolution.
- **When**: When credentials are not embedded in the JDBC URL.
- **Who**: All target-database modes.
- **Default**: `""` (empty)
- **Valid values**: Any string.
- **Modes**: All modes requiring target database.
- **Example**: `--db-password "s3cret!"`

---

### Flag: `--target-jdbc-url`

- **What**: Explicit target database JDBC URL, separate from `--jdbc-url`.
- **Why**: Disambiguates source vs target when both `--jdbc-url` and `--target-jdbc-url` are used. In db-to-db modes, `--jdbc-url` is the primary target; this flag provides an explicit alternative.
- **How**: Checked by `ResolveTargetDSN()` as a fallback if `--jdbc-url` is not set, or as the preferred target URL in db-to-db configurations.
- **Where**: `Config.TargetJDBCUrl`, used in `ResolveTargetDSN()`.
- **When**: When you want to be explicit about which URL is the target in a multi-database configuration.
- **Who**: db-to-db migration modes.
- **Default**: `""` (empty)
- **Valid values**: Same as `--jdbc-url`.
- **Modes**: insert, update, merge, upsert (db-to-db)
- **Example**: `--target-jdbc-url "jdbc:postgresql://target-host:5432/warehouse"`

---

### Flag: `--target-db-type`

- **What**: Explicit target database dialect type.
- **Why**: Override dialect auto-detection for the target database when `--target-jdbc-url` is used separately.
- **How**: Used by `ResolveTargetDSN()` for dialect selection.
- **Where**: `Config.TargetDbType`.
- **When**: When auto-detection is insufficient or you want to force a specific dialect.
- **Who**: db-to-db migration modes.
- **Default**: `""` (empty, falls back to `--db-type`)
- **Valid values**: Same as `--db-type`.
- **Modes**: insert, update, merge, upsert (db-to-db)
- **Example**: `--target-db-type mysql`

---

### Flag: `--target-table`

- **What**: Name of the target database table for write operations.
- **Why**: Specifies where data should be written. Used in INSERT/UPDATE/MERGE/UPSERT SQL generation and auto-create-table DDL.
- **How**: Passed to the strategy constructors (`NewInsertStrategy(dialect, table, columns)`), used in SQL statement construction with proper identifier escaping.
- **Where**: `Config.TargetTable`, used in all write strategies and auto-create logic.
- **When**: Required for all modes that write to a database table.
- **Who**: All database-writing modes.
- **Default**: `""` (empty, required for write modes)
- **Valid values**: Any valid SQL table name. Schema-qualified names supported (e.g., `schema.table`).
- **Modes**: insert-ind, update-ind, merge-ind, upsert-ind, insert, update, merge, upsert, ddl, verify
- **Example**: `--target-table public.users`

---

### Flag: `--columns`

- **What**: Comma-separated list of target column names.
- **Why**: Defines which columns to include in write operations when not using `--csv-mapping` or `--column-mapping`. Controls the column list in generated SQL.
- **How**: Parsed by `parseColumns()` into a `[]string`. When `--csv-mapping` is set, columns are extracted from the mapping instead. Used in strategy constructors and SQL generation.
- **Where**: `Config.Columns`, used in CSVImportOrchestrator and DbMigrationOrchestrator.
- **When**: When column names are the same in source and target and no type mapping is needed.
- **Who**: All import and migration modes.
- **Default**: `""` (empty)
- **Valid values**: Comma-separated column names (e.g., `"id,name,email,created_at"`).
- **Modes**: insert-ind, update-ind, merge-ind, upsert-ind, insert, update, merge, upsert
- **Example**: `--columns "id,name,email,status"`

---

### Flag: `--key-columns`

- **What**: Comma-separated list of key column names used for WHERE clause matching in update/merge/upsert strategies.
- **Why**: Defines the columns used to identify existing rows for UPDATE matching, MERGE/UPSERT conflict resolution. Key columns are excluded from the SET clause in updates.
- **How**: Parsed into `[]string` and passed to `NewUpdateStrategy()`, `NewMergeStrategy()`, `NewUpsertStrategy()`. Used in WHERE clause (UPDATE), ON clause (MERGE), and ON CONFLICT clause (UPSERT).
- **Where**: `Config.KeyColumns`, used in all non-INSERT strategies.
- **When**: Required for update, merge, and upsert modes (both -ind and db-to-db variants).
- **Who**: All update/merge/upsert modes.
- **Default**: `""` (empty, required for update/merge/upsert)
- **Valid values**: Comma-separated column names (e.g., `"id"` or `"account_id,region"`).
- **Modes**: update-ind, merge-ind, upsert-ind, update, merge, upsert
- **Example**: `--key-columns "customer_id"`

---

### Flag: `--source-jdbc-url`

- **What**: Source database JDBC-style connection URL for db-to-db migrations and exports.
- **Why**: Specifies the database to read from in db-to-db and export modes. Separate from the target URL.
- **How**: Parsed by `ResolveSourceDSN()` to create the source connection pool. Converted from JDBC format to Go driver DSN.
- **Where**: `Config.SourceJDBCUrl`, used in `DbMigrationOrchestrator`, `ExportCSVOrchestrator`, `ExportParquetOrchestrator`.
- **When**: Required for all modes where `RequiresSourceDatabase() == true`.
- **Who**: db-to-db modes (insert, update, merge, upsert), export modes (load2csv, load2parquet), kafka-push, rule-apply.
- **Default**: `""` (empty, required for source-database modes)
- **Valid values**: Same format as `--jdbc-url`.
- **Modes**: insert, update, merge, upsert, load2csv, load2parquet, kafka-push, rule-apply
- **Example**: `--source-jdbc-url "jdbc:oracle:thin:@prod-host:1521/ORCL"`

---

### Flag: `--source-db-type`

- **What**: Source database type/dialect identifier.
- **Why**: Selects the correct dialect for source query execution, pagination, and type mapping.
- **How**: Passed to source dialect resolution and connection pool creation.
- **Where**: `Config.SourceDbType`, used in source DSN resolution.
- **When**: When source database type cannot be auto-detected from the URL.
- **Who**: Source-database modes.
- **Default**: `""` (empty, auto-detected from URL)
- **Valid values**: Same as `--db-type`.
- **Modes**: insert, update, merge, upsert, load2csv, load2parquet, kafka-push, rule-apply
- **Example**: `--source-db-type oracle`

---

### Flag: `--source-username`

- **What**: Source database username for authentication.
- **Why**: Provides source database credentials separately from the JDBC URL.
- **How**: Injected into the source DSN during connection setup.
- **Where**: `Config.SourceUsername`, used in `ResolveSourceDSN()`.
- **When**: When source credentials are not embedded in the URL.
- **Who**: Source-database modes.
- **Default**: `""` (empty)
- **Valid values**: Any string.
- **Modes**: insert, update, merge, upsert, load2csv, load2parquet, kafka-push, rule-apply
- **Example**: `--source-username readonly_user`

---

### Flag: `--source-password`

- **What**: Source database password for authentication. Stored as `SecretString` type.
- **Why**: Secure credential injection for source database. Redacted in logs via `SecretString`.
- **How**: Same as `--source-username`. `SecretString` type prevents accidental exposure.
- **Where**: `Config.SourcePassword` (type `SecretString`).
- **When**: When source credentials are not embedded in the URL.
- **Who**: Source-database modes.
- **Default**: `""` (empty)
- **Valid values**: Any string.
- **Modes**: insert, update, merge, upsert, load2csv, load2parquet, kafka-push, rule-apply
- **Example**: `--source-password "r3adOnly!"`

---

### Flag: `--source-query`

- **What**: SQL SELECT query to execute against the source database for data extraction.
- **Why**: Defines what data to read from the source. Supports arbitrary SQL including JOINs, WHERE clauses, aggregations, and subqueries.
- **How**: Executed against the source connection pool. For db-to-db modes, results are streamed through cursor-based fetch (controlled by `--fetch-size`). For exports, results are written directly to file. `DynamicSqlBuilder` can inject group predicates and partition filters.
- **Where**: `Config.SourceQuery`, used in `DbMigrationOrchestrator`, `ExportCSVOrchestrator`, `ExportParquetOrchestrator`.
- **When**: Required for db-to-db and export modes. The query defines the data scope.
- **Who**: All source-database modes.
- **Default**: `""` (empty, required for source modes)
- **Valid values**: Any valid SQL SELECT statement for the source database dialect.
- **Modes**: insert, update, merge, upsert, load2csv, load2parquet, kafka-push, rule-apply
- **Example**: `--source-query "SELECT id, name, email FROM users WHERE active = 1 ORDER BY id"`

---

### Flag: `--source-table`

- **What**: Source table name (shorthand for simple `SELECT * FROM table` queries).
- **Why**: Convenience when the source query is a simple full-table select. Avoids writing `--source-query "SELECT * FROM table"`.
- **How**: Used to construct a simple SELECT query when `--source-query` is not provided.
- **Where**: `Config.SourceTable`.
- **When**: Simple db-to-db migrations where you want all columns from a source table.
- **Who**: Source-database modes.
- **Default**: `""` (empty)
- **Valid values**: Any valid table name.
- **Modes**: insert, update, merge, upsert, load2csv, load2parquet
- **Example**: `--source-table customers`

---

## Performance Flags

### Flag: `--batch-size`

- **What**: Number of records per database write batch.
- **Why**: Controls the trade-off between memory usage and write throughput. Larger batches mean fewer round-trips and higher TPS, but more memory per batch. Also controls the producer-consumer queue batch size in CSV import.
- **How**: Passed to orchestrators, which use it to cap the number of records collected before calling `strategy.ExecuteBatch()`. The strategy then further chunks into multi-row SQL statements (e.g., InsertStrategy.BatchSize = 2000 rows per INSERT). This flag controls the outer batch; the strategy's internal batch controls SQL statement size.
- **Where**: `Config.BatchSize`, used in `CSVImportOrchestrator`, `DbMigrationOrchestrator`, `ParquetGeneratorOrchestrator`, pipeline `LoadStep` executor.
- **When**: Tune when import is slow (increase) or running out of memory (decrease). The default of 50000 is good for most cases.
- **Who**: All modes that write to databases or generate data.
- **Default**: `50000`
- **Valid values**: 1 to 1,000,000 (practical range). Values above 500,000 may cause memory pressure.
- **Modes**: insert-ind, update-ind, merge-ind, upsert-ind, insert, update, merge, upsert, genparquet, pipeline (load step)
- **Example**: `--batch-size 100000`

---

### Flag: `--threads`

- **What**: Number of parallel worker goroutines for data processing.
- **Why**: Controls parallelism for database writes, reads, and transforms. More threads increase throughput on multi-core systems with fast I/O, but too many can overwhelm the database with connections.
- **How**: Sets `MaxOpenConns` and `MaxIdleConns` on the connection pool, and controls the number of writer goroutines in the producer-consumer pipeline. Each worker gets its own database connection from the pool.
- **Where**: `Config.Threads`, used in connection pool config, CSVImportOrchestrator worker count, DbMigrationOrchestrator worker count, pipeline step executors.
- **When**: Increase for high-throughput imports on powerful databases. Decrease for SQLite (forced to 1) or under-provisioned databases.
- **Who**: All modes that interact with databases.
- **Default**: `4`
- **Valid values**: 1 to 64 (practical range). SQLite ignores this (always 1).
- **Modes**: All database modes, genparquet, pipeline steps with threads config.
- **Example**: `--threads 8`

---

### Flag: `--queue-size`

- **What**: Size of the in-memory queue between producer (reader) and consumer (writer) goroutines.
- **Why**: Buffers records between the reading and writing phases of the pipeline. Larger queues absorb read/write speed differences but use more memory. Prevents the reader from blocking when writers are slow.
- **How**: Sets the channel buffer size in the producer-consumer pipeline used by CSV import and db-to-db migration.
- **Where**: `Config.QueueSize`, used in orchestrator pipeline setup.
- **When**: Increase if the reader is much faster than writers (e.g., fast SSD read, slow network write). Decrease if memory is constrained.
- **Who**: Import and migration modes.
- **Default**: `10000`
- **Valid values**: 100 to 1,000,000.
- **Modes**: insert-ind, update-ind, merge-ind, upsert-ind, insert, update, merge, upsert
- **Example**: `--queue-size 50000`

---

### Flag: `--fetch-size`

- **What**: Number of rows to fetch per database round-trip from the source database.
- **Why**: Controls cursor-based streaming from the source. Larger fetch sizes reduce round-trips but increase memory per fetch. Critical for large source queries to avoid loading all results into memory.
- **How**: Passed to the source database query execution as a cursor hint. Behavior varies by driver: PostgreSQL uses `SET statement_timeout` and cursor-based fetching; Oracle uses `prefetch_rows`.
- **Where**: `Config.FetchSize`, used in source query execution.
- **When**: Tune for large source queries. Increase for fast networks, decrease for limited memory.
- **Who**: db-to-db and export modes.
- **Default**: `10000`
- **Valid values**: 100 to 1,000,000.
- **Modes**: insert, update, merge, upsert, load2csv, load2parquet
- **Example**: `--fetch-size 50000`

---

## CSV / File Processing Flags

### Flag: `--input-file`

- **What**: Path to the input file (CSV or Parquet) for file import modes.
- **Why**: Specifies the data source for file-to-database import. File format is auto-detected by extension (`.parquet`/`.pqt` = Parquet, everything else = CSV).
- **How**: Passed to `openReader()` which creates either `reader.NewCSVReader()` or `reader.NewParquetReader()` based on extension. Supports absolute and relative paths.
- **Where**: `Config.InputFile`, used in `CSVImportOrchestrator.processFile()`.
- **When**: Required for all file import modes (insert-ind, update-ind, merge-ind, upsert-ind).
- **Who**: File import modes.
- **Default**: `""` (empty, required for import modes)
- **Valid values**: Any valid file path. Supports `.csv`, `.tsv`, `.txt`, `.parquet`, `.pqt`.
- **Modes**: insert-ind, update-ind, merge-ind, upsert-ind
- **Example**: `--input-file /data/exports/users.csv`

---

### Flag: `--output-file`

- **What**: Generic output file path, used as a fallback when mode-specific output paths are not set.
- **Why**: Provides a single flag for output across modes. Mode-specific flags (`--output-csv-path`, `--output-parquet-path`) take priority.
- **How**: Checked by `Config.GetOutputPath()` as the last fallback after `OutputCsvPath` and `OutputParquetPath`.
- **Where**: `Config.OutputFile`, used in `GetOutputPath()`.
- **When**: When you prefer a single generic output flag regardless of format.
- **Who**: Export and generation modes.
- **Default**: `""` (empty)
- **Valid values**: Any valid file path.
- **Modes**: gencsv, genparquet, load2csv, load2parquet
- **Example**: `--output-file /data/output/result.csv`

---

### Flag: `--delimiter`

- **What**: CSV field delimiter character.
- **Why**: Supports non-comma delimiters for TSV files, pipe-delimited files, and other formats.
- **How**: First character of the string is used as the `rune` delimiter for both CSV reader and writer. Applied to `csv.Reader.Comma` and `csv.Writer.Comma`.
- **Where**: `Config.Delimiter`, used in CSV readers, writers, and generators.
- **When**: When input or output files use non-comma delimiters.
- **Who**: All CSV modes.
- **Default**: `","` (comma)
- **Valid values**: Any single character. Common: `","`, `"\t"` (tab), `"|"` (pipe), `";"` (semicolon).
- **Modes**: insert-ind, update-ind, merge-ind, upsert-ind, gencsv, load2csv
- **Example**: `--delimiter "|"`

---

### Flag: `--has-header`

- **What**: Whether the input CSV file has a header row.
- **Why**: Controls whether the first row is treated as column names (skipped for data) or as data.
- **How**: Passed to `openReader()` and the CSV reader, which either reads and stores the first row as headers or treats it as data. Works in conjunction with `--csv-skip-header` via `EffectiveHasHeader()`.
- **Where**: `Config.HasHeader`, used in reader initialization.
- **When**: Set to `false` for headerless CSV files.
- **Who**: File import modes.
- **Default**: `true`
- **Valid values**: `true`, `false`
- **Modes**: insert-ind, update-ind, merge-ind, upsert-ind
- **Example**: `--has-header=false`

---

### Flag: `--csv-skip-header`

- **What**: Skip the CSV header row during import (alternate semantics to `--has-header`).
- **Why**: More intuitive name for some users. When `true`, it means "there IS a header row to skip" (effectively `has-header=true`).
- **How**: Checked by `Config.EffectiveHasHeader()`. If `csv-skip-header` is true, the effective has-header is true (there is a header to skip).
- **Where**: `Config.CsvSkipHeader`, used in `EffectiveHasHeader()`.
- **When**: Alternative to `--has-header` when the semantics of "skip" are clearer.
- **Who**: File import modes.
- **Default**: `false`
- **Valid values**: `true`, `false`
- **Modes**: insert-ind, update-ind, merge-ind, upsert-ind
- **Example**: `--csv-skip-header`

---

### Flag: `--csv-quote`

- **What**: CSV quote character for fields containing delimiters or newlines.
- **Why**: Override the default double-quote for CSV files that use a different quoting convention.
- **How**: Passed to the CSV reader configuration.
- **Where**: `Config.CsvQuote`, used in CSV reader setup.
- **When**: When CSV files use non-standard quoting (e.g., single quotes).
- **Who**: File import modes.
- **Default**: `"\"" `(double quote)
- **Valid values**: Any single character.
- **Modes**: insert-ind, update-ind, merge-ind, upsert-ind
- **Example**: `--csv-quote "'"`

---

### Flag: `--csv-escape`

- **What**: CSV escape character for escaping the quote character within quoted fields.
- **Why**: Override the default backslash escape for CSV files with different escape conventions.
- **How**: Passed to the CSV reader configuration.
- **Where**: `Config.CsvEscape`, used in CSV reader setup.
- **When**: When CSV files use non-standard escape characters.
- **Who**: File import modes.
- **Default**: `"\\"` (backslash)
- **Valid values**: Any single character.
- **Modes**: insert-ind, update-ind, merge-ind, upsert-ind
- **Example**: `--csv-escape "\\\\"`

---

### Flag: `--csv-mapping`

- **What**: Column mapping from CSV columns to database columns with type information. Format: `csvCol:dbCol:TYPE,...`
- **Why**: Maps CSV header names to database column names with explicit SQL types. Required for auto-create-table and type-aware data conversion. Allows CSV columns to have different names than database columns.
- **How**: Parsed by `parseCsvMapping()` into parallel slices of CSV column names, database column names, and SQL types. Types are validated against `safeSQLTypePattern` to prevent SQL injection. When `--columns` is empty, database columns are extracted from the mapping.
- **Where**: `Config.CsvMapping`, used in `CSVImportOrchestrator`, auto-table creation, record mapping.
- **When**: Import modes when CSV headers differ from DB columns, or when type information is needed for auto-create.
- **Who**: File import modes.
- **Default**: `""` (empty)
- **Valid values**: Comma-separated triplets: `csvCol:dbCol:TYPE`. Examples: `"id:user_id:BIGINT,name:full_name:VARCHAR(100),ts:created_at:TIMESTAMP"`.
- **Modes**: insert-ind, update-ind, merge-ind, upsert-ind
- **Example**: `--csv-mapping "id:id:BIGINT,name:name:VARCHAR(255),amount:amount:DECIMAL(12,2)"`

---

### Flag: `--csv-file-pattern`

- **What**: File path pattern with `{group}` placeholder for multi-file CSV import.
- **Why**: Process multiple CSV files in one run, each corresponding to a group value (e.g., one file per region, per date, per partition).
- **How**: Used with `--group-values` and `--group-columns`. For each group value, the `{groupColumn}` placeholder in the pattern is replaced with the value. If a file does not exist, it is skipped with a warning.
- **Where**: `Config.CsvFilePattern`, used in `CSVImportOrchestrator.runMultiFile()`.
- **When**: When data is split across multiple files by a grouping key (e.g., `data_{region}.csv`).
- **Who**: File import modes with partitioned data.
- **Default**: `""` (empty)
- **Valid values**: File path with placeholder. Example: `/data/exports/users_{region}.csv`.
- **Modes**: insert-ind, update-ind, merge-ind, upsert-ind
- **Example**: `--csv-file-pattern "/data/region_{region}/data.csv" --group-columns region --group-values "US,EU,APAC"`

---

## Table Management Flags

### Flag: `--auto-create-table`

- **What**: Automatically create the target table if it does not exist, using column types from `--csv-mapping`.
- **Why**: Eliminates the need for separate DDL scripts. Creates the table with columns and types derived from the CSV mapping. Useful for quick prototyping and testing.
- **How**: Before processing any files, `CSVImportOrchestrator.autoCreateTable()` checks if the table exists, and if not, generates a `CREATE TABLE` statement from the CSV mapping types. Column types are validated against `safeSQLTypePattern` to prevent injection.
- **Where**: `Config.AutoCreateTable`, used in `CSVImportOrchestrator.Run()`.
- **When**: For initial setup of target tables, prototyping, or CI/CD environments.
- **Who**: File import modes with CSV mapping.
- **Default**: `false`
- **Valid values**: `true`, `false`
- **Modes**: insert-ind, update-ind, merge-ind, upsert-ind
- **Example**: `--auto-create-table --csv-mapping "id:id:BIGINT,name:name:VARCHAR(255)"`

---

### Flag: `--force-recreate`

- **What**: Drop and recreate the target table before import.
- **Why**: Ensures a clean slate for each import run. Useful in development/testing when you want to reset the table. Destructive by design.
- **How**: If enabled and auto-create-table is also enabled, drops the existing table before creating a new one.
- **Where**: `Config.ForceRecreate`, used in auto-create logic.
- **When**: Development and testing only. Never use in production without explicit intent.
- **Who**: File import modes during development.
- **Default**: `false`
- **Valid values**: `true`, `false`
- **Modes**: insert-ind, update-ind, merge-ind, upsert-ind (with `--auto-create-table`)
- **Example**: `--force-recreate --auto-create-table`

---

## Transform Flags

### Flag: `--transform-script`

- **What**: Path to a JavaScript transform script applied to each record during import.
- **Why**: Apply business logic, data cleansing, format conversion, or enrichment during import without pre-processing files. The goja JS engine provides 100+ built-in helper functions.
- **How**: Loaded by `transform.NewTransformEngine()`, compiled once, and executed for each record (or batch, depending on mode). The script receives a `record` object with column values and must return the modified record (ONE_TO_ONE), an array of records (ONE_TO_MANY), or an accumulated result (MANY_TO_ONE, MANY_TO_MANY).
- **Where**: `Config.TransformScript`, used in `CSVImportOrchestrator`, pipeline `transform` steps.
- **When**: When data needs transformation during import (type conversion, value mapping, string formatting, date parsing, etc.).
- **Who**: File import modes with data transformation requirements.
- **Default**: `""` (empty, no transform)
- **Valid values**: Path to a `.js` file. The script has access to all 100+ transform helpers (string, date, math, JSON, validation, masking, window functions).
- **Modes**: insert-ind, update-ind, merge-ind, upsert-ind
- **Example**: `--transform-script transforms/clean_users.js`

---

### Flag: `--transform-mode`

- **What**: Transform cardinality mode controlling input/output record relationship.
- **Why**: Different transformations have different cardinalities: one record in = one record out (cleaning), one in = many out (exploding), many in = one out (aggregating), many in = many out (complex).
- **How**: Passed to `transform.NewTransformEngine()`. Controls how the engine invokes the script and collects results.
- **Where**: `Config.TransformMode`, used in transform engine initialization.
- **When**: When the transform needs to change the number of records (default ONE_TO_ONE handles most cases).
- **Who**: File import modes with non-1:1 transformations.
- **Default**: `"ONE_TO_ONE"`
- **Valid values**: `ONE_TO_ONE`, `ONE_TO_MANY`, `MANY_TO_ONE`, `MANY_TO_MANY`
- **Modes**: insert-ind, update-ind, merge-ind, upsert-ind
- **Example**: `--transform-mode ONE_TO_MANY`

---

## Data Generation Flags

### Flag: `--record-count`

- **What**: Number of records to generate in gencsv/genparquet modes.
- **Why**: Controls the size of the generated dataset. Determines how many rows the generator produces.
- **How**: Used as the loop bound in CSV and Parquet generators. Must be positive.
- **Where**: `Config.RecordCount`, used in `CSVGeneratorOrchestrator.Run()`, `ParquetGeneratorOrchestrator.Run()`.
- **When**: Required for generation modes.
- **Who**: gencsv, genparquet modes.
- **Default**: `0` (must be explicitly set)
- **Valid values**: 1 to 2^63-1 (int64). Practical range: 1 to 100,000,000.
- **Modes**: gencsv, genparquet
- **Example**: `--record-count 1000000`

---

### Flag: `--column-definitions`

- **What**: DSL string defining column names, types, and distribution parameters for data generation.
- **Why**: Specifies the schema and data characteristics of generated test data. Supports typed columns with configurable distributions.
- **How**: Parsed by `generator.ParseColumnDefinitions()` into a slice of `ColumnDef` structs. Format: `name:TYPE[:DISTRIBUTION[:min:max[:precision]]]`. Supported types: BIGINT, INT, STRING, VARCHAR, DECIMAL, FLOAT, DOUBLE, BOOLEAN, DATE, TIMESTAMP, UUID. Distributions: RANDOM (default), SEQUENTIAL, GAUSSIAN, ZIPF.
- **Where**: `Config.ColumnDefinitions`, used in both generator orchestrators.
- **When**: Required for gencsv and genparquet modes.
- **Who**: gencsv, genparquet modes.
- **Default**: `""` (empty, required for generation)
- **Valid values**: Comma-separated column definitions. Examples: `"id:BIGINT:SEQUENTIAL:1:1000000"`, `"name:STRING"`, `"amount:DECIMAL:RANDOM:0:10000:2"`, `"ts:TIMESTAMP"`.
- **Modes**: gencsv, genparquet
- **Example**: `--column-definitions "id:BIGINT:SEQUENTIAL:1:999999,name:STRING,amount:DECIMAL:GAUSSIAN:0:10000:2,created_at:TIMESTAMP"`

---

### Flag: `--seed`

- **What**: Random seed for reproducible data generation.
- **Why**: Ensures identical output across runs for the same seed, enabling deterministic test data generation for CI/CD and regression testing.
- **How**: Passed to `rand.NewSource(seed)`. If 0, uses `time.Now().UnixNano()` for non-deterministic generation.
- **Where**: `Config.Seed`, used in both generator orchestrators.
- **When**: When reproducible test data is required.
- **Who**: gencsv, genparquet modes.
- **Default**: `0` (non-deterministic)
- **Valid values**: Any int64.
- **Modes**: gencsv, genparquet
- **Example**: `--seed 42`

---

### Flag: `--output-csv-path`

- **What**: Output file path specifically for CSV generation and export.
- **Why**: Mode-specific output path that takes priority over `--output-file` for CSV operations.
- **How**: Checked first by `Config.GetOutputPath()` before falling back to `OutputFile`.
- **Where**: `Config.OutputCsvPath`, used in `GetOutputPath()`, CSV generator, CSV export.
- **When**: For gencsv and load2csv modes.
- **Who**: gencsv, load2csv modes.
- **Default**: `""` (empty)
- **Valid values**: Any valid file path ending in `.csv` (or any extension).
- **Modes**: gencsv, load2csv
- **Example**: `--output-csv-path /data/output/test_data.csv`

---

### Flag: `--csv-include-header`

- **What**: Whether to include a header row in generated CSV output.
- **Why**: Some downstream systems require headers; others do not.
- **How**: When true, the CSV generator writes column names as the first row before data rows.
- **Where**: `Config.CsvIncludeHeader`, used in `CSVGeneratorOrchestrator.Run()`.
- **When**: Set to `false` when generating headerless CSV files.
- **Who**: gencsv mode.
- **Default**: `true`
- **Valid values**: `true`, `false`
- **Modes**: gencsv
- **Example**: `--csv-include-header=false`

---

## Group Processing Flags

### Flag: `--group-columns`

- **What**: Column name(s) used for group-based processing and file splitting.
- **Why**: Enables partitioned processing where data is filtered or split by a grouping column (e.g., region, date, tenant_id).
- **How**: Used in conjunction with `--group-values`. For exports, injects WHERE clause predicates via `DynamicSqlBuilder`. For imports, substitutes placeholders in `--csv-file-pattern`.
- **Where**: `Config.GroupColumns`, used in export orchestrators and multi-file import.
- **When**: When processing data by partitions/groups.
- **Who**: Export and import modes with partitioned data.
- **Default**: `""` (empty)
- **Valid values**: Comma-separated column names (e.g., `"region"` or `"year,month"`).
- **Modes**: load2csv, load2parquet, insert-ind (multi-file), update-ind, merge-ind, upsert-ind
- **Example**: `--group-columns "region"`

---

### Flag: `--group-values`

- **What**: Comma-separated group values to process.
- **Why**: Defines which group partitions to process. Each value generates a separate query (for exports) or maps to a separate file (for imports).
- **How**: Parsed into a `[]string` and iterated. For exports, each value is substituted into the source query via `DynamicSqlBuilder`. For imports, substituted into `--csv-file-pattern`.
- **Where**: `Config.GroupValues`, used in export and import orchestrators.
- **When**: When processing specific partitions.
- **Who**: Export and import modes with partitioned data.
- **Default**: `""` (empty)
- **Valid values**: Comma-separated values matching the group column (e.g., `"US,EU,APAC"`).
- **Modes**: load2csv, load2parquet, insert-ind (multi-file), update-ind, merge-ind, upsert-ind
- **Example**: `--group-values "US,EU,APAC,LATAM"`

---

### Flag: `--group-query`

- **What**: SQL query to dynamically fetch group values from a database.
- **Why**: When group values are not known in advance, this query retrieves them dynamically (e.g., `SELECT DISTINCT region FROM customers`).
- **How**: Executed against the source database to populate the group values list before processing.
- **Where**: `Config.GroupQuery`.
- **When**: When group values should be dynamically determined.
- **Who**: Export and import modes with dynamic groups.
- **Default**: `""` (empty)
- **Valid values**: Any SQL SELECT returning a single column of group values.
- **Modes**: load2csv, load2parquet, insert-ind (multi-file)
- **Example**: `--group-query "SELECT DISTINCT region FROM customers ORDER BY region"`

---

### Flag: `--group-table`

- **What**: Control table name for group management and tracking.
- **Why**: Enables stateful group processing where a control table tracks which groups have been processed, enabling resume and progress tracking.
- **How**: Used for group state management.
- **Where**: `Config.GroupTable`.
- **When**: For large partitioned migrations requiring resume capability.
- **Who**: Import and export modes with state management.
- **Default**: `""` (empty)
- **Valid values**: Any valid table name.
- **Modes**: Import and export modes with groups.
- **Example**: `--group-table migration_group_status`

---

### Flag: `--group-range-start`

- **What**: Start value for numeric range-based group filtering.
- **Why**: Process a numeric range of groups (e.g., customer IDs 1-10000) without enumerating each value.
- **How**: Used with `--group-range-end` to generate a sequence of numeric group values.
- **Where**: `Config.GroupRangeStart`.
- **When**: When groups are numeric ranges rather than discrete values.
- **Who**: Import and export modes with numeric group ranges.
- **Default**: `0`
- **Valid values**: Any int64.
- **Modes**: Import and export modes with numeric groups.
- **Example**: `--group-range-start 1`

---

### Flag: `--group-range-end`

- **What**: End value for numeric range-based group filtering.
- **Why**: Defines the upper bound of the numeric group range.
- **How**: Used with `--group-range-start`.
- **Where**: `Config.GroupRangeEnd`.
- **When**: When groups are numeric ranges.
- **Who**: Import and export modes with numeric group ranges.
- **Default**: `0`
- **Valid values**: Any int64 greater than or equal to `group-range-start`.
- **Modes**: Import and export modes with numeric groups.
- **Example**: `--group-range-end 10000`

---

### Flag: `--split-output-by-group`

- **What**: Create separate output files for each group value during export.
- **Why**: Produces one file per group for parallel downstream processing, partition-aligned storage, or per-tenant data delivery.
- **How**: When enabled, the export orchestrator iterates over group values and creates a separate output file for each, with the group value substituted into the output path.
- **Where**: `Config.SplitOutputByGroup`, used in `ExportCSVOrchestrator`, `ExportParquetOrchestrator`.
- **When**: When per-group file output is required.
- **Who**: Export modes.
- **Default**: `false`
- **Valid values**: `true`, `false`
- **Modes**: load2csv, load2parquet
- **Example**: `--split-output-by-group --group-columns "region" --group-values "US,EU"`

---

### Flag: `--enable-group-placeholders`

- **What**: Enable `${group}` placeholder substitution in SQL queries and file paths.
- **Why**: Allows group values to be injected into arbitrary positions in queries and paths using placeholder syntax.
- **How**: When enabled, the `${group}` placeholder in source queries and file patterns is replaced with the current group value.
- **Where**: `Config.EnableGroupPlaceholders`.
- **When**: When group values need to appear in custom positions in SQL or file paths.
- **Who**: Export and import modes with group processing.
- **Default**: `false`
- **Valid values**: `true`, `false`
- **Modes**: load2csv, load2parquet, insert-ind (multi-file)
- **Example**: `--enable-group-placeholders --source-query "SELECT * FROM data WHERE partition_key = '\${group}'"`

---

## Static Column Flags

### Flag: `--static-update-columns`

- **What**: Comma-separated list of extra constant columns to inject into every record during import or migration.
- **Why**: Add metadata columns (e.g., `load_date`, `source_system`, `batch_id`) without modifying the source data. Supports 3-level evaluation: SQL literals (e.g., `CURRENT_TIMESTAMP`), dialect functions, and record expressions.
- **How**: Parsed into a `[]string` and paired with `--static-update-values`. Classified by the dialect's `ClassifyStaticValue()` into SQL literals (injected into SQL), function calls (executed by dialect), or record-level expressions (evaluated per row via `RecordEvaluator`). Forms a `CompositeGroup` in the strategy.
- **Where**: `Config.StaticUpdateColumns`, used in `CSVImportOrchestrator`, `DbMigrationOrchestrator`.
- **When**: Adding audit columns, batch identifiers, or constant values during import.
- **Who**: Import and migration modes.
- **Default**: `""` (empty)
- **Valid values**: Comma-separated column names. Must match count of `--static-update-values`.
- **Modes**: insert-ind, update-ind, merge-ind, upsert-ind, insert, update, merge, upsert
- **Example**: `--static-update-columns "load_date,source_system" --static-update-values "CURRENT_TIMESTAMP,LEGACY_ERP"`

---

### Flag: `--static-update-values`

- **What**: Comma-separated values for static update columns.
- **Why**: Provides the constant values to inject for each static column. Supports SQL literals, dialect functions, and literal strings.
- **How**: Paired 1:1 with `--static-update-columns`. Each value is classified by the dialect: `CURRENT_TIMESTAMP`, `SYSDATE`, `NOW()` are SQL functions; quoted strings are literals; others may be record expressions.
- **Where**: `Config.StaticUpdateValues`, used alongside `StaticUpdateColumns`.
- **When**: Always used with `--static-update-columns`.
- **Who**: Import and migration modes.
- **Default**: `""` (empty)
- **Valid values**: Comma-separated values. Must match count of `--static-update-columns`.
- **Modes**: insert-ind, update-ind, merge-ind, upsert-ind, insert, update, merge, upsert
- **Example**: `--static-update-values "CURRENT_TIMESTAMP,LEGACY_ERP"`

---

## Column Mapping Flags

### Flag: `--column-mapping`

- **What**: Column mapping for db-to-db migrations. Format: `srcCol:tgtCol:TYPE,...`
- **Why**: Maps source column names to different target column names with explicit type information. Required when source and target schemas have different column names.
- **How**: Parsed by `parseColumnMapping()` into parallel slices of source and target column names. Source columns are used in the SELECT list; target columns are used in the INSERT/UPDATE.
- **Where**: `Config.ColumnMapping`, used in `DbMigrationOrchestrator`.
- **When**: When source and target column names differ, or when explicit type mapping is needed.
- **Who**: db-to-db migration modes.
- **Default**: `""` (empty)
- **Valid values**: Comma-separated triplets: `srcCol:tgtCol:TYPE`. Example: `"user_id:id:BIGINT,full_name:name:VARCHAR"`.
- **Modes**: insert, update, merge, upsert
- **Example**: `--column-mapping "user_id:id:BIGINT,full_name:name:VARCHAR(255),email_addr:email:VARCHAR(320)"`

---

## Parquet Flags

### Flag: `--output-parquet-path`

- **What**: Output file path specifically for Parquet generation and export.
- **Why**: Mode-specific output path for Parquet operations. Takes priority over `--output-file` in `GetOutputPath()`.
- **How**: Checked by `Config.GetOutputPath()` after `OutputCsvPath`.
- **Where**: `Config.OutputParquetPath`, used in `GetOutputPath()`, Parquet generator, Parquet export.
- **When**: For genparquet and load2parquet modes.
- **Who**: genparquet, load2parquet modes.
- **Default**: `""` (empty)
- **Valid values**: Any valid file path, typically ending in `.parquet`.
- **Modes**: genparquet, load2parquet
- **Example**: `--output-parquet-path /data/output/fact_sales.parquet`

---

### Flag: `--parquet-compression`

- **What**: Compression algorithm for Parquet output files.
- **Why**: Controls the compression/speed trade-off for Parquet files. SNAPPY is fastest; ZSTD offers best compression; GZIP for compatibility.
- **How**: Passed to `writer.NewParquetWriter()` via `ParquetWriterConfig.Compression`.
- **Where**: `Config.ParquetCompression`, used in Parquet writers.
- **When**: Tune based on downstream requirements: SNAPPY for speed, ZSTD for size, GZIP for compatibility.
- **Who**: genparquet, load2parquet modes.
- **Default**: `"SNAPPY"`
- **Valid values**: `SNAPPY`, `GZIP`, `LZ4`, `ZSTD`, `NONE`
- **Modes**: genparquet, load2parquet, pipeline (write step with format: parquet)
- **Example**: `--parquet-compression ZSTD`

---

### Flag: `--parquet-row-group-size`

- **What**: Row group size in bytes for Parquet output files.
- **Why**: Controls the granularity of Parquet row groups. Larger row groups improve compression and sequential read performance; smaller row groups improve random access and predicate pushdown.
- **How**: Passed to `writer.NewParquetWriter()` via `ParquetWriterConfig.RowGroupSize`.
- **Where**: `Config.ParquetRowGroupSize`, used in Parquet writers.
- **When**: Tune for query patterns: larger for sequential scans, smaller for filtered/selective queries.
- **Who**: genparquet, load2parquet modes.
- **Default**: `268435456` (256 MB)
- **Valid values**: 1048576 (1 MB) to 1073741824 (1 GB). Default 256 MB is good for most analytical workloads.
- **Modes**: genparquet, load2parquet, pipeline (write step with format: parquet)
- **Example**: `--parquet-row-group-size 134217728` (128 MB)

---

## Metrics and Progress Flags

### Flag: `--enable-tps-metrics`

- **What**: Enable transactions-per-second (TPS) metrics reporting during import and migration.
- **Why**: Monitor import throughput in real-time. Reports current TPS, total records, and elapsed time to stderr at regular intervals.
- **How**: When enabled, initializes `startTime` and `totalRecords` counters. Worker goroutines atomically increment counters. A reporting goroutine periodically calculates and prints TPS.
- **Where**: `Config.EnableTpsMetrics`, used in `CSVImportOrchestrator`, `DbMigrationOrchestrator`.
- **When**: During performance tuning, production monitoring, or benchmarking.
- **Who**: Import and migration modes.
- **Default**: `false`
- **Valid values**: `true`, `false`
- **Modes**: insert-ind, update-ind, merge-ind, upsert-ind, insert, update, merge, upsert
- **Example**: `--enable-tps-metrics`

---

### Flag: `--import-enable-detailed-progress`

- **What**: Enable detailed per-batch progress reporting during import.
- **Why**: Provides granular progress information including records processed, batch completion times, and file progress percentage.
- **How**: Enables per-batch reporting at the interval specified by `--import-progress-report-interval`.
- **Where**: `Config.ImportEnableDetailedProgress`, used in import orchestrators.
- **When**: When you need fine-grained visibility into import progress.
- **Who**: Import modes.
- **Default**: `false`
- **Valid values**: `true`, `false`
- **Modes**: insert-ind, update-ind, merge-ind, upsert-ind
- **Example**: `--import-enable-detailed-progress`

---

### Flag: `--import-progress-report-interval`

- **What**: Interval in seconds between progress report messages during import.
- **Why**: Controls how frequently progress is reported to stderr. Lower values give more frequent updates but more log noise.
- **How**: Used as the timer interval for the progress reporting goroutine.
- **Where**: `Config.ImportProgressReportInterval`, used in import orchestrators.
- **When**: Adjust based on how much progress visibility you want.
- **Who**: Import modes with detailed progress enabled.
- **Default**: `5` (seconds)
- **Valid values**: 1 to 3600.
- **Modes**: insert-ind, update-ind, merge-ind, upsert-ind (with `--import-enable-detailed-progress`)
- **Example**: `--import-progress-report-interval 10`

---

## State Management Flags

### Flag: `--enable-state-management`

- **What**: Enable state tracking for resume/restart capability.
- **Why**: For long-running migrations, state management allows resuming from the last successfully processed batch after a failure, avoiding re-processing of already-committed data.
- **How**: When enabled, tracks the last successfully committed batch/offset. On restart, reads the state and skips already-processed records.
- **Where**: `Config.EnableStateManagement`, used in import orchestrators.
- **When**: For large migrations where restart cost is high.
- **Who**: Import and migration modes.
- **Default**: `false`
- **Valid values**: `true`, `false`
- **Modes**: insert-ind, update-ind, merge-ind, upsert-ind, insert, update, merge, upsert
- **Example**: `--enable-state-management`

---

## Error Handling Flags

### Flag: `--max-retry-attempts`

- **What**: Maximum number of retry attempts for failed batch writes.
- **Why**: Transient database errors (connection resets, deadlocks, lock timeouts) can be recovered by retrying. Configures the retry helper's maximum attempts.
- **How**: Passed to `recovery.RetryHelper` via `RetryConfig.MaxAttempts`. Each batch write is wrapped in a retry loop with exponential backoff.
- **Where**: `Config.MaxRetryAttempts`, used in `CSVImportOrchestrator`, `DbMigrationOrchestrator`.
- **When**: Adjust based on database stability. Increase for flaky networks, decrease for fail-fast scenarios.
- **Who**: Import and migration modes.
- **Default**: `3`
- **Valid values**: 0 (no retries) to 10.
- **Modes**: insert-ind, update-ind, merge-ind, upsert-ind, insert, update, merge, upsert
- **Example**: `--max-retry-attempts 5`

---

### Flag: `--max-allowed-errors`

- **What**: Maximum number of batch errors allowed before the overall import is aborted.
- **Why**: Allows some batches to fail (e.g., constraint violations on specific rows) while continuing the overall import. Zero means unlimited errors are tolerated (unless fail-fast is on).
- **How**: Tracked by `recovery.ErrorTracker`. After each batch error, checks if the error count exceeds the threshold. If so, aborts the import.
- **Where**: `Config.MaxAllowedErrors`, used in `recovery.NewErrorTracker()`.
- **When**: When some data quality issues are expected and you want to continue importing valid data.
- **Who**: Import and migration modes.
- **Default**: `0` (unlimited)
- **Valid values**: 0 (unlimited) to any positive integer.
- **Modes**: insert-ind, update-ind, merge-ind, upsert-ind, insert, update, merge, upsert
- **Example**: `--max-allowed-errors 100`

---

### Flag: `--fail-fast-mode`

- **What**: Stop the entire import on the first batch error.
- **Why**: For critical migrations where any data loss is unacceptable. Ensures the first error is immediately visible and no further writes occur.
- **How**: Sets `FailFast` on the `ErrorTracker`. When any worker encounters an error, the tracker signals all workers to stop.
- **Where**: `Config.FailFastMode`, used in `recovery.NewErrorTracker()`.
- **When**: Production migrations where data integrity is paramount.
- **Who**: Import and migration modes.
- **Default**: `false`
- **Valid values**: `true`, `false`
- **Modes**: insert-ind, update-ind, merge-ind, upsert-ind, insert, update, merge, upsert
- **Example**: `--fail-fast-mode`

---

## Debug Flags

### Flag: `--dry-run`

- **What**: Execute all processing steps except actual database writes.
- **Why**: Validate configuration, parsing, transforms, and SQL generation without modifying any data. Shows what would be done.
- **How**: When enabled, the orchestrator runs the full pipeline (reading, parsing, transforming, batching) but skips the `strategy.ExecuteBatch()` call. SQL statements may still be generated and logged for inspection.
- **Where**: `Config.DryRun`, checked before write operations.
- **When**: Configuration validation, migration rehearsal, testing transforms on production-like data without risk.
- **Who**: All database-writing modes.
- **Default**: `false`
- **Valid values**: `true`, `false`
- **Modes**: insert-ind, update-ind, merge-ind, upsert-ind, insert, update, merge, upsert
- **Example**: `--dry-run`

---

### Flag: `--debug-mode`

- **What**: Enable debug-level logging output.
- **Why**: Shows detailed internal state: SQL statements, batch contents, timing breakdowns, connection pool stats, retry attempts, and strategy decisions. Verbose but essential for troubleshooting.
- **How**: Sets `log.LevelDebug` via `initLogging()`. All `log.Debugln/Debugf` calls throughout the codebase become visible.
- **Where**: `Config.DebugMode`, checked in `initLogging()`.
- **When**: Troubleshooting failed imports, investigating performance issues, understanding internal behavior.
- **Who**: All modes.
- **Default**: `false`
- **Valid values**: `true`, `false`
- **Modes**: All modes.
- **Example**: `--debug-mode`

---

### Flag: `--verbose`

- **What**: Enable verbose logging (less detail than debug, more than default).
- **Why**: Shows high-level progress messages and key decision points without the noise of full debug output.
- **How**: Sets `log.LevelVerbose` via `initLogging()`. `log.Verboseln/Verbosef` calls become visible. Overridden by `--debug-mode`.
- **Where**: `Config.Verbose`, checked in `initLogging()`.
- **When**: When you want more visibility than default but not full debug output.
- **Who**: All modes.
- **Default**: `false`
- **Valid values**: `true`, `false`
- **Modes**: All modes.
- **Example**: `--verbose`

---

## Pipeline Flags

### Flag: `--pipeline-file`

- **What**: Path to the YAML pipeline definition file.
- **Why**: Specifies the pipeline to execute. The YAML file defines databases, steps, dependencies, shared datasets, variables, and daemon config.
- **How**: Read and parsed by `pipeline.ParsePipelineFile()`. The parser validates step types, resolves dependencies, checks for DAG cycles, and constructs the execution plan.
- **Where**: `Config.PipelineFile`, used in `pipeline.Run()`.
- **When**: Required for pipeline, kafka-push, kafka-pull, and daemon modes.
- **Who**: Pipeline-based modes.
- **Default**: `""` (empty, required for pipeline modes)
- **Valid values**: Path to a valid YAML file following the pipeline schema.
- **Modes**: pipeline, kafka-push, kafka-pull, daemon
- **Example**: `--pipeline-file etl_pipeline.yaml`

---

### Flag: `--pipeline-memory-threshold-mb`

- **What**: Memory threshold in MB for pipeline shared datasets and operator engine decisions.
- **Why**: Controls when the operator engine switches from hash-join (fast, memory-intensive) to sort-merge join (slower, memory-efficient). Also influences dataset registry caching decisions.
- **How**: Compared against estimated dataset size during operator selection in `internal/operator/`. If estimated size exceeds threshold, sort-merge or external spill is used instead of hash-join.
- **Where**: `Config.PipelineMemoryThresholdMB`, used in operator engine and dataset registry.
- **When**: Tune based on available memory. Increase for servers with large RAM, decrease for constrained environments.
- **Who**: Pipeline mode with setop/join steps.
- **Default**: `512` (MB)
- **Valid values**: 64 to 32768 (practical range).
- **Modes**: pipeline
- **Example**: `--pipeline-memory-threshold-mb 2048`

---

### Flag: `--progress-interval`

- **What**: Interval in seconds for pipeline step progress messages.
- **Why**: Controls how frequently the pipeline executor reports per-step progress (records processed, elapsed time, throughput). Set to 0 to disable.
- **How**: Passed to `pipeline.SetProgressInterval()` which configures a `time.Duration` used by step executors for periodic progress reporting.
- **Where**: Configured in `initLogging()`, used throughout pipeline step executors.
- **When**: Tune for desired verbosity. 0 disables progress messages entirely.
- **Who**: Pipeline mode.
- **Default**: `10` (seconds)
- **Valid values**: 0 (disabled) to 3600.
- **Modes**: pipeline, daemon
- **Example**: `--progress-interval 5`

---

## License Flags

### Flag: `--license-key`

- **What**: License key string for activating paid features.
- **Why**: Mass Migrator uses a feature-gated licensing model. The license key unlocks enterprise features (gen-pipeline, advanced operators, unlimited threads). A built-in pro trial is available without a key.
- **How**: Resolved by `license.Resolver.Resolve()` which checks CLI key, config key, home directory key file, and falls back to the built-in trial. The license payload is validated against an embedded public key, and expiry is checked against both local and database server clocks (multi-clock validation).
- **Where**: `Config.LicenseKey`, used in `resolveLicense()`.
- **When**: For production deployments requiring enterprise features.
- **Who**: All modes (checked at startup).
- **Default**: `""` (empty, uses trial)
- **Valid values**: Base64-encoded license key string.
- **Modes**: All modes (global).
- **Example**: `--license-key "eyJhbGciOi..."`

---

## Config Flags

### Flag: `--config-file`

- **What**: Path to a YAML configuration file containing all flag values.
- **Why**: Avoids long command lines by putting all configuration in a file. Supports all the same keys as CLI flags (using the mapstructure tag names). File values are overridden by explicit CLI flags.
- **How**: Loaded by `config.LoadYamlConfig()` during `initConfig()`. Uses viper's YAML unmarshaling. Values from the file are set in viper's config store, then CLI flags override.
- **Where**: `Config.ConfigFile`, processed in `initConfig()`.
- **When**: For complex configurations with many flags, or for storing reusable configurations.
- **Who**: All modes (global).
- **Default**: `""` (empty, no config file)
- **Valid values**: Path to a valid YAML file.
- **Modes**: All modes (global).
- **Example**: `--config-file production_migration.yaml`

---

### Flag: `--mode`

- **What**: Operation mode selector (legacy flag on root command).
- **Why**: The original way to select the operation mode before subcommands were added. Still supported for backward compatibility with v2 configurations and scripts.
- **How**: Parsed by `types.ParseMode()` in `app.Route()` to dispatch to the correct orchestrator. Subcommands set this automatically via `viper.Set("mode", ...)`.
- **Where**: `Config.Mode`, used in `app.Route()`.
- **When**: When using the root command instead of subcommands. Subcommands are preferred for new scripts.
- **Who**: All modes via root command.
- **Default**: `""` (empty, required when using root command)
- **Valid values**: Any mode string: `gencsv`, `genparquet`, `insert-ind`, `update-ind`, `merge-ind`, `upsert-ind`, `insert`, `update`, `merge`, `upsert`, `load2csv`, `load2parquet`, `kafka-push`, `kafka-pull`, `pipeline`, `daemon`, `query`, `ddl`, `json-encapsulate`, `json-query`, `verify`, `workflow-scheduler`, `rule-apply`
- **Modes**: Root command only.
- **Example**: `--mode insert-ind`

---

## Environment Variable Override

All flags can be set via environment variables with the `MM_` prefix. The flag name is uppercased and hyphens are replaced with underscores:

| Flag | Environment Variable |
|------|---------------------|
| `--batch-size` | `MM_BATCH_SIZE` |
| `--jdbc-url` | `MM_JDBC_URL` |
| `--db-password` | `MM_DB_PASSWORD` |
| `--threads` | `MM_THREADS` |
| `--pipeline-file` | `MM_PIPELINE_FILE` |
| `--license-key` | `MM_LICENSE_KEY` |
| `--debug-mode` | `MM_DEBUG_MODE` |

This is configured via `viper.SetEnvPrefix("MM")` and `viper.AutomaticEnv()` in `initConfig()`.
