# Mass Migrator CLI Reference

Complete command-line interface reference for Mass Migrator v3.

## Table of Contents

- [Installation](#installation)
- [Global Options](#global-options)
- [Commands](#commands)
  - [gencsv](#gencsv-generate-test-csv-data)
  - [csv2db](#csv2db-import-csv-to-database)
  - [pipeline](#pipeline-execute-yaml-pipeline)
  - [license](#license-license-management)
  - [batch-poller](#batch-poller-batch-polling-engine)
  - [daemon](#daemon-daemon-mode)
  - [state](#state-state-management)
- [Operation Modes](#operation-modes)
- [Configuration](#configuration)
- [Examples](#examples)

## Installation

```bash
# Install from source
go install github.com/massmigrator/mass-migrator/cmd/mass-migrator@latest

# Or build from repository
git clone https://github.com/massmigrator/mass-migrator.git
cd mass-migrator
make build
```

## Global Options

Options that can be used with any command:

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--config-file` | string | - | Path to YAML configuration file |
| `--license-key` | string | - | License key string |
| `--verbose` | bool | false | Enable verbose logging |
| `--debug-mode` | bool | false | Enable debug output |
| `--dry-run` | bool | false | Perform dry run without writing |

## Commands

### gencsv (Generate Test CSV Data)

Generate synthetic test data in CSV format for testing and development.

```bash
mass-migrator gencsv [flags]
```

#### Flags

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--output` | string | required | Output CSV file path |
| `--records` | int64 | required | Number of records to generate |
| `--columns` | string | required | Column definitions (format: name:TYPE,...) |
| `--header` | bool | true | Include header in generated CSV |
| `--seed` | int64 | 0 | Random seed for reproducible generation |

#### Column Definition Format

```
name:TYPE[:DIST[:min:max[:precision]]]
```

Supported types: `BIGINT`, `INTEGER`, `STRING`, `EMAIL`, `DECIMAL`, `TIMESTAMP`, `DATE`, `BOOLEAN`, `FLOAT`, `DOUBLE`, `UUID`, `PHONE`

Supported distributions: `SEQUENTIAL`, `RANDOM`, `NORMAL`

#### Examples

Generate 1 million records with multiple column types:

```bash
mass-migrator gencsv \
  --output test_data.csv \
  --records 1000000 \
  --columns "id:BIGINT:SEQUENTIAL:1:1000000,name:STRING:RANDOM:5:20,email:EMAIL,created_at:TIMESTAMP,active:BOOLEAN"
```

Generate reproducible test data:

```bash
mass-migrator gencsv \
  --output test_data.csv \
  --records 100000 \
  --columns "id:BIGINT:SEQUENTIAL:1:100000,value:DOUBLE:RANDOM:0:1000" \
  --seed 12345
```

### csv2db (Import CSV to Database)

Import CSV files into a database table with optional transformations.

```bash
mass-migrator csv2db [flags]
```

#### Flags

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--input` | string | required | Input CSV file path |
| `--db-url` | string | required | Database JDBC URL |
| `--table` | string | required | Target table name |
| `--mapping` | string | - | Column mapping: csvCol:dbCol:TYPE,... |
| `--create-table` | bool | false | Automatically create target table |
| `--skip-header` | bool | false | Skip CSV header row |
| `--delimiter` | string | "," | CSV delimiter character |
| `--quote` | string | "\"" | CSV quote character |
| `--escape` | string | "\\" | CSV escape character |

#### Performance Flags

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--threads` | int | 4 | Worker threads |
| `--batch-size` | int | 50000 | Batch size for inserts |
| `--queue-size` | int | 10000 | Queue size for workers |

#### Examples

Basic CSV import:

```bash
mass-migrator csv2db \
  --input data.csv \
  --db-url "postgresql://user:pass@localhost:5432/mydb" \
  --table users
```

Import with column mapping and auto-create table:

```bash
mass-migrator csv2db \
  --input data.csv \
  --db-url "postgresql://user:pass@localhost:5432/mydb" \
  --table users \
  --mapping "id:id:INT,name:name:STRING,email:email:STRING" \
  --create-table \
  --threads 8
```

Import with custom CSV format:

```bash
mass-migrator csv2db \
  --input data.csv \
  --db-url "mysql://user:pass@localhost:3306/mydb" \
  --table users \
  --delimiter "|" \
  --quote "'" \
  --skip-header
```

### pipeline (Execute YAML Pipeline)

Execute a multi-step pipeline defined in a YAML configuration file.

```bash
mass-migrator pipeline [flags]
```

#### Flags

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--config` | string | required | Path to pipeline YAML configuration |
| `--log` | string | - | Path to pipeline log file |

#### Pipeline Configuration

Pipeline YAML files define a directed acyclic graph (DAG) of steps:

```yaml
name: "User Migration Pipeline"
description: "Migrate users from source to target"

steps:
  - name: extract-users
    type: db-query
    config:
      jdbc-url: "postgresql://source/db"
      query: "SELECT * FROM users"
      output-dataset: users

  - name: transform-users
    type: transform
    config:
      input-dataset: users
      output-dataset: transformed-users
      script: |
        function transform(record) {
          return {
            id: record.id,
            full_name: record.first_name + ' ' + record.last_name
          };
        }

  - name: load-users
    type: db-write
    config:
      jdbc-url: "mysql://target/db"
      table: users
      input-dataset: transformed-users
      strategy: upsert
      key-columns: [id]
```

#### Step Types

| Type | Description | Configuration |
|------|-------------|---------------|
| `db-query` | Execute database query | jdbc-url, query, output-dataset |
| `db-write` | Write to database | jdbc-url, table, input-dataset, strategy |
| `csv-read` | Read CSV file | input-file, output-dataset |
| `csv-write` | Write CSV file | output-file, input-dataset |
| `parquet-read` | Read Parquet file | input-file, output-dataset |
| `parquet-write` | Write Parquet file | output-file, input-dataset |
| `transform` | Transform data | input-dataset, output-dataset, script |
| `kafka-consume` | Consume from Kafka | brokers, topic, output-dataset |
| `kafka-produce` | Produce to Kafka | brokers, topic, input-dataset |
| `s3-read` | Read from S3 | bucket, key, output-dataset |
| `s3-write` | Write to S3 | bucket, key, input-dataset |
| `group-by` | Group data | input-dataset, output-dataset, columns |
| `filter` | Filter records | input-dataset, output-dataset, condition |
| `sort` | Sort records | input-dataset, output-dataset, columns |
| `aggregate` | Aggregate data | input-dataset, output-dataset, aggregations |

#### Examples

Execute a pipeline:

```bash
mass-migrator pipeline --config migration-pipeline.yaml
```

Execute with logging:

```bash
mass-migrator pipeline \
  --config migration-pipeline.yaml \
  --log migration.log
```

### batch-poller (Batch Polling Engine)

Continuously poll a database header table for new records and process them through a configurable pipeline with claim strategies, error handling, and recovery.

```bash
mass-migrator batch-poller [command]
```

#### Subcommands

##### run

Start the batch poller.

```bash
mass-migrator batch-poller run --config <path> [flags]
```

Flags:

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--config` | string | required | Path to batch-poller YAML config |
| `--max-cycles` | int | 0 | Maximum poll cycles (0 = unlimited) |
| `--fail-rate` | float64 | 0 | Random processing failure rate 0.0-1.0 (testing only) |

##### recover

Reset stale records stuck in processing status back to new.

```bash
mass-migrator batch-poller recover [flags]
```

Flags:

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--connection` | string | required | JDBC connection URL |
| `--table` | string | required | Header table name |
| `--status-column` | string | `status` | Status column name |
| `--timeout` | string | `5m` | Records older than this are reset |
| `--status-new` | string | `N` | Status value for new records |
| `--status-processing` | string | `P` | Status value for processing records |

#### YAML Configuration

```yaml
connection: "jdbc:postgresql://localhost:5432/mydb?user=app&password=secret"
header_table: batch_headers
detail_tables:
  - table: batch_details
    join_column: header_id
status_column: status
status_values:
  new: "N"
  processing: "P"
  completed: "Y"
  error: "E"
interval_seconds: 10
claim_strategy: atomic       # atomic | cas
batch_size: 200
chunk_size: 20
max_workers: 8
error_strategy: per_record   # batch | per_record
max_retries: 3
recovery_strategy: timeout
recovery_timeout_seconds: 300
recovery_sweep_interval: 60
overlap_policy: queue_one    # queue_one | concurrent | adaptive
```

#### Claim Strategies

| Strategy | Description |
|----------|-------------|
| `atomic` | Single `UPDATE...RETURNING` atomically claims records (PostgreSQL, SQL Server) |
| `cas` | `SELECT` then CAS-guarded update — works on all databases |

#### Error Strategies

| Strategy | Description |
|----------|-------------|
| `batch` | Entire chunk marked as error if any record fails |
| `per_record` | Only failed records marked as error, others continue |

#### Overlap Policies

| Policy | Description |
|--------|-------------|
| `queue_one` | Skip poll cycle if previous is still running |
| `concurrent` | Allow overlapping poll cycles up to `max_concurrent` |
| `adaptive` | Automatically switch between queue and concurrent based on load |

#### Examples

Run with limited cycles:

```bash
mass-migrator batch-poller run --config batch_poller.yaml --max-cycles 5
```

Run with simulated failures:

```bash
mass-migrator batch-poller run --config batch_poller.yaml --fail-rate 0.2
```

Recover stale records:

```bash
mass-migrator batch-poller recover \
  --connection "jdbc:postgresql://localhost:5432/mydb" \
  --table batch_headers \
  --timeout 10m
```

### license (License Management)

Manage licenses for enterprise features.

```bash
mass-migrator license [command]
```

#### Subcommands

##### show

Display current license information.

```bash
mass-migrator license show
```

##### activate

Activate a license key.

```bash
mass-migrator license activate <key>
```

##### deactivate

Deactivate current license.

```bash
mass-migrator license deactivate
```

### daemon (Daemon Mode)

Run Mass Migrator as a background daemon for scheduled migrations.

```bash
mass-migrator daemon [command]
```

#### Subcommands

##### start

Start the daemon in the background.

```bash
mass-migrator daemon start
```

Flags:

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--config` | string | - | Path to daemon configuration file |
| `--pid-file` | string | /var/run/mass-migrator.pid | PID file path |

##### Runtime control verbs (reload / status / stop)

These three verbs are operator-facing **clients** that dial the running
daemon's control socket and send a command. They are siblings of
`service` (which manages the SCM/systemd/launchd registration) and were
added in Gap-Fix G1 so one binary covers both surfaces.

Common flags (every verb accepts all three):

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--socket` | string | `$MASS_MIGRATOR_CONTROL_SOCKET` or platform default | Control socket path (Unix domain socket on linux/darwin, `\\.\pipe\mass-migrator` on Windows) |
| `--timeout` | duration | `5s` | Timeout for dialing and I/O against the control socket |
| `--json` | bool | `false` | Emit a machine-parseable JSON envelope instead of human-readable text |

Exit codes (shared by all three):

- `0` — command acknowledged by the daemon.
- `1` — daemon unreachable (no socket, no listener, refused).
- `2` — daemon replied with an `ERR ...` response.
- `3` — dial or I/O exceeded `--timeout`.

###### reload

Ask the running daemon to re-read its pipeline configuration.

```bash
mass-migrator daemon reload
mass-migrator daemon reload --socket /var/run/mm/control.sock --json
```

###### status

Show runtime status of the running daemon (uptime, active pipelines, last reload timestamp). Distinct from `daemon service status`, which queries the SCM about the registered service.

```bash
mass-migrator daemon status
mass-migrator daemon status --json
```

###### stop

Ask the running daemon to begin a graceful shutdown via its control socket. Distinct from `daemon service stop`, which sends a Stop control to the Windows SCM.

```bash
mass-migrator daemon stop
mass-migrator daemon stop --socket /var/run/mm/control.sock --timeout 10s
```

##### restart

Restart the daemon.

```bash
mass-migrator daemon restart
```

##### service (Windows service management)

Manage the mass-migrator daemon as a Windows service via the Service Control
Manager (SCM). All subcommands are Windows-specific — on Linux use `systemctl`,
on macOS use `launchctl`. Invoking these on non-Windows hosts exits with
code `2` and a platform-aware message.

```bash
mass-migrator daemon service [verb]
```

Common flags (every verb accepts both):

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--name` | string | `mass-migrator` | SCM service name |
| `--json` | bool | `false` | Emit a machine-parseable JSON result instead of human-readable text |

Verbs:

- `install` — Register the running binary with the SCM. Extra flags:
  - `--display-name` (default `Mass Migrator Daemon`) — label shown in Services.msc
  - `--description` — text registered with the SCM
  - `--config-path` (default `%PROGRAMDATA%\mass-migrator\daemon.yaml`) — path to the daemon YAML
  - `--binary-path` (default: current executable) — override the binary registered with the SCM
- `uninstall` — Remove the service registration. Service must be stopped first.
- `start` — Send the SCM a Start control for the named service.
- `stop` — Send the SCM a Stop control and wait for the service to reach Stopped.
- `restart` — Stop then Start. Tolerates an already-stopped service.
- `status` — Query the SCM for the service's current state and PID.

```bash
# Install with defaults
mass-migrator daemon service install

# Custom service name + JSON output
mass-migrator daemon service install --name mm-prod \
  --config-path C:\ProgramData\mm\daemon.yaml --json

# Query status as JSON for scripts
mass-migrator daemon service status --json
```

Exit codes:

- `0` — operation succeeded.
- `1` — operator error (bad flag, SCM rejection, etc.).
- `2` — invoked on a non-Windows host.

#### Daemon Configuration

```yaml
jobs:
  - name: "Daily User Sync"
    schedule: "0 2 * * *"  # Daily at 2 AM
    pipeline: "user-sync-pipeline.yaml"
    enabled: true

  - name: "Hourly Metrics"
    schedule: "0 * * * *"  # Every hour
    pipeline: "metrics-pipeline.yaml"
    enabled: true

settings:
  log-level: "info"
  log-file: "/var/log/mass-migrator/daemon.log"
  max-concurrent-jobs: 3
```

### state (State Management)

Manage pipeline state for checkpoint/resume functionality.

```bash
mass-migrator state [command]
```

#### Subcommands

##### list

List all saved pipeline states.

```bash
mass-migrator state list
```

Output format:

```
ID          CREATED             PIPELINE           STATUS      PROGRESS
abc123      2026-03-07 14:30    user-migration     Running     45%
def456      2026-03-07 15:00    data-export        Completed   100%
```

##### show

Show details of a specific state.

```bash
mass-migrator state show <id>
```

Output includes:
- State metadata
- Checkpoint data
- Step progress
- Error information

##### resume

Resume a pipeline from a saved state.

```bash
mass-migrator state resume <id>
```

##### delete

Delete a saved state.

```bash
mass-migrator state delete <id>
```

##### clear

Delete all saved states.

```bash
mass-migrator state clear
```

##### validate

Validate all saved states.

```bash
mass-migrator state validate
```

## Operation Modes

Mass Migrator supports various operation modes for different data movement scenarios:

### Data Generation Modes

| Mode | Description |
|------|-------------|
| `gencsv` | Generate CSV test data |
| `genparquet` | Generate Parquet test data |

### Import Modes

| Mode | Description |
|------|-------------|
| `insert-ind` | Insert from file to database |
| `update-ind` | Update from file to database |
| `merge-ind` | Merge from file to database |
| `upsert-ind` | Upsert from file to database |

### Database Migration Modes

| Mode | Description |
|------|-------------|
| `insert` | Insert from source to target database |
| `update` | Update target from source database |
| `merge` | Merge source into target database |
| `upsert` | Upsert from source to target database |

### Export Modes

| Mode | Description |
|------|-------------|
| `db2csv` | Export database table to CSV |
| `db2parquet` | Export database table to Parquet |
| `load2csv` | Bulk load to CSV |
| `load2parquet` | Bulk load to Parquet |

### Streaming Modes

| Mode | Description |
|------|-------------|
| `kafka-push` | Push database changes to Kafka |
| `kafka-pull` | Pull from Kafka to database |

## Configuration

### Database Connection Strings

#### PostgreSQL

```
postgresql://user:password@localhost:5432/database?sslmode=require
```

#### MySQL

```
mysql://user:password@tcp(localhost:3306)/database
```

#### SQL Server

```
sqlserver://user:password@localhost:1433?database=dbname
```

#### Oracle

```
oracle://user:password@localhost:1521/service_name
```

#### SQLite

```
sqlite:///path/to/database.db
```

#### Neo4j

```
neo4j://user:password@localhost:7687
```

#### Netezza

```
netezza://user:password@localhost:5480/database
```

### Environment Variables

All configuration can be provided via environment variables with the `MM_` prefix:

```bash
export MM_DB_TYPE="postgresql"
export MM_JDBC_URL="postgresql://user:pass@localhost:5432/mydb"
export MM_THREADS="8"
export MM_BATCH_SIZE="50000"
```

### YAML Configuration Files

Create reusable configuration files:

```yaml
# config.yaml
source:
  jdbc-url: "postgresql://user:pass@localhost:5432/sourcedb"
  query: "SELECT * FROM users WHERE active = true"

target:
  jdbc-url: "mysql://user:pass@localhost:3306/targetdb"
  table: "users"

performance:
  batch-size: 50000
  threads: 8
  fetch-size: 10000

transform:
  script-file: "transform.js"
  mode: "ONE_TO_ONE"

error-handling:
  max-retry-attempts: 3
  fail-fast-mode: false
```

Use with:

```bash
mass-migrator --config-file config.yaml
```

## Examples

### Complete Migration Workflow

#### 1. Generate Test Data

```bash
mass-migrator gencsv \
  --output source_users.csv \
  --records 1000000 \
  --columns "id:BIGINT:SEQUENTIAL:1:1000000,first_name:STRING:RANDOM:3:12,last_name:STRING:RANDOM:3:15,email:EMAIL,created_at:TIMESTAMP"
```

#### 2. Import to Source Database

```bash
mass-migrator csv2db \
  --input source_users.csv \
  --db-url "postgresql://user:pass@localhost:5432/sourcedb" \
  --table users \
  --create-table \
  --threads 8
```

#### 3. Migrate to Target Database with Transformation

Create `transform.js`:

```javascript
function transform(record) {
  return {
    user_id: record.id,
    full_name: record.first_name + ' ' + record.last_name,
    email_address: record.email.toLowerCase(),
    account_created: parseDate(record.created_at),
    migration_timestamp: new Date()
  };
}
```

Run migration:

```bash
mass-migrator \
  --mode upsert \
  --source-jdbc-url "postgresql://user:pass@localhost:5432/sourcedb" \
  --source-table users \
  --target-jdbc-url "mysql://user:pass@localhost:3306/targetdb" \
  --target-table users \
  --key-columns user_id \
  --transform-script transform.js \
  --batch-size 50000 \
  --threads 8 \
  --enable-state-management
```

### Group-Based Processing

Process large datasets in groups:

```bash
mass-migrator \
  --mode insert \
  --source-jdbc-url "postgresql://user:pass@localhost:5432/sourcedb" \
  --source-query "SELECT * FROM large_table" \
  --target-jdbc-url "mysql://user:pass@localhost:3306/targetdb" \
  --target-table large_table \
  --group-columns "region,department" \
  --split-output-by-group \
  --threads 16
```

### Pipeline Orchestration

Create `migration-pipeline.yaml`:

```yaml
name: "Full Migration Pipeline"
description: "Complete data migration workflow"

steps:
  - name: extract
    type: db-query
    config:
      jdbc-url: "postgresql://source/db"
      query: "SELECT * FROM users"
      output-dataset: raw-users

  - name: transform
    type: transform
    config:
      input-dataset: raw-users
      output-dataset: clean-users
      script-file: "transform.js"

  - name: validate
    type: filter
    config:
      input-dataset: clean-users
      output-dataset: valid-users
      condition: "record.email != null && record.email.length > 0"

  - name: load
    type: db-write
    config:
      jdbc-url: "mysql://target/db"
      table: users
      input-dataset: valid-users
      strategy: upsert
      key-columns: [user_id]
```

Execute pipeline:

```bash
mass-migrator pipeline --config migration-pipeline.yaml
```

### Daemon Mode for Scheduled Syncs

Create `daemon-config.yaml`:

```yaml
jobs:
  - name: "Incremental User Sync"
    schedule: "*/30 * * * *"  # Every 30 minutes
    pipeline: "incremental-sync.yaml"
    enabled: true

  - name: "Daily Full Sync"
    schedule: "0 1 * * *"  # Daily at 1 AM
    pipeline: "full-sync.yaml"
    enabled: true
```

Start daemon:

```bash
mass-migrator daemon start --config daemon-config.yaml
```

## Performance Tuning

### Batch Size

Optimal batch size depends on your database and schema:

- **Small rows**: 50,000 - 100,000
- **Medium rows**: 10,000 - 50,000
- **Large rows**: 1,000 - 10,000

### Thread Count

Set based on available CPU cores:

```bash
# For 8 core system
--threads 6

# For high-throughput scenarios
--threads 16
```

### Fetch Size

Optimize fetch size for your database:

- **PostgreSQL**: 10,000 - 50,000
- **MySQL**: 10,000 - 100,000
- **SQL Server**: 5,000 - 50,000
- **Oracle**: 100 - 10,000

## Troubleshooting

### Enable Debug Logging

```bash
mass-migrator --verbose --debug-mode [command]
```

### Dry Run

Test without making changes:

```bash
mass-migrator --dry-run [command]
```

### Check State

View pipeline state:

```bash
mass-migrator state list
mass-migrator state show <id>
```

### Resume Failed Migration

```bash
mass-migrator state resume <id>
```

## Additional Resources

- [README](../README.md) - Project overview
- [Architecture](reference/5w1h-operation-modes-and-flags.md) - System architecture and operation modes
- [Contributing](../CONTRIBUTING.md) - Contribution guidelines
- [GitHub Issues](https://github.com/massmigrator/mass-migrator/issues) - Bug reports and feature requests
