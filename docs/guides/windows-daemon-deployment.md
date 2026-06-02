# Mass Migrator on Windows — Daemon Deployment Guide

> **Audience:** Windows sysadmins installing and operating Mass Migrator
> v3 in daemon mode on Windows Server 2022 (also supported on Server 2019
> and Windows 11 Pro).
> **Scope:** End-to-end installation, day-2 operations, observability,
> reload patterns, troubleshooting, and uninstall.

This is the canonical reference for running Mass Migrator as a Windows
service. If you are looking for Linux/systemd or macOS/launchd guidance,
see [`daemon-operations.md`](daemon-operations.md). For complete CLI flag
listings see [`cli-reference.md`](../cli-reference.md).

---

## Table of Contents

1. [Overview](#1-overview)
2. [Prerequisites](#2-prerequisites)
3. [Installation (recommended path)](#3-installation-recommended-path)
4. [Verifying installation](#4-verifying-installation)
5. [Managing the service](#5-managing-the-service)
6. [Reloading configuration](#6-reloading-configuration)
7. [Logs and observability](#7-logs-and-observability)
8. [Configuration reference](#8-configuration-reference)
9. [Pipeline placement and discovery](#9-pipeline-placement-and-discovery)
10. [Uninstall](#10-uninstall)
11. [Troubleshooting](#11-troubleshooting)
12. [Differences from Linux/macOS](#12-differences-from-linuxmacos)
13. [Comparison: daemon vs Task Scheduler](#13-comparison-daemon-vs-task-scheduler)

---

## 1. Overview

The Mass Migrator daemon is a background service that runs scheduled
database migration, ETL, and incremental-sync pipelines on a cron schedule.
On Windows it is a first-class citizen of the operating system — it is
hosted by the Service Control Manager (SCM), writes lifecycle events to
the Windows Event Log, and exposes a control plane over a named pipe with
a restrictive SDDL ACL.

### What the daemon does on Windows

| Concern | Implementation |
|---|---|
| Process supervision | Windows SCM (`services.msc`, `sc.exe`, `Get-Service`) |
| Auto-start on boot | SCM `StartType=Automatic`, set at install time |
| Reload without restart | SCM user-defined control code **128**, `mass-migrator daemon reload` control-socket command, OR `Restart-Service` |
| Graceful shutdown | SCM Stop/Shutdown → daemon cancels context → in-flight jobs drain within `shutdown_timeout` |
| Control plane | Named pipe `\\.\pipe\mass-migrator`, SDDL restricted to Owner + `BUILTIN\Administrators` |
| Pipeline registration | Explicit `pipelines:` list in `daemon.yaml` AND/OR auto-discovery via `pipelines_dir` (`*.yaml` / `*.yml`) with optional fsnotify hot-reload |
| Lifecycle events (start/stop/reload/fatal) | Windows Event Log, source `mass-migrator`, log `Application` |
| Routine job logs | Rotating text file at `%PROGRAMDATA%\mass-migrator\logs\daemon.log` |
| HTTP observability (optional) | `health_addr` opens loopback-only HTTP server with `/health`, `/metrics` (Prometheus), `/status` |
| Cron scheduling | Per-pipeline `daemon.schedule` YAML field (5-field cron) |
| Concurrency | Worker pool sized by `daemon.workers` in `daemon.yaml`; per-pipeline `overlap_policy` |

The daemon is a single self-contained Go binary. There is no .NET runtime
requirement, no native package manager dependency, and no PowerShell
modules to install at runtime — only the bootstrap PowerShell scripts in
`contrib/` need elevation.

### What this guide does NOT cover

- Writing pipeline YAML — see [`pipeline-mixed-stages-guide.md`](pipeline-mixed-stages-guide.md)
- Cron expression syntax — see [`daemon-operations.md`](daemon-operations.md#cron-expressions)
- Database connection tuning — see [`performance-optimization.md`](performance-optimization.md)
- Error handlers and finalizers — see [`pipeline-error-handling.md`](pipeline-error-handling.md)

---

## 2. Prerequisites

### Supported hosts

| OS | Status | Notes |
|---|---|---|
| Windows Server 2022 | **Supported** (primary target) | Verified in CI on `windows-2022` runners |
| Windows Server 2019 | Supported | Same code path; CI does not gate but no known issues |
| Windows 11 Pro / Enterprise | Supported for evaluation and developer hosts | SCM is identical to Server SKUs |
| Windows 10 (any edition) | Best-effort | Not part of the CI matrix |
| Windows Server Core | Supported | Headless install path is identical |

### Required permissions

You must run the installer from an **elevated PowerShell prompt** (right-
click PowerShell → *Run as Administrator*). Day-to-day service operations
(start, stop, query) can be delegated to any account that has SCM rights
on the service object — see [Managing the service](#5-managing-the-service).

### Software prerequisites

| Component | Required version | Notes |
|---|---|---|
| Windows PowerShell | 5.1 | Pre-installed on every supported Windows SKU |
| PowerShell 7 (`pwsh`) | 7.0+ | Optional; `install.ps1` runs unchanged under both shells |
| .NET runtime | **Not required** | The binary is statically linked Go |
| Visual C++ runtime | Not required | No DLL dependencies beyond `kernel32`, `advapi32`, etc. |
| Microsoft Defender exclusion | Recommended | Exclude `C:\Program Files\mass-migrator\mass-migrator.exe` and `%PROGRAMDATA%\mass-migrator\` to avoid AV scan latency on large pipeline runs |

### Network requirements

The daemon needs outbound network access to:

- Every source/target database referenced in your pipeline YAML (SQL
  Server, PostgreSQL, MySQL, Oracle, SQLite is local-only).
- Optional: Kafka brokers, S3 endpoints, or remote state-store databases
  if those features are wired in.

The daemon itself does **not** listen on any TCP port by default — the
control plane is a Windows named pipe, not a socket. See the
[control plane](#named-pipe-control-plane) section below if you must
expose a TCP listener for cross-host control.

### Disk layout assumed by this guide

| Path | Role | Default permissions |
|---|---|---|
| `C:\Program Files\mass-migrator\` | Binary (`mass-migrator.exe`) | Inherited from `Program Files` — Admin write, Authenticated Users read |
| `%PROGRAMDATA%\mass-migrator\` | Data root | Inherited from `ProgramData` — Admin write, Authenticated Users read |
| `%PROGRAMDATA%\mass-migrator\daemon.yaml` | Daemon config | Write: SYSTEM + Admins (per ProgramData ACL) |
| `%PROGRAMDATA%\mass-migrator\pipelines\` | Pipeline YAML files | Drop directory |
| `%PROGRAMDATA%\mass-migrator\state\` | SQLite state DB (default backend) | Service account writable |
| `%PROGRAMDATA%\mass-migrator\logs\` | Rotated text logs | Service account writable |
| `%PROGRAMDATA%\mass-migrator\daemon.pid` | PID file written at startup | Service account writable |

`%PROGRAMDATA%` resolves to `C:\ProgramData` on a default install — both
literals are used interchangeably in commands throughout this guide.

---

## 3. Installation (recommended path)

The recommended path uses the bundled PowerShell installer
(`contrib/install.ps1`). It is idempotent — re-running it does not
clobber an operator's edited `daemon.yaml` or pipeline files, and the
SCM and Event Log registrations are no-ops when already present.

### Step 1 — Download the release zip

Download the Windows release archive from the public mirror:

> https://github.com/avntct/mass-migrator/releases

The zip contains:

- `mass-migrator.exe` — the daemon + CLI binary (amd64; arm64 also published)
- `contrib\install.ps1`, `contrib\uninstall.ps1` — bootstrap scripts
- `contrib\daemon-example-windows.yaml`, `contrib\pipeline-example-windows.yaml` — seed configs
- `LICENSE`, `README.md`, `CHANGELOG.md`

Verify the checksum against the published `checksums.txt`:

```powershell
Get-FileHash .\mass-migrator_3.x.y_windows_amd64.zip -Algorithm SHA256
# Compare against the value in checksums.txt
```

If you build from source instead, copy `mass-migrator.exe` and the
`contrib/` directory into a single staging folder and continue from
step 3.

### Step 2 — Extract

Extract the zip to a working directory of your choosing. The installer
does not care where you extract — it copies the binary into
`C:\Program Files\mass-migrator\` from wherever you run it.

```powershell
Expand-Archive .\mass-migrator_3.x.y_windows_amd64.zip -DestinationPath C:\tmp\mass-migrator-staging
cd C:\tmp\mass-migrator-staging
```

### Step 3 — Open an elevated PowerShell prompt

Right-click the PowerShell icon and choose **Run as Administrator**. The
installer aborts immediately if it is not running with administrator
privileges (it cannot register an SCM service or an Event Log source
without elevation).

### Step 4 — Run the installer

**Default install (recommended):**

```powershell
.\contrib\install.ps1
```

**Custom paths:**

```powershell
.\contrib\install.ps1 `
    -InstallDir D:\mass-migrator `
    -DataDir    D:\mass-migrator\data `
    -NoStart
```

**Parameters:**

| Parameter | Default | Effect |
|---|---|---|
| `-BinaryPath` | `.\mass-migrator.exe` | Source binary to copy into the install dir |
| `-InstallDir` | `C:\Program Files\mass-migrator` | Where the binary lives |
| `-DataDir` | `%PROGRAMDATA%\mass-migrator` | Where `daemon.yaml`, `pipelines\`, `state\`, `logs\` live |
| `-NoStart` | (off) | Skip the final `Start-Service`; install but do not start |

### What `install.ps1` does

In order:

1. **Asserts elevation.** Aborts if the current principal is not in `BUILTIN\Administrators`.
2. **Resolves the binary path.** Fails fast if `mass-migrator.exe` is missing.
3. **Creates the directory tree.**
   - `$InstallDir\`
   - `$DataDir\`, `$DataDir\pipelines\`, `$DataDir\state\`, `$DataDir\logs\`
4. **Copies the binary** into `$InstallDir\mass-migrator.exe`. Overwrites
   on every run so upgrade-in-place is `install.ps1` again with the new
   binary.
5. **Seeds example configs** — but only if absent. Operator edits to
   `daemon.yaml` and `pipelines\example.yaml` are preserved on re-runs.
6. **Registers the Event Log source** `mass-migrator` against the
   `Application` log. Idempotent — uses
   `[System.Diagnostics.EventLog]::SourceExists()` to short-circuit.
7. **Registers the service with the SCM** by invoking
   `mass-migrator.exe daemon service install` with the resolved binary
   and config paths. The subcommand itself is idempotent and reports
   "service already exists" when re-run.
8. **Starts the service** via `Start-Service mass-migrator` and waits
   up to 30 seconds for `Running` (skipped when `-NoStart` is passed).
9. **Prints a summary table** of service name, status, paths, and Event
   Log source.

The full script is at `contrib/install.ps1`; read it before running on
production hosts if your security policy requires it.

---

## 4. Verifying installation

Run these four checks in order. If any one fails, jump to
[Troubleshooting](#11-troubleshooting).

### Check 1 — Service is running

```powershell
Get-Service -Name mass-migrator
```

Expected output:

```
Status   Name               DisplayName
------   ----               -----------
Running  mass-migrator      Mass Migrator Daemon
```

If `Status` is `Stopped`, see [Service won't start](#service-wont-start)
in the troubleshooting table.

### Check 2 — Event Log shows lifecycle entries

```powershell
Get-WinEvent -LogName Application -ProviderName mass-migrator -MaxEvents 5 |
    Format-Table TimeCreated, Id, LevelDisplayName, Message -AutoSize
```

Expected: at least one entry with `Id=100` and a message containing
`scheduled mass-migrator daemon starting`. Lifecycle event IDs:

| Event ID | Severity | Meaning |
|---|---|---|
| 100 | Information | Daemon start |
| 101 | Information | Daemon stop |
| 102 | Information | Daemon reload |
| 103 | Information | Daemon shutdown (received signal) |
| 200 | Error | Fatal error during start |

If `Get-WinEvent` returns no provider entries, the Event Log source is
not registered — re-run `install.ps1` from an elevated prompt.

### Check 3 — Service status via the daemon's own CLI

```powershell
& 'C:\Program Files\mass-migrator\mass-migrator.exe' daemon service status
```

Expected output:

```
Service: mass-migrator
  State: running
  PID:   12345
```

JSON form for scripting:

```powershell
& 'C:\Program Files\mass-migrator\mass-migrator.exe' daemon service status --json
```

```json
{
  "ok": true,
  "service": "mass-migrator",
  "state": "running",
  "pid": 12345
}
```

The `status` verb reads from the SCM. The state field is one of:
`stopped`, `start-pending`, `stop-pending`, `running`, `continue-pending`,
`pause-pending`, `paused`, `unknown`.

### Check 4 — Daemon log file exists and is being written

```powershell
Get-Content 'C:\ProgramData\mass-migrator\logs\daemon.log' -Tail 20
```

You should see lines like:

```
INFO  Starting scheduled mass-migrator daemon...
INFO  Discovered 1 pipeline(s)
INFO  Registered job: example.yaml (schedule: */5 * * * *)
INFO  Daemon started with PID 12345 (1 jobs registered)
```

To follow in real time:

```powershell
Get-Content 'C:\ProgramData\mass-migrator\logs\daemon.log' -Wait
```

---

## 5. Managing the service

Mass Migrator exposes **two distinct management surfaces** on Windows.
Pick the right one for the operation you have in mind — they look
similar at the command line but talk to completely different layers.

### Two surfaces, one binary

| Surface | What it controls | Command family | Talks to |
|---|---|---|---|
| **SCM-level** (service registration) | Windows-service lifecycle: install, start, stop, restart, uninstall | `mass-migrator daemon service ...` (also `Start-Service`, `sc.exe`) | Service Control Manager API |
| **Daemon-runtime-level** (the running process) | The live daemon process: graceful reload, runtime status, graceful stop | `mass-migrator daemon reload` / `status` / `stop` | Named pipe `\\.\pipe\mass-migrator` |

Both surfaces are served by the same `mass-migrator.exe` binary that
`install.ps1` drops into `C:\Program Files\mass-migrator\`. The
standalone `daemon` binary still exists internally for SCM hosting
(it is what the SCM actually launches), but operators **do not invoke
it directly** — every operator-facing command is reachable through the
main `mass-migrator` binary.

> **Rule of thumb:** if you want to install/uninstall the service or
> change its SCM state (Stopped ↔ Running), reach for the **SCM-level**
> commands. If the service is already running and you want to nudge it
> without changing its SCM state — reload config, fetch live status,
> trigger a graceful drain — reach for the **runtime-level** commands.

### Three ways to drive the SCM surface

For SCM operations specifically, you have three equivalent toolchains
that all converge on the same SCM API calls.

| Toolchain | When to use | Output |
|---|---|---|
| **PowerShell cmdlets** | Ad-hoc admin, interactive shells, mixed-OS PowerShell runbooks | Human-readable; structured via `Get-Service \| ConvertTo-Json` |
| **`sc.exe`** | Legacy batch scripts, Group Policy startup scripts, environments where PowerShell is locked down | Compact text; well-documented exit codes |
| **`mass-migrator daemon service ...`** | Same automation that drives non-Windows installs; want JSON output by default; want platform-consistent behaviour | Plain text or JSON via `--json` |

### PowerShell cmdlets

```powershell
# Start
Start-Service -Name mass-migrator

# Stop
Stop-Service -Name mass-migrator

# Restart
Restart-Service -Name mass-migrator

# Query status
Get-Service -Name mass-migrator

# Query with full detail
Get-Service -Name mass-migrator | Format-List *

# Wait for a specific status
(Get-Service mass-migrator).WaitForStatus('Running', '00:00:30')
```

`Stop-Service` blocks until the service reaches the `Stopped` state or
the timeout fires. The daemon's graceful shutdown drains in-flight jobs
within `shutdown_timeout` (default `60s`); raise it in `daemon.yaml` if
your pipelines have long-running steps.

### `sc.exe` (Service Control utility)

```cmd
sc.exe start mass-migrator
sc.exe stop mass-migrator
sc.exe query mass-migrator
sc.exe queryex mass-migrator   :: includes PID
sc.exe qc mass-migrator        :: shows binPath, start type, dependencies
```

`sc.exe control mass-migrator 128` is the **reload** path — see
[Reloading configuration](#6-reloading-configuration).

### Mass Migrator's own subcommands

These wrap the same SCM API calls as `sc.exe` but produce JSON for
scripting and behave consistently on Linux (where they degrade
gracefully with exit code 2 and a redirect message).

```powershell
# Start
mass-migrator daemon service start

# Stop
mass-migrator daemon service stop

# Restart (Stop + Start; tolerates "already stopped")
mass-migrator daemon service restart

# Query status
mass-migrator daemon service status
mass-migrator daemon service status --json

# Custom service name
mass-migrator daemon service status --name mm-prod
```

All subcommands accept:

| Flag | Default | Effect |
|---|---|---|
| `--name` | `mass-migrator` | SCM service identifier |
| `--json` | (off) | Emit machine-readable JSON instead of human-readable text |

The `--json` flag emits a stable schema on both success and failure, so
a single decoder consumes both branches:

```json
{
  "ok": true,
  "verb": "start",
  "service": "mass-migrator",
  "message": "service start requested"
}
```

Exit codes:

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Operator/SCM error (already running, not found, access denied, etc.) |
| 2 | Wrong platform — you ran a Windows-only verb on Linux/macOS |

### Daemon-runtime control verbs

These verbs dial the daemon's **control socket** (named pipe on
Windows) and ask the live process to do something. The SCM is not
involved — `Get-Service` reports `Running` throughout. They are the
operator-friendly equivalent of "send the daemon a signal".

```powershell
mass-migrator daemon reload   # re-read config, apply pipeline changes
mass-migrator daemon status   # uptime, registered pipelines, running jobs
mass-migrator daemon stop     # graceful shutdown; drains within shutdown_timeout
```

Note: `daemon status` is distinct from `daemon service status` — the
latter queries the SCM, the former queries the running daemon itself.

All three verbs accept the same flags:

| Flag | Default | Effect |
|---|---|---|
| `--socket` | `--socket` flag → `MASS_MIGRATOR_CONTROL_SOCKET` env var → platform default (`\\.\pipe\mass-migrator` on Windows) | Path to the daemon's control socket |
| `--timeout` | `5s` | Caps dial + I/O wait against an unresponsive daemon |
| `--json` | (off) | Emit a JSON envelope for scripting |

Exit codes (stable contract — wire these into automation):

| Code | Meaning |
|---|---|
| 0 | Command succeeded; daemon acknowledged |
| 1 | Daemon unreachable (socket missing, no listener, refused) |
| 2 | Daemon replied with `ERR ...` (e.g. reload failed validation) |
| 3 | Dial or I/O exceeded `--timeout` |

JSON envelope (same shape on both success and failure — `ok` flips,
`response` is replaced by `error` on failure):

```json
{ "ok": true,  "verb": "reload", "socket": "\\\\.\\pipe\\mass-migrator", "response": "OK reload scheduled" }
{ "ok": false, "verb": "reload", "socket": "\\\\.\\pipe\\mass-migrator", "error": "dial: ..." }
```

> **Access note:** the named pipe is SDDL-protected (Owner +
> `BUILTIN\Administrators`). A non-admin caller will see exit code 1
> with `Access is denied`. Use `sc.exe control mass-migrator 128`
> instead from a less-privileged account that you've explicitly
> granted `SERVICE_USER_DEFINED_CONTROL` to.

### Programmatic status checks

For monitoring or health-check scripts:

```powershell
$result = & 'C:\Program Files\mass-migrator\mass-migrator.exe' daemon service status --json |
    ConvertFrom-Json

if ($result.state -eq 'running') {
    Write-Host "Daemon healthy (PID $($result.pid))"
} else {
    Write-Warning "Daemon not running: $($result.state)"
    exit 1
}
```

---

## 6. Reloading configuration

Mass Migrator supports configuration reload **without dropping the
service from `Running` state**. The reload re-reads `daemon.yaml`,
re-discovers pipelines from the explicit list *and* (when configured)
from `pipelines_dir`, and diffs the live scheduler against the desired
set:

- New pipeline entries → jobs added
- Removed entries → jobs cancelled and unregistered
- Changed `schedule` or `timezone` → job removed and re-added with new
  cron spec

In-flight pipeline runs are **not** interrupted. Reload only affects the
scheduler's next-tick decisions.

> **Tip:** if you set `pipelines_dir` with `pipelines_dir_watch: true`
> (the default), the daemon reloads automatically within ~200 ms when a
> YAML file in the directory is created, modified, or removed. You
> rarely need to trigger reload manually in that mode — see
> [Pipeline placement and discovery](#9-pipeline-placement-and-discovery).

### Three equivalent reload paths

All three converge on the same `ScheduledDaemon.Reload()` method inside
the daemon process and are functionally equivalent for the purpose of
re-applying a config change.

| Path | Command | When to use |
|---|---|---|
| Restart-Service | `Restart-Service mass-migrator` | You want a clean slate; brief downtime is acceptable |
| SCM control 128 | `sc.exe control mass-migrator 128` | Graceful reload, zero downtime; pure Windows tooling |
| Control-socket RELOAD | `mass-migrator daemon reload` | Graceful reload via the named pipe; no service-state touch; same syntax as Linux/macOS |

#### Path 1 — Restart-Service

```powershell
Restart-Service -Name mass-migrator
```

This is **not** a hot-reload — the daemon process exits, the SCM
launches a new one, and there is a brief window (typically <2 seconds)
where the daemon is not scheduling jobs. Use it when you changed a
startup-only field (`control_socket`, `pid_file`, `log_dir`,
`health_addr`) or want to wipe stale in-memory state.

#### Path 2 — SCM user-defined control code 128

```cmd
sc.exe control mass-migrator 128
```

The daemon registers `128` as a user-defined SCM control code at startup.
On receipt, the service handler invokes `ScheduledDaemon.Reload()`
without changing the SCM state — `Get-Service` continues to report
`Running` throughout. Event Log entry ID `102` is written on completion.
Use this when scripting reload from cmd.exe, Group Policy, or any tool
that speaks `sc.exe`, and you want the action audited.

#### Path 3 — `mass-migrator daemon reload` (recommended for operators)

```powershell
mass-migrator daemon reload
# or, with a tight timeout for health-check loops:
mass-migrator daemon reload --timeout 2s --json
```

This is the operator-friendly form. It dials the named pipe
`\\.\pipe\mass-migrator` and writes the `RELOAD\n` text command — the
same wire protocol used by SCM control 128 underneath, but reachable
from any shell without `sc.exe` and with stable exit codes plus an
optional JSON envelope. See
[Daemon-runtime control verbs](#daemon-runtime-control-verbs) for the
full flag and exit-code reference.

#### Named-pipe control plane

The named pipe `\\.\pipe\mass-migrator` is protected by SDDL:

```
D:P(A;;GA;;;OW)(A;;GA;;;BA)
```

Which grants `GENERIC_ALL` to the pipe **Owner** (the daemon's effective
SID) and **`BUILTIN\Administrators`**. Every other caller — including
non-admin operators — receives `ACCESS_DENIED` at the kernel before any
bytes are read. There is also a second imperative SID check inside the
daemon's `authorizePeer` routine as defense in depth.

If you need to issue reload from a non-admin caller, switch to SCM
control 128 and grant that account the `SERVICE_USER_DEFINED_CONTROL`
right on the service object via `sc.exe sdset`.

---

## 7. Logs and observability

The daemon produces three log streams. Each has a distinct purpose and a
distinct retention story.

| Stream | Destination | Lifecycle |
|---|---|---|
| Routine job logs | Rotating text file (`%PROGRAMDATA%\mass-migrator\logs\daemon.log`) | Built-in size-based rotation |
| Lifecycle events | Windows Event Log, source `mass-migrator`, log `Application` | OS-managed retention |
| Per-pipeline logs | One file per pipeline under `logs\` | Created on first run; not rotated |

### File logs and rotation

The daemon writes structured human-readable lines to `daemon.log`. On
Windows, log rotation is **enabled by default** (it is off on Linux/macOS
because external `logrotate` is the convention there). When the file
exceeds the size threshold, the daemon renames it to `daemon.log.1`,
shifts older backups down (`daemon.log.1` → `daemon.log.2`, ...), and
deletes anything older than the retention count.

Defaults:

| Knob | YAML key | Default | Range |
|---|---|---|---|
| Enabled | `log_rotate_enabled` | `true` (Windows) | bool |
| Max file size | `log_rotate_max_mb` | `100` MB | positive integer |
| Backup count | `log_rotate_max_files` | `7` | positive integer |

Override by editing `daemon.yaml`:

```yaml
daemon:
  log_rotate_enabled: true
  log_rotate_max_mb: 200
  log_rotate_max_files: 14
```

Reload (`sc.exe control mass-migrator 128`) does **not** re-open the
rotating file handle; rotation knob changes take effect on the next
`Restart-Service`. Size and backup-count limits apply continuously once
rotation is enabled.

### Windows Event Log

The daemon emits **lifecycle-only** entries to the Event Log — start,
stop, reload, fatal-error. Routine per-job execution stays in the file
log so the Event Log does not become noisy.

Query interactively:

```powershell
# Last 20 lifecycle entries
Get-WinEvent -LogName Application -ProviderName mass-migrator -MaxEvents 20 |
    Format-Table TimeCreated, Id, LevelDisplayName, Message -AutoSize

# Only errors
Get-WinEvent -FilterHashtable @{
    LogName      = 'Application'
    ProviderName = 'mass-migrator'
    Level        = 2          # Error
} -MaxEvents 50

# Last hour
Get-WinEvent -FilterHashtable @{
    LogName      = 'Application'
    ProviderName = 'mass-migrator'
    StartTime    = (Get-Date).AddHours(-1)
}
```

Event IDs were already listed in [Verifying installation](#check-2--event-log-shows-lifecycle-entries).

### Forwarding to a SIEM

The supported pattern is **Windows Event Forwarding (WEF)**. Configure a
subscription on your WEF collector that targets the `Application` log
filtered by `ProviderName='mass-migrator'`. From there pipe to Splunk,
ELK, Sentinel, or whatever your SOC uses.

WEF subscription XML filter example:

```xml
<QueryList>
  <Query Id="0">
    <Select Path="Application">
      *[System[Provider[@Name='mass-migrator']]]
    </Select>
  </Query>
</QueryList>
```

File logs can be tailed by a forwarder agent (NXLog, Winlogbeat,
Filebeat) pointed at `%PROGRAMDATA%\mass-migrator\logs\daemon.log`.

### Metrics and health endpoints

When `health_addr` is set in `daemon.yaml`, the SCM-registered daemon
starts an HTTP server on that address as part of its normal startup
sequence. There is **no** longer a "foreground only" caveat — the same
endpoints are available whether the daemon is running interactively or
as a Windows service.

```yaml
daemon:
  # ... other settings ...
  health_addr: "127.0.0.1:9090"
```

Endpoints served:

| Path | Format | Purpose |
|---|---|---|
| `GET /health` | JSON `{"status":"ok","uptime_seconds":N}` | Liveness probe. Returns HTTP 503 with `status:"shutting_down"` during graceful shutdown so external load balancers stop forwarding work. |
| `GET /metrics` | Prometheus text exposition (`text/plain; version=0.0.4`) | Daemon-level gauges (`daemon_uptime_seconds`, `pipelines_registered_total`, `pipeline_jobs_running`) plus per-pipeline counters (`pipeline_job_runs_total{pipeline="<name>"}`, `pipeline_last_run_timestamp_seconds{pipeline="<name>"}`). |
| `GET /status` | JSON | Full daemon snapshot: config summary (`workers`, `default_timezone`, `health_addr`, `pipelines_count`), all registered pipelines with their schedules, and the subset currently running. |

#### Security: loopback-only by default

The daemon **refuses to bind to non-loopback addresses** — this is a
hard rule, not a tuning knob. The bind validator accepts:

- `127.0.0.1` (and any `127.x.x.x` address)
- `localhost`
- `::1`

Any other host triggers a startup error like:

```
health server: must bind to loopback (127.0.0.0/8, localhost, or ::1), got "10.1.2.3"
```

If the address is already bound by another process, the daemon **fails
to start** with a clear error rather than silently degrading without
metrics. This is deliberate: operators rely on `/metrics` for fleet-wide
alerting, so silent unavailability would be worse than a startup failure.

#### Remote scraping pattern

For remote scraping, front the loopback endpoint with a reverse proxy
(IIS, nginx-for-Windows, Caddy) bound to the LAN interface with TLS
and Windows authentication. Minimal Prometheus scrape config — same
shape for a local agent or a remote proxy, just swap the target:

```yaml
scrape_configs:
  - job_name: mass-migrator
    scrape_interval: 30s
    static_configs:
      - targets: ['127.0.0.1:9090']  # or '<lan-ip>:<proxy-port>'
```

When the daemon stops, the HTTP server drains in-flight requests with
a 5-second timeout before closing the listener, so a quick
`Restart-Service` does not race against a still-bound port.

---

## 8. Configuration reference

The daemon's behaviour is driven entirely by `daemon.yaml` plus the
pipeline files it references. The canonical key reference lives in
[`cli-reference.md`](../cli-reference.md). Below are the keys that have
Windows-specific guidance.

### Windows-specific knobs

| YAML key | Value on Windows | Notes |
|---|---|---|
| `daemon.control_socket` | `"\\\\.\\pipe\\mass-migrator"` | **Required exact value.** Validator rejects anything that isn't a `\\.\pipe\` or `\\?\pipe\` path on Windows. Don't change unless you also change the daemon's hard-coded service name. |
| `daemon.pid_file` | e.g. `C:/ProgramData/mass-migrator/daemon.pid` | Must be writable by the service account. Use forward slashes OR escape backslashes (`C:\\ProgramData\\...`) — YAML treats single backslashes as line continuations and will silently corrupt the path. |
| `daemon.log_dir` | e.g. `C:/ProgramData/mass-migrator/logs` | Same path-quoting caveat. The daemon creates the directory on startup if missing. |
| `daemon.log_rotate_enabled` | `true` (default) | Always set explicitly on Windows so the intent is auditable. |
| `daemon.shutdown_timeout` | `60s`–`300s` | Set higher than your worst-case pipeline so the SCM does not force-kill mid-transaction. |
| `daemon.workers` | 1–100 | Worker pool size. Controls the maximum number of pipelines running concurrently. |
| `daemon.pipelines_dir` | e.g. `C:/ProgramData/mass-migrator/pipelines` | Optional directory the daemon scans for `*.yaml` / `*.yml` pipeline definitions at startup. Coexists with the explicit `pipelines:` list — see [§9](#9-pipeline-placement-and-discovery). Empty (default) disables auto-discovery; the daemon then requires the explicit list. |
| `daemon.pipelines_dir_watch` | `true` (default when `pipelines_dir` set) | fsnotify-based hot reload. Add/modify/delete a YAML file in the directory → daemon reloads within ~200 ms. Set to `false` for one-shot scan-at-startup behaviour. Ignored when `pipelines_dir` is empty. |
| `daemon.health_addr` | e.g. `127.0.0.1:9090` | Optional. When set, the daemon binds an HTTP server serving `/health`, `/metrics`, `/status`. **Loopback-only:** non-loopback hosts cause the daemon to fail startup. Empty (default) disables the HTTP surface entirely. See [§7](#7-logs-and-observability). |

### Path quoting rules for Windows YAML

YAML interprets a single backslash before certain characters as an
escape. The safe forms, in order of preference:

1. **Forward slashes** — accepted by every Windows API the daemon uses:

   ```yaml
   pid_file: "C:/ProgramData/mass-migrator/daemon.pid"
   log_dir:  "C:/ProgramData/mass-migrator/logs"
   ```

2. **Double-quoted with escaped backslashes** — for the control socket
   specifically, because the `\\.\pipe\` syntax is *not* a filesystem
   path and forward slashes change its meaning:

   ```yaml
   control_socket: "\\\\.\\pipe\\mass-migrator"
   ```

3. **Single-quoted with literal backslashes** — works because YAML does
   not process escapes inside single quotes, but bracket-matching tools
   often misread these. Avoid in shared configs.

### State backend choice

The daemon tracks job execution state in an embedded store. Backends:

| Backend | Setup cost | Concurrency | Notes |
|---|---|---|---|
| `sqlite` (default) | Zero — file in `state\` | `MaxOpenConns=1` (WAL mode); writes serialised | Fine for ≤4 workers and ≤100 events/sec |
| `postgres` | Requires reachable PG instance | High; designed for write-heavy workloads | Use when you already operate Postgres |
| `mysql`, `sqlserver`, `oracle` | Production-quality backends | High | Match whatever your DBA prefers |

SQLite is the right answer for most single-host Windows deployments.
Switch to PostgreSQL only when you have an operations team that already
runs it, or when you cross the SQLite concurrency ceiling.

### Example: minimal Windows `daemon.yaml`

```yaml
---
daemon:
  pid_file:        "C:/ProgramData/mass-migrator/daemon.pid"
  control_socket:  "\\\\.\\pipe\\mass-migrator"
  shutdown_timeout: 60s
  heartbeat_interval: 10s
  default_timezone: "+00:00"
  log_dir:         "C:/ProgramData/mass-migrator/logs"
  workers:         4

  # Windows-default rotation; explicit for clarity.
  log_rotate_enabled:   true
  log_rotate_max_mb:    100
  log_rotate_max_files: 7

  # Optional auto-discovery: drop *.yaml / *.yml files into this dir
  # and the daemon picks them up automatically; runtime edits trigger a
  # debounced reload within ~200ms. Comment out to require explicit
  # `pipelines:` listing only.
  pipelines_dir:       "C:/ProgramData/mass-migrator/pipelines"
  pipelines_dir_watch: true

  # Optional HTTP observability surface. Loopback-only; the daemon
  # refuses to bind to non-loopback hosts. Comment out to disable.
  health_addr:         "127.0.0.1:9090"

# Explicit pipelines (optional when pipelines_dir is set). On a name
# collision the explicit entry wins and the directory copy is dropped
# with a warning logged.
pipelines:
  - file:    "C:/ProgramData/mass-migrator/pipelines/example.yaml"
    enabled: true
```

For the full per-pipeline schema (`daemon.schedule`, `overlap_policy`,
`run_immediately`, `timezone`), see the pipeline files seeded by
`install.ps1` under `pipelines\example.yaml`, or read
[`daemon-operations.md`](daemon-operations.md).

---

## 9. Pipeline placement and discovery

The daemon supports **two complementary discovery mechanisms**. Pick
whichever fits your operations model — or combine them.

| Mechanism | YAML key | Best for |
|---|---|---|
| **Explicit list** | `pipelines:` (top-level) | Production deployments where `daemon.yaml` lives under version control and every active pipeline is auditable in one file. |
| **Directory auto-discovery** | `daemon.pipelines_dir` (+ optional `pipelines_dir_watch`) | Environments where pipelines are dropped in by tooling, by operators editing files in a shared folder, or by a Group Policy / Configuration Manager workflow. |

Both mechanisms can be active at the same time. On a pipeline-`name:`
collision the explicit entry wins and the directory copy is dropped
with a warning logged to `daemon.log`.

### Mechanism A — Explicit list

```yaml
pipelines:
  - file:    "C:/ProgramData/mass-migrator/pipelines/sync_orders.yaml"
    enabled: true
  - file:    "C:/ProgramData/mass-migrator/pipelines/etl_customers.yaml"
    enabled: true
  - file:    "C:/ProgramData/mass-migrator/pipelines/full_reconciliation.yaml"
    enabled: false   # Listed but skipped — toggle without deletion
```

Use this when you want **every** pipeline that the daemon schedules to
appear in `daemon.yaml` for review by configuration management. Drop
files into a directory freely; until they are listed here, they are
inert. The `enabled` flag toggles a pipeline without removing it from
the list.

### Mechanism B — Directory auto-discovery

```yaml
daemon:
  pipelines_dir:       "C:/ProgramData/mass-migrator/pipelines"
  pipelines_dir_watch: true   # default when pipelines_dir is set
```

At **startup** the daemon scans `pipelines_dir` non-recursively and
registers every well-formed `*.yaml` or `*.yml` file it finds. Each
discovered file is treated as if it had appeared in the explicit list
with `enabled: true`.

At **runtime** — when `pipelines_dir_watch: true`, which is the default
whenever `pipelines_dir` is set — the daemon uses fsnotify to observe
the directory. Add/modify/delete events trigger a daemon-level reload
after a **200 ms debounce window** (which folds the multiple events
emitted by editor "save" sequences into a single reload).

**File naming rules:**

- Any `.yaml` or `.yml` extension is accepted (case-insensitive).
- Dotfiles, backup suffixes, and editor swap files (`.yaml~`, `.yaml.bak`)
  are ignored, so editor activity does not trigger spurious reloads.
- The pipeline's `name:` field — not the filename — is what identifies
  it for scheduling and for collision detection against the explicit
  list. Two files named `orders.yaml` and `orders-v2.yaml` are
  different pipelines only if their internal `name:` differs.

**Error handling:**

- A file whose YAML fails to parse is logged with a warning and
  **skipped**. The daemon stays up and continues registering the other
  files — one bad pipeline never crashes the daemon.
- An unreadable `pipelines_dir` (deleted, permission denied) is logged
  and the daemon falls back to whatever the explicit list provides.
  If both the dir and the explicit list are missing, the config
  validator rejects `daemon.yaml` outright at startup.

### Combining both mechanisms

A common production layout uses an explicit list for critical,
audited pipelines (under version control) plus a `dropin\` directory
for ops-driven additions:

```yaml
daemon:
  pipelines_dir: "C:/ProgramData/mass-migrator/pipelines/dropin"

pipelines:
  - file:    "C:/ProgramData/mass-migrator/pipelines/core/critical_etl.yaml"
    enabled: true
```

If a file in `dropin\` ever declares the same `name:` as
`critical_etl.yaml`, the explicit entry wins and the drop-in is
silently ignored — your audited config is never accidentally shadowed.

### Workflow for adding a new pipeline

1. **Author the YAML** at `C:\ProgramData\mass-migrator\pipelines\<name>.yaml`.
   The pipeline's `daemon.schedule` field controls when it runs; the
   daemon's `default_timezone` applies if the pipeline doesn't override it.
2. **Register it.** With auto-discovery you are done — the daemon
   reloads within ~200 ms. With the explicit list, add an entry under
   `pipelines:` in `daemon.yaml` and reload via any of the three paths
   from [§6](#6-reloading-configuration).
3. **Verify** in Event Log (reload event ID 102) and in `daemon.log`:
   ```powershell
   Get-Content 'C:\ProgramData\mass-migrator\logs\daemon.log' -Tail 20 |
       Select-String 'Reload:|Registered job'
   ```

### Workflow for disabling a pipeline temporarily

- **Explicit list:** flip `enabled: true` to `enabled: false`, reload.
  The file stays on disk for the next re-enable.
- **Directory auto-discovery:** move the file out of `pipelines_dir`
  (e.g. into a `disabled\` sibling directory). The daemon reloads,
  the job is unregistered, and the file is preserved for the next
  re-enable.

Either way, in-flight runs of the disabled pipeline are not cancelled
— reload affects only the scheduler's next-tick decisions.

### Workflow for changing a schedule

Edit the `daemon.schedule` field inside the pipeline file itself
(not `daemon.yaml`). With auto-discovery the change is picked up
within ~200 ms; with the explicit list, reload manually. Either way
the daemon notices the new cron and re-registers the job.

---

## 10. Uninstall

The bundled uninstaller is `contrib/uninstall.ps1`. It preserves your
data directory by default so a re-install with `install.ps1` lands on
the same `daemon.yaml`, pipelines, state DB, and rotated logs.

### Standard uninstall (preserves data)

```powershell
.\contrib\uninstall.ps1
```

Removes, in order:

1. Stops the service (waits up to 60 s for `Stopped`).
2. Unregisters via `mass-migrator daemon service uninstall`, falling
   back to `sc.exe delete mass-migrator` if the binary is missing.
3. Removes the Event Log source.
4. Removes the install directory (`C:\Program Files\mass-migrator\`).

Preserves: `%PROGRAMDATA%\mass-migrator\` — daemon.yaml, pipelines,
state, logs.

### Full uninstall (irreversible)

```powershell
.\contrib\uninstall.ps1 -PurgeData
```

Adds step 5: removes `%PROGRAMDATA%\mass-migrator\` recursively. This
destroys configuration, all state databases, and all rotated logs.

### Custom paths

If you installed with `-InstallDir` / `-DataDir` to non-default
locations, pass the same flags to `uninstall.ps1`:

```powershell
.\contrib\uninstall.ps1 -InstallDir D:\mass-migrator -DataDir D:\mass-migrator\data
```

### Uninstall summary table

The script prints a summary like:

```
Service           : removed
Event Log src     : removed
Install dir       : removed
Data dir          : preserved
```

If any row says `STILL PRESENT`, the underlying remove operation failed
— usually because the operator was not running as Administrator, or a
file inside the directory is locked by another process (e.g., a
PowerShell session whose CWD is inside `%PROGRAMDATA%\mass-migrator\`).

---

## 11. Troubleshooting

The table below maps symptoms to diagnostics. When in doubt, start with
the Event Log — it captures every lifecycle transition with a typed event ID.

### Symptom → diagnostic table

| Symptom | First diagnostic | Likely cause | Resolution |
|---|---|---|---|
| `Get-Service` shows `Stopped` immediately after `Start-Service` | `Get-WinEvent -LogName Application -ProviderName mass-migrator -MaxEvents 5` | Daemon crashed during startup. Event ID **200** (fatal) carries the wrapped error message. | Fix the underlying error — usually a malformed `daemon.yaml`, an unreachable database, or an invalid cron expression. Then `Restart-Service`. |
| `Start-Service` hangs for 30 s then fails | `Get-WinEvent ... -Level 2` (errors); `Get-Content daemon.log -Tail 50` | Long DB pool warm-up exceeded SCM start-pending window. | Increase `default_timezone`/decrease pool size, or pre-warm DB before starting. Worst case, mark service start as `delayed-auto` so it runs after the boot-storm. |
| "Pipe not found" or "The system cannot find the file specified" when reloading via the pipe | `Get-Service mass-migrator` | Daemon is stopped — the pipe only exists while the service is running. Alternatively the named pipe path is wrong. | Start the service; verify `control_socket` in `daemon.yaml` is exactly `"\\\\.\\pipe\\mass-migrator"`. |
| "Access is denied" on pipe dial | Check caller's group membership: `whoami /groups \| findstr Administrators` | Caller is not the pipe Owner and not in `BUILTIN\Administrators`. The SDDL denies everyone else. | Run the reload from an elevated shell, or use `sc.exe control mass-migrator 128` (requires only `SERVICE_USER_DEFINED_CONTROL` on the service object). |
| Daemon log file isn't rotating | `cat daemon.yaml \| Select-String log_rotate` | `log_rotate_enabled: true` is missing or set to `false`. Windows default is **on** but an explicit `false` overrides. | Set `log_rotate_enabled: true`, `Restart-Service`. (Reload alone does not re-open the rotating writer.) |
| Event Log entries from `mass-migrator` provider aren't appearing | `[System.Diagnostics.EventLog]::SourceExists('mass-migrator')` returns `False` | The Event Log source was never registered, usually because `install.ps1` was run from a non-elevated prompt. | Re-run `install.ps1` from an elevated PowerShell, or manually register: `New-EventLog -LogName Application -Source mass-migrator`. |
| Service `Status=Running` but no pipelines are firing | `Get-Content daemon.log -Tail 100 \| Select-String 'Registered job'` | Zero jobs registered — either no pipelines in `daemon.yaml`, all `enabled: false`, or every pipeline parse failed. | Inspect `daemon.log` for `skipping pipeline ...` warnings. Fix the pipeline YAML or add at least one `enabled: true` entry. |
| One pipeline runs at 100% CPU and starves the others | Look at `Resource Monitor` → `mass-migrator.exe` PID; check `daemon.workers` and per-pipeline `overlap_policy` | Worker pool is saturated by one long-running pipeline; concurrency is bounded by `daemon.workers`. | Increase `daemon.workers` (default 4), or set the heavy pipeline's `overlap_policy: skip` so it does not pile up. |
| Reload via control 128 silently does nothing | `Get-WinEvent ... -FilterHashtable @{Id=102}` | The daemon received the control but the reload itself failed (e.g., new `daemon.yaml` is invalid). | The daemon log records the reload error. Roll `daemon.yaml` back, reload again. The previous live configuration remains active until reload succeeds. |
| `mass-migrator daemon service install` says "service already exists" | `Get-Service mass-migrator` | Service is already registered (idempotent install short-circuit). | Either accept — you're done — or uninstall first if you want to change `--binary-path` / `--config-path`. |
| Uninstall says `Service: STILL PRESENT` | `Get-Service mass-migrator` then `sc.exe queryex mass-migrator` | The service still has open handles (rare; usually a stuck `services.msc` GUI). | Close `services.msc`, retry `uninstall.ps1`. Last resort: `sc.exe delete mass-migrator` from elevated cmd and reboot. |
| `mass-migrator daemon reload` exits 1 ("no listener" / "file not found") | `Get-Service mass-migrator` | Daemon is stopped — the named pipe only exists while the service is `Running`, or `control_socket` in `daemon.yaml` is wrong. | Start the service; verify `control_socket` is `"\\\\.\\pipe\\mass-migrator"`. |
| `mass-migrator daemon reload` exits 2 with `ERR ...` | Trailing `ERR` text + `Get-Content daemon.log -Tail 50` | New `daemon.yaml` failed validation (bad timezone, non-loopback `health_addr`, invalid cron, etc.). | Roll `daemon.yaml` back, retry. Previous live config stays active until reload succeeds. |
| YAML dropped into `pipelines_dir` is not being picked up | `Select-String 'pipelines_dir' C:\ProgramData\mass-migrator\daemon.yaml`; `Get-Content daemon.log -Tail 100 \| Select-String 'pipelines_dir'` | Either `pipelines_dir` is unset, `pipelines_dir_watch: false`, fsnotify can't watch the dir, OR the file failed to parse (daemon logs+skips by design), OR its `name:` collided with the explicit list. | Set `pipelines_dir`; leave `pipelines_dir_watch` unset (defaults to `true`). Check `daemon.log` for `pipelines_dir: watching ... for changes` and any `skipping <file>` warnings. |
| `GET /metrics` returns 404 / connection refused | `Select-String 'health_addr' C:\ProgramData\mass-migrator\daemon.yaml` | `health_addr` is not set — HTTP server disabled by design. | Add `health_addr: "127.0.0.1:9090"` under `daemon:` and `Restart-Service mass-migrator`. |
| Daemon fails to start with `health server: must bind to loopback` | The `health_addr` value in `daemon.yaml` | Non-loopback addresses are refused; there is no override. | Use `127.0.0.1:9090`, `localhost:9090`, or `[::1]:9090`. Front with a reverse proxy for remote scraping. |
| Daemon fails to start with `health server: bind ... address already in use` | `netstat -ano \| findstr :9090` | Another process holds the port. Daemon fails startup rather than silently running without metrics. | Wait a few seconds (previous instance releasing) or pick a different loopback port. |

### Capturing a support bundle

When opening an issue, attach:

```powershell
# Service definition
sc.exe qc mass-migrator > $env:USERPROFILE\Desktop\mm-support\service.txt

# Current daemon config
Copy-Item 'C:\ProgramData\mass-migrator\daemon.yaml' $env:USERPROFILE\Desktop\mm-support\

# Last 1000 daemon log lines
Get-Content 'C:\ProgramData\mass-migrator\logs\daemon.log' -Tail 1000 |
    Set-Content $env:USERPROFILE\Desktop\mm-support\daemon-tail.log

# Last 50 Event Log entries
Get-WinEvent -LogName Application -ProviderName mass-migrator -MaxEvents 50 |
    Format-List * | Out-File $env:USERPROFILE\Desktop\mm-support\eventlog.txt

# Binary version
& 'C:\Program Files\mass-migrator\mass-migrator.exe' --version >
    $env:USERPROFILE\Desktop\mm-support\version.txt
```

Compress and attach.

---

## 12. Differences from Linux/macOS

If you already operate Mass Migrator on Linux or macOS, the Windows port
keeps the runtime semantics identical but swaps the OS integration
points. The table below shows the one-to-one mapping.

| Concern | Linux / macOS | Windows |
|---|---|---|
| Service manager | systemd (Linux), launchd (macOS) | Service Control Manager (SCM) |
| Service file | `/etc/systemd/system/mass-migrator.service` | SCM database (registered via `mass-migrator daemon service install`) |
| Start command | `sudo systemctl start mass-migrator` | `Start-Service mass-migrator` |
| Status command | `sudo systemctl status mass-migrator` | `Get-Service mass-migrator` |
| Reload signal | `sudo systemctl reload mass-migrator` (SIGHUP) | `sc.exe control mass-migrator 128` |
| Service logs | `journalctl -u mass-migrator` | Windows Event Log (`Application` / `mass-migrator`) |
| Control plane transport | Unix domain socket at `/var/run/mass-migrator/control.sock` | Named pipe at `\\.\pipe\mass-migrator` |
| Control plane authz | SO_PEERCRED — only the daemon UID may connect | SDDL — only Owner + `BUILTIN\Administrators` may connect |
| Config location | `/etc/mass-migrator/daemon.yaml` | `%PROGRAMDATA%\mass-migrator\daemon.yaml` |
| State location | `/var/lib/mass-migrator/` | `%PROGRAMDATA%\mass-migrator\state\` |
| Log location | `/var/log/mass-migrator/` | `%PROGRAMDATA%\mass-migrator\logs\` |
| Log rotation | `logrotate(8)` via `contrib/mass-migrator.logrotate` | Built-in (Go) — `log_rotate_*` keys |
| PID file | `/var/run/mass-migrator/daemon.pid` (0600) | `%PROGRAMDATA%\mass-migrator\daemon.pid` (service account) |
| Tail logs | `tail -F /var/log/mass-migrator/daemon.log` | `Get-Content C:\ProgramData\mass-migrator\logs\daemon.log -Wait` |
| Process under | dedicated `mass-migrator` UNIX user | `LocalSystem` by default (configure via `sc.exe config mass-migrator obj=` for a custom service account) |

The control-socket text protocol (`STATUS\n`, `RELOAD\n`, `STOP\n`) is
identical on both transports. Code paths above the dial site are
shared, so behaviour at the daemon layer is the same.

---

## 13. Comparison: daemon vs Task Scheduler

Windows admins reach for Task Scheduler instinctively, and for many
workloads that is the correct call. Daemon mode is **not** universally
better. The decision matrix:

### When daemon mode wins

| Need | Why daemon mode |
|---|---|
| **Multiple pipelines on cron** | One process schedules N pipelines with one set of database pools; Task Scheduler launches a fresh process per task. |
| **Hot reload** | `sc.exe control 128` re-reads `daemon.yaml` without a process restart. Task Scheduler has no equivalent — you edit the XML and the next launch picks it up. |
| **Overlap policy** | `skip` / `wait` / `replace` / `cancel` are first-class. Task Scheduler offers "do not start a new instance" but no `wait` queueing. |
| **Shared database pools** | One daemon → one pool per database → predictable connection count. Task Scheduler → each task opens its own pool → connection storms. |
| **Structured lifecycle events** | Event Log entries for start/stop/reload/fatal with stable event IDs. Task Scheduler logs *that a task ran*, not *that mass-migrator started*. |
| **Stateful incremental sync** | Watermark + checkpoint state is held in process between runs; reload preserves it. Task Scheduler reloads state from disk every run (slower, more I/O). |
| **/metrics for Prometheus** | First-class in daemon mode: set `health_addr` and the daemon serves `/health`, `/metrics`, `/status` on a loopback HTTP port. Task Scheduler has no metrics endpoint. |
| **Auto-discover new pipelines** | Daemon scans `pipelines_dir` at startup and (with `pipelines_dir_watch: true`) reloads within ~200 ms when files are dropped in. Task Scheduler cannot auto-discover new tasks — every task has to be registered explicitly. |
| **Heartbeat / stale-job detection** | Daemon emits a heartbeat every `heartbeat_interval`; stuck jobs are surfaced. Task Scheduler has no liveness signal. |

### When Task Scheduler is fine

| Need | Why Task Scheduler |
|---|---|
| **Single occasional pipeline** | One CSV-load every Monday at 03:00 — Task Scheduler is one form, zero install. |
| **No operations team** | The team is comfortable with the Task Scheduler GUI; no PowerShell pipeline; learning a new daemon is overhead. |
| **Group Policy distribution** | You already push tasks via GPO. Continue doing so. |
| **Workload is genuinely independent** | The pipeline doesn't share state with anything else and a fresh process per run is desirable for blast-radius reasons. |
| **Existing audit story** | Your security team has Task Scheduler audit rules wired into SIEM; adding a new audit source costs more than it saves. |

### Bottom line

Many Windows shops use Task Scheduler successfully and that's fine. If
you find yourself listing five tasks in Task Scheduler, all calling
`mass-migrator pipeline run ...` with different YAML files, **that is
the signal to consolidate into daemon mode**. The lifecycle, observability,
and resource-pooling wins compound at the second pipeline.

Conversely, if you have one pipeline and a small team, deploying a
daemon for it adds maintenance surface without proportional benefit.

---

## Appendix A — Quick reference card

```text
INSTALL
  .\contrib\install.ps1 [-InstallDir D:\mm] [-DataDir D:\mm\data] [-NoStart]

SCM-LEVEL MANAGEMENT (service registration)
  PowerShell:    Start-Service mass-migrator
                 Stop-Service mass-migrator
                 Restart-Service mass-migrator
                 Get-Service mass-migrator

  sc.exe:        sc.exe start mass-migrator
                 sc.exe stop mass-migrator
                 sc.exe query mass-migrator

  Native:        mass-migrator daemon service start
                 mass-migrator daemon service stop
                 mass-migrator daemon service restart
                 mass-migrator daemon service status [--json]

DAEMON-RUNTIME MANAGEMENT (live process, via named pipe)
                 mass-migrator daemon reload                # graceful config reload
                 mass-migrator daemon status [--json]        # runtime status
                 mass-migrator daemon stop                   # graceful shutdown
                 # Flags on all three: --socket, --timeout, --json
                 # Exit codes: 0 ok, 1 unreachable, 2 daemon ERR, 3 timeout

RELOAD (no restart) — three equivalent paths
  sc.exe control mass-migrator 128
  mass-migrator daemon reload
  Restart-Service mass-migrator                # brief downtime

OBSERVABILITY (when daemon.health_addr is set, loopback-only)
  Health:        Invoke-WebRequest http://127.0.0.1:9090/health
  Metrics:       Invoke-WebRequest http://127.0.0.1:9090/metrics
  Status:        Invoke-WebRequest http://127.0.0.1:9090/status

LOGS
  File:          Get-Content C:\ProgramData\mass-migrator\logs\daemon.log -Wait
  Event Log:     Get-WinEvent -LogName Application -ProviderName mass-migrator -MaxEvents 20

UNINSTALL
  .\contrib\uninstall.ps1                 # Preserves data
  .\contrib\uninstall.ps1 -PurgeData      # Destroys data

KEY PATHS
  Binary:        C:\Program Files\mass-migrator\mass-migrator.exe
  Config:        C:\ProgramData\mass-migrator\daemon.yaml
  Pipelines:     C:\ProgramData\mass-migrator\pipelines\   (also pipelines_dir target)
  State:         C:\ProgramData\mass-migrator\state\
  Logs:          C:\ProgramData\mass-migrator\logs\
  PID file:      C:\ProgramData\mass-migrator\daemon.pid
  Control pipe:  \\.\pipe\mass-migrator

NEW CONFIG KEYS (under daemon:)
  pipelines_dir        directory scanned for *.yaml/*.yml (auto-discovery)
  pipelines_dir_watch  fsnotify hot-reload (default true when pipelines_dir set)
  health_addr          HTTP server bind, loopback only (e.g. 127.0.0.1:9090)
```

---

## Appendix B — Cross-references

| Topic | Document |
|---|---|
| Linux / systemd / launchd | [`daemon-operations.md`](daemon-operations.md) |
| Full CLI flag reference | [`cli-reference.md`](../cli-reference.md) |
| Pipeline error handlers and finalizers | [`pipeline-error-handling.md`](pipeline-error-handling.md) |
| Mixed-stage pipelines | [`pipeline-mixed-stages-guide.md`](pipeline-mixed-stages-guide.md) |
| Recovery and checkpointing | [`recovery-checkpointing.md`](recovery-checkpointing.md) |
| Performance tuning | [`performance-optimization.md`](performance-optimization.md) |
| Release publishing flow | [`publishing-releases.md`](publishing-releases.md) |

For the install/uninstall script source, see
[`contrib/install.ps1`](../../contrib/install.ps1) and
[`contrib/uninstall.ps1`](../../contrib/uninstall.ps1).
