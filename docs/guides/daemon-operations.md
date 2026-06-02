# Mass Migrator Daemon Operations Guide

This guide covers deployment, operation, monitoring, and troubleshooting of the Mass Migrator daemon in production environments.

## Overview

The Mass Migrator daemon is a background service that executes scheduled database migration, ETL, and incremental sync pipelines using cron-style scheduling. It supports:

- **Multi-pipeline mode**: A daemon config file references multiple pipeline definitions, each with its own cron schedule
- **Concurrency control**: Configurable worker pools and overlap policies (skip, cancel, wait, replace)
- **Hot-reload**: Configuration changes without restarting via `SIGHUP` signal or control socket command
- **Runtime management**: Unix domain socket for `STATUS`, `RELOAD`, and `STOP` commands
- **Observability**: Health endpoints, metrics, and optional Go runtime profiling

---

## Installation

### 1. Create System User and Group

```bash
sudo useradd --system --home /var/lib/mass-migrator --shell /usr/sbin/nologin mass-migrator
sudo groupadd --system mass-migrator 2>/dev/null || true
sudo usermod -a -G mass-migrator mass-migrator
```

### 2. Install Binary

Download the mass-migrator binary for your platform (Linux x86_64, Linux ARM64, macOS, etc.) from the [GitHub releases page](https://github.com/massmigrator/mass-migrator/releases).

```bash
sudo install -m 0755 /path/to/mass-migrator /usr/local/bin/mass-migrator
```

### 3. Create Directory Structure

```bash
sudo mkdir -p /etc/mass-migrator/pipelines
sudo mkdir -p /var/lib/mass-migrator
sudo mkdir -p /var/log/mass-migrator
sudo mkdir -p /var/run/mass-migrator

sudo chown mass-migrator:mass-migrator /etc/mass-migrator
sudo chown mass-migrator:mass-migrator /var/lib/mass-migrator
sudo chown mass-migrator:mass-migrator /var/log/mass-migrator
sudo chown mass-migrator:mass-migrator /var/run/mass-migrator

sudo chmod 0700 /var/lib/mass-migrator
sudo chmod 0750 /var/log/mass-migrator
sudo chmod 0700 /var/run/mass-migrator
```

### 4. Install Systemd Service Files

```bash
sudo cp contrib/mass-migrator.service /etc/systemd/system/
sudo cp contrib/mass-migrator.logrotate /etc/logrotate.d/mass-migrator
sudo cp contrib/mass-migrator-tmpfiles.conf /etc/tmpfiles.d/mass-migrator.conf

sudo systemctl daemon-reload
sudo systemd-tmpfiles --create
```

### 5. Create Configuration

Create `/etc/mass-migrator/daemon.yaml` with your pipeline definitions:

```yaml
---
daemon:
  pid_file: "/var/run/mass-migrator/daemon.pid"
  control_socket: "/var/run/mass-migrator/control.sock"
  shutdown_timeout: 30s
  heartbeat_interval: 10s
  default_timezone: "+00:00"
  log_dir: "/var/log/mass-migrator"
  workers: 4

pipelines:
  - file: "/etc/mass-migrator/pipelines/sync_orders.yaml"
    enabled: true
  - file: "/etc/mass-migrator/pipelines/sync_customers.yaml"
    enabled: true
```

Each pipeline file specifies its own schedule and overlap policy:

```yaml
---
name: sync_orders_pipeline

daemon:
  schedule: "*/5 * * * *"      # Every 5 minutes
  overlap_policy: skip           # skip | cancel | wait | replace
  timezone: "+00:00"

databases:
  source:
    url: "postgresql://localhost:5432/appdb?sslmode=disable"
    username: appuser
    password: "${APPUSER_PASSWORD}"  # Use env interpolation
    type: postgresql
    pool_size: 5

steps:
  - id: extract_orders
    type: query
    database: source
    sql: "SELECT id, name, amount FROM orders WHERE updated_at > ?"
    output: source_data

  - id: load_orders
    type: load
    database: source
    dataset: source_data
    target_table: orders_sync
    strategy: upsert
    key_columns: [id]
    columns: [id, name, amount]
    batch_size: 1000
    threads: 2
    depends_on: [extract_orders]
```

---

## Configuration

### Daemon Config Schema

**`/etc/mass-migrator/daemon.yaml`** (multi-pipeline mode):

| Key | Type | Description | Default |
|-----|------|-------------|---------|
| `daemon.pid_file` | string | Path to PID lock file (0600 perms, daemon user only) | `/var/run/mass-migrator/daemon.pid` |
| `daemon.control_socket` | string | Unix socket for runtime commands (STATUS, RELOAD, STOP) | `/var/run/mass-migrator/control.sock` |
| `daemon.shutdown_timeout` | duration | Graceful shutdown timeout | `30s` |
| `daemon.heartbeat_interval` | duration | Health check interval for running jobs | `10s` |
| `daemon.default_timezone` | string | Cron schedule timezone (e.g., "+07:00", "UTC") | `+00:00` |
| `daemon.log_dir` | string | Directory for per-pipeline log files | `/var/log/mass-migrator` |
| `daemon.workers` | int | Number of concurrent worker goroutines | `4` |
| `pipelines[]` | array | List of pipeline references | — |
| `pipelines[].file` | string | Path to pipeline YAML | — |
| `pipelines[].enabled` | bool | Enable/disable pipeline without deletion | `true` |

### Environment Variables

The daemon respects standard mass-migrator environment variables for database credentials, API keys, and logging:

| Variable | Usage | Example |
|----------|-------|---------|
| `MM_PPROF` | Enable Go runtime profiling on `/debug/pprof/*` endpoints | `MM_PPROF=1` |
| `MM_NTP_SERVER` | NTP server for time sync (if needed for scheduling) | `time.google.com` |
| `MM_ALLOW_INSECURE_TLS` | Allow insecure TLS for dev/test only | `false` |
| `APPUSER_PASSWORD` | Example: database password (referenced in daemon.yaml as `${APPUSER_PASSWORD}`) | — |
| `DATABASE_URL` | Example: connection string | — |

Set in `/etc/systemd/system/mass-migrator.service.d/custom.conf` or directly in the service file `[Service]` section:

```ini
[Service]
Environment="MM_PPROF=1"
Environment="APPUSER_PASSWORD=secret123"
```

Or in `/etc/default/mass-migrator` if sourced by the service file:

```bash
MM_PPROF=1
APPUSER_PASSWORD=secret123
```

---

## Lifecycle Management

### Start Daemon

```bash
sudo systemctl start mass-migrator
```

Verify startup:

```bash
sudo systemctl status mass-migrator
sudo journalctl -u mass-migrator -f
```

### Check Status

```bash
sudo systemctl status mass-migrator

# Detailed daemon status via control socket
echo "STATUS" | sudo socat - UNIX-CONNECT:/var/run/mass-migrator/control.sock

# Health check endpoints
curl http://localhost:8080/health
curl http://localhost:8080/health/ready
curl http://localhost:8080/health/live
```

### Reload Configuration (No Downtime)

```bash
sudo systemctl reload mass-migrator

# Or via control socket
echo "RELOAD" | sudo socat - UNIX-CONNECT:/var/run/mass-migrator/control.sock

# Signal daemon directly (systemd forwards to daemon process)
sudo systemctl kill -s HUP mass-migrator
```

Reload re-reads the daemon config and pipeline files, without interrupting in-flight jobs. Newly registered pipelines become active on the next scheduler tick.

### Stop Daemon (Graceful)

```bash
sudo systemctl stop mass-migrator
```

The daemon receives `SIGTERM`, cancels pending jobs, completes in-flight jobs (up to `shutdown_timeout`), releases locks, and exits cleanly.

```bash
# Force stop if stuck
sudo systemctl kill -s KILL mass-migrator
```

### Restart Daemon

```bash
sudo systemctl restart mass-migrator
```

### View Logs

```bash
# Follow live logs
sudo journalctl -u mass-migrator -f

# Last 50 lines
sudo journalctl -u mass-migrator -n 50

# Logs since last boot
sudo journalctl -u mass-migrator -b

# Per-pipeline logs (if logging to disk)
sudo tail -f /var/log/mass-migrator/sync_orders_pipeline.log
```

---

## Health and Observability

### Health Endpoints

The daemon provides HTTP health check endpoints on the health server (default: `127.0.0.1:8080`).

#### GET /health

Returns overall daemon health status (200 = healthy, 503 = degraded).

```bash
curl http://127.0.0.1:8080/health
```

**Response (200 OK)**:
```json
{
  "status": "healthy",
  "scheduler": {
    "workers": 4,
    "in_flight": 1,
    "queue_capacity": 100,
    "queue_size": 5,
    "dropped_jobs": 0,
    "jobs_by_status": {
      "scheduled": 2,
      "running": 1,
      "completed": 10,
      "failed": 0
    },
    "last_updated": "2026-05-31T12:34:56Z"
  }
}
```

#### GET /health/ready

Readiness probe — returns 200 if daemon has jobs registered and is accepting work.

```bash
curl http://127.0.0.1:8080/health/ready
```

Use in Kubernetes or load balancer health checks.

#### GET /health/live

Liveness probe — returns 200 if daemon process is alive and responsive (lightweight).

```bash
curl http://127.0.0.1:8080/health/live
```

**Response (200 OK)**:
```json
{
  "alive": true,
  "workers": 4
}
```

#### GET /metrics

Current scheduler metrics (Prometheus-style format).

```bash
curl http://127.0.0.1:8080/metrics
```

**Response (200 OK)**:
```json
{
  "workers": 4,
  "in_flight": 1,
  "queue_capacity": 100,
  "queue_size": 5,
  "dropped_jobs": 0,
  "wait_time_ms": 1234,
  "max_wait_ms": 5678,
  "last_updated": "2026-05-31T12:34:56Z",
  "jobs": 3
}
```

| Metric | Meaning |
|--------|---------|
| `workers` | Configured number of concurrent worker goroutines |
| `in_flight` | Number of pipelines currently executing |
| `queue_capacity` | Max jobs in queue (unbounded by default) |
| `queue_size` | Current number of pending jobs in queue |
| `dropped_jobs` | Cumulative count of jobs dropped due to queue overflow |
| `wait_time_ms` | Total wait time for all jobs (milliseconds) |
| `max_wait_ms` | Longest single job wait time (milliseconds) |
| `last_updated` | Timestamp of last metric update |
| `jobs` | Total number of registered pipelines |

### Prometheus Scrape Config

Add to your Prometheus `prometheus.yml`:

```yaml
scrape_configs:
  - job_name: 'mass-migrator-daemon'
    static_configs:
      - targets: ['127.0.0.1:8080']
    metrics_path: '/metrics'
    scrape_interval: '15s'
```

### Optional: Go Runtime Profiling

Enable with `MM_PPROF=1` environment variable:

```bash
MM_PPROF=1 sudo systemctl restart mass-migrator
```

Profiling endpoints become available at `http://127.0.0.1:8080/debug/pprof/`:

```bash
# Goroutine snapshot
curl http://127.0.0.1:8080/debug/pprof/goroutine?debug=2 > goroutine.txt

# Heap profile (memory)
curl http://127.0.0.1:8080/debug/pprof/heap > heap.prof
go tool pprof -http=:6060 heap.prof

# CPU profile (30-second trace)
curl 'http://127.0.0.1:8080/debug/pprof/profile?seconds=30' > cpu.prof
go tool pprof -http=:6060 cpu.prof

# Mutex contention
curl http://127.0.0.1:8080/debug/pprof/mutex > mutex.prof
```

**Security**: `/debug/pprof` exposes Go internals and memory layout. Only enable in trusted networks. Do not bind health server to public interfaces.

---

## Control Socket

The daemon listens on a Unix domain socket for runtime commands. Only the daemon user can connect (peer-credential check enforced).

**Socket path**: `/var/run/mass-migrator/control.sock` (0700 permissions, daemon user only)

**Available commands**:

| Command | Effect | Response |
|---------|--------|----------|
| `STATUS` | Report daemon and job status | JSON with running jobs, queue depth, metrics |
| `RELOAD` | Re-read config and pipeline files | "reload scheduled" (non-blocking) |
| `STOP` | Initiate graceful shutdown | "shutdown initiated" |

### Using socat to Send Commands

```bash
# STATUS
echo "STATUS" | sudo socat - UNIX-CONNECT:/var/run/mass-migrator/control.sock

# RELOAD
echo "RELOAD" | sudo socat - UNIX-CONNECT:/var/run/mass-migrator/control.sock

# STOP
echo "STOP" | sudo socat - UNIX-CONNECT:/var/run/mass-migrator/control.sock
```

If `socat` is not available, install it:

```bash
sudo apt-get install socat        # Debian/Ubuntu
sudo yum install socat            # RHEL/CentOS
brew install socat                # macOS
```

---

## Dead Letter Queue (DLQ) Management

Failed pipeline executions are written to a Dead Letter Queue for inspection and re-processing.

**DLQ location**: Configured in daemon config (default: `/var/lib/mass-migrator/dlq/`)

### Storage Backend (Wave 8F: SQLite)

As of Wave 8F the DLQ is backed by a **SQLite database** (file: `dlq.db`), not a CSV file. Each failed record is one indexed row, so `UpdateRetryCount` and `RemoveEntry` are O(log N) — earlier versions read+rewrote the whole CSV per call (O(N), so O(N²) under retry storms).

**Recommended new path**: `/var/lib/mass-migrator/dlq/dlq.db`.

**Backward compatibility**: callers that still pass `.../dlq.csv` continue to work — on first open the existing CSV is auto-imported into a sibling `.db` file, and the CSV is left in place as an audit trail. Imports are idempotent (a marker in `dlq_meta` records the source path).

**Backup**: just copy the `.db` file (and the `-wal` / `-shm` sidecars if present). Stop or quiesce the daemon first if you want a transactionally clean snapshot.

```bash
# Hot backup using SQLite's online backup API:
sqlite3 /var/lib/mass-migrator/dlq/dlq.db ".backup /backups/dlq-$(date +%F).db"

# Or copy while daemon is paused:
cp /var/lib/mass-migrator/dlq/dlq.db* /backups/
```

**Inspection** via `sqlite3`:

```bash
# Show the last 20 entries
sqlite3 /var/lib/mass-migrator/dlq/dlq.db \
  "SELECT datetime(created_at/1000000000,'unixepoch'), step_id, run_id, retry_count, substr(last_error,1,80)
   FROM dlq_entries ORDER BY created_at DESC LIMIT 20;"

# Count by error type
sqlite3 /var/lib/mass-migrator/dlq/dlq.db \
  "SELECT last_error, COUNT(*) FROM dlq_entries GROUP BY last_error ORDER BY 2 DESC;"

# Count by step
sqlite3 /var/lib/mass-migrator/dlq/dlq.db \
  "SELECT step_id, COUNT(*) FROM dlq_entries GROUP BY step_id;"
```

**Explicit migration helper** (for batch jobs):

```go
import "github.com/massmigrator/mass-migrator/internal/dlq"

err := dlq.MigrateCSVToSQLite("/old/dlq.csv", "/new/dlq.db")
```

### Inspect DLQ

```bash
mass-migrator dlq inspect --path /var/lib/mass-migrator/dlq/
```

Example output:
```
DLQ Statistics:
  Total failed jobs: 42
  Failed at: 2026-05-31T12:00:00Z
  Errors:
    - "connection timeout": 15
    - "duplicate key": 20
    - "out of memory": 7

Recent failures:
  1. Job: sync_orders_pipeline [2026-05-31 12:15:00]
     Error: duplicate key value violates unique constraint
     
  2. Job: sync_customers_pipeline [2026-05-31 12:10:30]
     Error: connection timeout
```

### Re-process Failed Jobs

```bash
# Re-process all jobs matching a pattern
mass-migrator dlq reprocess --path /var/lib/mass-migrator/dlq/ --filter "sync_orders*"

# Re-process all DLQ entries
mass-migrator dlq reprocess --path /var/lib/mass-migrator/dlq/ --all
```

Re-processed jobs are submitted to the scheduler with the original configuration. They run on the next available worker.

### Manual DLQ Cleanup

**Note**: The DLQ has no automatic TTL or bounded size as of Wave 8F — the migration to SQLite was scoped to fix the O(N²) latency defect. TTL-based eviction and a `MaxSizeBytes` cap are still planned future enhancements. Until then, monitor disk usage and manually clean stale entries if necessary.

```bash
# List DLQ files
ls -lh /var/lib/mass-migrator/dlq/

# Delete old entries (older than 30 days)
find /var/lib/mass-migrator/dlq/ -type f -mtime +30 -delete

# Clear entire DLQ (only if you're certain about recovery)
rm -rf /var/lib/mass-migrator/dlq/*
```

A planned future enhancement will add TTL-based automatic cleanup and bounded DLQ size with eviction policies.

---

## State Database Management

The daemon tracks job execution state in a durable store (SQLite, PostgreSQL, MySQL, SQL Server, or Oracle, depending on your config).

**State DB location**: Configured in daemon config (default: SQLite at `/var/lib/mass-migrator/state.db`)

### Backup State Database

#### SQLite (file-based)

```bash
# Daemon must be running (uses WAL mode with concurrent access)
sudo sqlite3 /var/lib/mass-migrator/state.db ".backup /tmp/state.db.backup"

# Or stop daemon and copy
sudo systemctl stop mass-migrator
sudo cp /var/lib/mass-migrator/state.db /tmp/state.db.backup
sudo cp /var/lib/mass-migrator/state.db-wal /tmp/state.db-wal.backup 2>/dev/null || true
sudo systemctl start mass-migrator
```

#### PostgreSQL

```bash
sudo -u postgres pg_dump --host=localhost --dbname=mass_migrator_state > /tmp/state.sql
```

Or use `pg_basebackup` for point-in-time recovery.

#### MySQL

```bash
mysqldump --host=localhost --user=root --password --all-databases > /tmp/state.sql
```

### Restore State Database

#### SQLite

```bash
sudo systemctl stop mass-migrator
sudo rm /var/lib/mass-migrator/state.db
sudo cp /tmp/state.db.backup /var/lib/mass-migrator/state.db
sudo chown mass-migrator:mass-migrator /var/lib/mass-migrator/state.db
sudo chmod 0600 /var/lib/mass-migrator/state.db
sudo systemctl start mass-migrator
```

#### PostgreSQL

```bash
psql --host=localhost --user=postgres < /tmp/state.sql
```

### Cleanup Stale Locks

If a daemon crashes without releasing run locks, they persist in the state DB. Clean them up before restarting:

```bash
# Check stale locks (running longer than 1 hour)
sudo sqlite3 /var/lib/mass-migrator/state.db \
  "SELECT job_id, acquired_at FROM run_locks WHERE acquired_at < datetime('now', '-1 hour');"

# Delete stale locks (only if certain daemon is not running)
sudo systemctl stop mass-migrator
sudo sqlite3 /var/lib/mass-migrator/state.db \
  "DELETE FROM run_locks WHERE acquired_at < datetime('now', '-1 hour');"
sudo systemctl start mass-migrator
```

---

## Licensing

Mass Migrator daemon requires a valid license key for production use. Trial and dev builds are time-limited.

### License Key Placement

Place your license key in:

1. **Environment variable** (highest priority):
   ```bash
   export MM_LICENSE_KEY="your-license-key-here"
   ```

2. **Config file** (`/etc/mass-migrator/daemon.yaml`):
   ```yaml
   license_key: "your-license-key-here"
   ```

3. **Home directory** (`~mass-migrator/.mass-migrator/license`):
   ```bash
   sudo -u mass-migrator mkdir -p ~/.mass-migrator
   echo "your-license-key-here" | sudo tee ~/.mass-migrator/license
   sudo chmod 0600 ~/.mass-migrator/license
   ```

### License Signing Key Management

Licenses are signed with an RSA 2048-bit private key. For production deployments:

1. **Generate or obtain signing key** (operations/infra team responsibility):
   ```bash
   mass-migrator keygen --type rsa --bits 2048 --output sign.key
   sudo cp sign.key /etc/mass-migrator/sign.key
   sudo chown root:mass-migrator /etc/mass-migrator/sign.key
   sudo chmod 0640 /etc/mass-migrator/sign.key
   ```

2. **Configure in daemon**:
   ```yaml
   license:
     signing_key: "/etc/mass-migrator/sign.key"
   ```

3. **Recommended**: Use HSM or KMS-backed key rotation
   - AWS KMS: Integrate with `aws-vault` or Secrets Manager
   - HashiCorp Vault: Use Vault client with auto-rotation

### License Expiry Handling

At startup, the daemon checks license expiry:

- **Valid license**: Daemon starts normally
- **License expired**: Daemon logs warning and degrades to free tier (limited parallelism, fewer features)
- **No license** (trial/dev): Time-limited access (90 days from first run)

**Monitor license expiry**:

```bash
journalctl -u mass-migrator | grep "license"
curl http://127.0.0.1:8080/health | jq '.license'
```

---

## Troubleshooting

### Daemon Won't Start

**Symptom**: `sudo systemctl start mass-migrator` fails immediately or hangs.

**Diagnosis**:

```bash
# Check systemd error
sudo systemctl status mass-migrator
sudo journalctl -u mass-migrator -n 20

# Check file permissions
ls -la /var/lib/mass-migrator /var/run/mass-migrator /var/log/mass-migrator

# Verify PID file is not stale
sudo ls -la /var/run/mass-migrator/daemon.pid
cat /var/run/mass-migrator/daemon.pid 2>/dev/null | xargs ps -p

# Check config syntax
sudo -u mass-migrator mass-migrator validate-config --file /etc/mass-migrator/daemon.yaml
```

**Common causes and fixes**:

| Symptom | Cause | Fix |
|---------|-------|-----|
| `permission denied` on log/lib dirs | Wrong owner | `sudo chown -R mass-migrator:mass-migrator /var/lib/mass-migrator /var/log/mass-migrator` |
| `PID file already locked` | Stale daemon process | `ps aux \| grep mass-migrator` (verify no daemon running), then `rm /var/run/mass-migrator/daemon.pid` |
| `config file not found` | Missing `/etc/mass-migrator/daemon.yaml` | Create config file (see Configuration section) |
| `no enabled pipelines` | All pipelines disabled in config | Set `enabled: true` for at least one pipeline |
| `YAML parse error` | Syntax error in daemon.yaml | Validate YAML: `yamllint /etc/mass-migrator/daemon.yaml` |

### Pipeline Not Running on Schedule

**Symptom**: Pipeline's cron schedule approaches but job doesn't execute.

**Diagnosis**:

```bash
# Check daemon is running
sudo systemctl status mass-migrator

# Verify pipeline is registered
echo "STATUS" | sudo socat - UNIX-CONNECT:/var/run/mass-migrator/control.sock | jq '.jobs[] | select(.name == "sync_orders_pipeline")'

# Check scheduler queue depth
curl http://127.0.0.1:8080/metrics | jq '.queue_size, .in_flight'

# Check logs for scheduler errors
sudo journalctl -u mass-migrator | grep -i "schedule\|trigger\|error"
```

**Common causes and fixes**:

| Symptom | Cause | Fix |
|---------|-------|-----|
| Job in queue but not running | All workers busy with other jobs | Increase `daemon.workers` in config, reload |
| Job scheduled but skipped | Previous run still active + overlap_policy: skip | Check `/health` for long-running jobs, or change `overlap_policy` to `wait` |
| Cron schedule not advancing | Timezone mismatch | Verify `daemon.default_timezone` matches system TZ: `timedatectl` |
| Pipeline file not found | Incorrect path in daemon.yaml | Check `pipelines[].file` path is absolute and readable by daemon user |

### Pipeline Stuck / Hangs

**Symptom**: Job appears running indefinitely; no completion or error.

**Diagnosis**:

```bash
# Check health status
curl http://127.0.0.1:8080/health | jq '.scheduler'

# Enable pprof and capture goroutine dump
MM_PPROF=1 sudo systemctl restart mass-migrator
curl 'http://127.0.0.1:8080/debug/pprof/goroutine?debug=2' > goroutine.txt
grep "^goroutine" goroutine.txt | wc -l  # Count goroutines

# Look for blocked channels or I/O waits
grep -A 5 "chan send\|chan receive\|net.(*" goroutine.txt

# Check database connectivity
sudo -u mass-migrator mass-migrator ping-database --url "postgresql://localhost:5432/appdb?sslmode=disable"

# Check disk space / DLQ overflow
df -h /var/lib/mass-migrator
du -sh /var/lib/mass-migrator/dlq/
```

**Common causes and fixes**:

| Symptom | Cause | Fix |
|---------|-------|-----|
| No error, just hanging | Database connection hang | Increase DB pool size, check `max_connections` on DB, verify firewall |
| Goroutine explosion | Goroutine leak in script or operator | Check pipeline YAML for infinite loops in `transform` steps, file bug with goroutine dump |
| Memory growth | Dataset not released after pipeline | Check for circular dependencies in pipeline DAG, use `dataset.scope` to free unused data |
| Disk full (DLQ overflow) | Too many failed jobs queued | Clear DLQ (see DLQ section), fix underlying pipeline error, increase disk |

### Phantom Running Jobs

**Symptom**: Job shows "running" in `/health` but no process activity; doesn't complete after hours.

**Issue (Phase 1A finding)**: Earlier daemon versions had a heartbeat goroutine leak in `executeJob()` that prevented job completion updates. Phantom jobs survived daemon restart.

**Diagnosis**:

```bash
# List stuck jobs
echo "STATUS" | sudo socat - UNIX-CONNECT:/var/run/mass-migrator/control.sock | jq '.jobs[] | select(.status == "running")'

# Check actual process/goroutine count
ps aux | grep mass-migrator
curl 'http://127.0.0.1:8080/debug/pprof/goroutine?debug=1' | grep mass-migrator | wc -l
```

**Fix**:

1. **Upgrade to latest version** (Phase 2+ includes fixes)
2. **Manual cleanup** (if upgrade not possible):
   ```bash
   sudo systemctl stop mass-migrator
   sudo sqlite3 /var/lib/mass-migrator/state.db \
     "UPDATE jobs SET status = 'failed' WHERE status = 'running' AND updated_at < datetime('now', '-1 hour');"
   sudo systemctl start mass-migrator
   ```

### State Database Corruption

**Symptom**: Daemon fails to start with "database is locked" or "corrupt database" error.

**Diagnosis**:

```bash
# Check SQLite integrity
sudo sqlite3 /var/lib/mass-migrator/state.db "PRAGMA integrity_check;"

# Check WAL files
ls -la /var/lib/mass-migrator/state.db*

# Check permissions
stat /var/lib/mass-migrator/state.db | grep Access
```

**Fix**:

```bash
# SQLite recovery (standard WAL recovery)
sudo systemctl stop mass-migrator
sudo sqlite3 /var/lib/mass-migrator/state.db ".recover" | sqlite3 /tmp/recovered.db
sudo mv /var/lib/mass-migrator/state.db /tmp/state.db.corrupted
sudo mv /tmp/recovered.db /var/lib/mass-migrator/state.db
sudo chown mass-migrator:mass-migrator /var/lib/mass-migrator/state.db
sudo chmod 0600 /var/lib/mass-migrator/state.db
sudo systemctl start mass-migrator

# PostgreSQL point-in-time recovery
# (Use `pg_restore` with backup from pg_basebackup)
```

### License Expiry

**Symptom**: Daemon logs "license expired" on startup; only free-tier features available.

**Diagnosis**:

```bash
sudo journalctl -u mass-migrator | grep -i license
```

**Fix**:

1. Generate new license key from your account portal
2. Update `/etc/mass-migrator/daemon.yaml` or environment variable
3. Reload daemon: `sudo systemctl reload mass-migrator`

### Goroutine Leak / Memory Growth

**Symptom**: Memory usage grows over hours/days; goroutine count increases indefinitely.

**Diagnosis**:

```bash
# Enable profiling
MM_PPROF=1 sudo systemctl restart mass-migrator

# Baseline heap
curl 'http://127.0.0.1:8080/debug/pprof/heap' > /tmp/heap1.prof

# Wait 1 hour
sleep 3600

# Compare heap
curl 'http://127.0.0.1:8080/debug/pprof/heap' > /tmp/heap2.prof
go tool pprof -base /tmp/heap1.prof /tmp/heap2.prof

# Check goroutine growth
curl 'http://127.0.0.1:8080/debug/pprof/goroutine?debug=1' | head -1
```

**Common causes**:

- Goroutine leak in dataset operator (JOIN, UNION with circular dependencies)
- Transform script creating unbounded goroutines
- Database connection pool not released

**Fix**:

1. Capture heap + goroutine dumps and [file a bug](https://github.com/massmigrator/mass-migrator/issues) with profiles
2. Workaround: restart daemon weekly via cron: `0 2 * * 0 systemctl restart mass-migrator`
3. Check pipeline YAML for: circular dependencies, unbounded loops in transform, large datasets without scope isolation

### Out of Disk (DLQ Overflow)

**Symptom**: Daemon logs "no space left on device"; new jobs fail immediately.

**Diagnosis**:

```bash
# Check disk usage
df -h /var/lib/mass-migrator

# Check DLQ size
du -sh /var/lib/mass-migrator/dlq/

# Count failed jobs
find /var/lib/mass-migrator/dlq/ -type f | wc -l
```

**Fix**:

1. Stop daemon (in-flight jobs complete, no new jobs start)
2. Clean DLQ: `rm -rf /var/lib/mass-migrator/dlq/*` (or `find ... -mtime +30 -delete` for selective cleanup)
3. Check system logs for what caused failures (fix root issue)
4. Restart daemon

**Prevention**:

Set up automated disk monitoring:

```bash
# Add to crontab
0 */4 * * * [ $(du -sk /var/lib/mass-migrator/dlq | cut -f1) -gt 10485760 ] && \
  find /var/lib/mass-migrator/dlq -type f -mtime +14 -delete
```

---

## Integration with Monitoring

### Grafana Dashboard

TODO: Link to official Grafana dashboard (to be published).

Meanwhile, create a simple dashboard with panels for:

- **Gauge**: `in_flight` (current running jobs)
- **Counter**: `dropped_jobs` (cumulative failed jobs)
- **Time series**: `wait_time_ms` (job queue latency)
- **Time series**: `queue_size` (pending jobs)

### Alerting

Create alerts for operational issues:

**Disk usage**:
```
alert: DLQDiskFull
expr: (node_filesystem_avail_bytes{mountpoint="/var/lib/mass-migrator"} / node_filesystem_size_bytes) < 0.1
for: 5m
```

**Job failures**:
```
alert: DaemonJobFailures
expr: rate(mass_migrator_dropped_jobs[5m]) > 0.1
for: 10m
```

**Queue buildup**:
```
alert: DaemonQueueFull
expr: mass_migrator_queue_size > 50
for: 15m
```

**Memory growth**:
```
alert: DaemonMemoryLeak
expr: process_resident_memory_bytes{job="mass-migrator-daemon"} > 4e9
for: 30m
```

---

## Performance Tuning

### Worker Count

Tune `daemon.workers` based on:
- CPU cores: `workers = num_cores` for CPU-bound pipelines
- Database connections: `workers = pool_size / 2` (leave headroom for other clients)
- Memory per job: `total_memory / avg_job_memory`

Example: 8 cores, 20 DB connections, 500 MB/job, 4 GB daemon limit:
```yaml
daemon:
  workers: 8  # Use all cores
  # But also: 20 DB connections / 2 = 10 workers, limited by DB
  # And: 4 GB / 500 MB = 8 jobs, limited by memory
  # Net result: 8 workers (bottleneck is CPU or memory)
```

### Resource Limits

Adjust `systemd` unit file for your workload:

```ini
[Service]
MemoryMax=8G           # Increase if jobs are large
LimitNOFILE=100000     # If handling many files
TasksMax=8192          # If spawning many goroutines
```

Apply changes:
```bash
sudo systemctl daemon-reload
sudo systemctl restart mass-migrator
```

### Batch Size Tuning

In pipeline YAML, tune `batch_size` for write performance:

```yaml
- id: load_orders
  type: load
  batch_size: 10000    # Increase for bulk writes, decrease for memory-constrained
  threads: 4           # Match daemon.workers for parallelism
```

---

## Security Checklist

- [ ] Daemon runs as unprivileged `mass-migrator` user
- [ ] PID file is 0600 (daemon user only)
- [ ] Control socket is 0700 (daemon user only, peer-cred enforced)
- [ ] Config files contain no plaintext passwords (use env interpolation)
- [ ] Health server binds to localhost (127.0.0.1) only
- [ ] `/debug/pprof` is disabled by default (enable only for debugging)
- [ ] Systemd unit has hardened permissions (ProtectSystem=strict, NoNewPrivileges, etc.)
- [ ] Firewall rules restrict access to health server (no external exposure)
- [ ] License key stored in environment or protected file (0600 perms)
- [ ] Database credentials passed via env vars, not hardcoded in config
- [ ] Log files have restricted permissions (0640 by default, logrotate enforces)
- [ ] Backups of state DB are encrypted at rest (if applicable)

---

## Appendix: Example Daemon Config

See `contrib/daemon-example.yaml` for a complete multi-pipeline daemon config with best practices:

```yaml
---
daemon:
  # Critical for concurrency and recovery
  pid_file: "/var/run/mass-migrator/daemon.pid"
  control_socket: "/var/run/mass-migrator/control.sock"
  
  # Graceful shutdown window
  shutdown_timeout: 60s
  
  # Job heartbeat for detecting stuck executions
  heartbeat_interval: 10s
  
  # Default timezone for all cron schedules (can override per-pipeline)
  default_timezone: "+00:00"
  
  # Log output directory
  log_dir: "/var/log/mass-migrator"
  
  # Worker pool size — tune based on CPU cores and DB pool
  workers: 4

pipelines:
  # Reference to first pipeline
  - file: "/etc/mass-migrator/pipelines/sync_orders.yaml"
    enabled: true
  
  # Reference to second pipeline
  - file: "/etc/mass-migrator/pipelines/sync_customers.yaml"
    enabled: true
  
  # Disabled pipeline (loaded but not scheduled)
  - file: "/etc/mass-migrator/pipelines/full_reconciliation.yaml"
    enabled: false
```

Each pipeline file defines its own schedule and overlap policy (see Configuration section).
