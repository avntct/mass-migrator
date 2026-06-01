#!/bin/bash
################################################################################
# Mass Migrator v3 (Go) - 6-Step Equivalent WITHOUT pipeline mode
#
# Same targets and outcomes as test-6step-pipeline-go.sh, but uses ONLY simple
# modes (gencsv / csv2db / insert / update-ind) plus raw psql for DDL/DML.
# No pipeline YAML, no shared_datasets, no DAG — proves the same end-state is
# reachable with the file-and-table primitives alone.
#
# Pipeline (original) → Simple-mode replacement mapping:
#   [0] map table             →  psql CREATE+INSERT       (unchanged: pure DDL/DML)
#   [1] gencsv                →  gencsv subcommand        (unchanged)
#   [2] csv2db import         →  csv2db subcommand        (unchanged)
#   [3.1] setup_clone (sql)   →  psql CREATE TABLE
#   [3.2] extract_source      →  (merged into 3.3 via JOIN in SQL)
#   [3.3] enrich_data (lookup)→  psql CREATE TABLE AS SELECT ... JOIN  (staging)
#   [3.4] load_clone (insert) →  `insert` DB-to-DB subcommand (staging → clone)
#   [3.5] mass_update         →  psql UPDATE
#   [3.6] restore_balances    →  (merged with 3b)
#   [3b] update-ind from CSV  →  update-ind subcommand    (unchanged)
#   [4] verify                →  psql                     (unchanged)
#
# Configure via env vars: RECORD_COUNT, DB_HOST, DB_PORT, DB_NAME, DB_USER,
# DB_PASSWORD, THREADS, BATCH_SIZE, GO_BIN
#
# Usage: ./test-6step-simple-mode-go.sh [-r RECORD_COUNT] [-t THREADS] [-b BATCH_SIZE]
################################################################################

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# --- Default Configuration ---
DEFAULT_RECORD_COUNT=50000
DEFAULT_THREADS=8
DEFAULT_BATCH_SIZE=5000

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -r|--records)
            RECORD_COUNT="$2"
            shift 2
            ;;
        -t|--threads)
            THREADS="$2"
            shift 2
            ;;
        -b|--batch)
            BATCH_SIZE="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [-r RECORD_COUNT] [-t THREADS] [-b BATCH_SIZE]"
            echo "  -r, --records   Number of records to generate (default: $DEFAULT_RECORD_COUNT)"
            echo "  -t, --threads   Thread count (default: $DEFAULT_THREADS)"
            echo "  -b, --batch     Batch size (default: $DEFAULT_BATCH_SIZE)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Apply defaults (env vars take precedence)
RECORD_COUNT="${RECORD_COUNT:-$DEFAULT_RECORD_COUNT}"
THREADS="${THREADS:-$DEFAULT_THREADS}"
BATCH_SIZE="${BATCH_SIZE:-$DEFAULT_BATCH_SIZE}"

# --- Configuration (override via environment variables) ---
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR="${TEST_DIR:-$BASE_DIR/test_output_simple}"

# Go binary
GO_BIN="${GO_BIN:-./mass-migrator}"
GO_OPTS=""

# Database
DB_TYPE="${DB_TYPE:-postgresql}"
DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-appdb}"
DB_USER="${DB_USER:-appuser}"
DB_PASSWORD="${DB_PASSWORD:-Pass#\$123}"

DB_URL="postgresql://${DB_HOST}:${DB_PORT}/${DB_NAME}?sslmode=disable"
JDBC_URL="jdbc:postgresql://${DB_HOST}:${DB_PORT}/${DB_NAME}"

# Province/District
PROVINCE_MIN=1
PROVINCE_MAX=99
PROVINCE_COUNT=$((PROVINCE_MAX - PROVINCE_MIN + 1))
DISTRICT_MIN=1
DISTRICT_MAX=9999

# Tables — same suffix scheme as the pipeline test but with _simple to avoid collisions
MAP_TABLE="${MAP_TABLE:-province_district_map_simple}"
IMPORT_TABLE="${IMPORT_TABLE:-test_simple_go}"
CLONE_TABLE="${CLONE_TABLE:-clone_simple_go}"
STAGING_TABLE="${STAGING_TABLE:-enriched_staging_simple}"

# Files
CSV_OUTPUT="$TEST_DIR/test_records.csv"

# Step 5/6
UPDATE5_MASS_VALUE=999999

# --- Partition / Queue / Multi-threading Hardening (same as pipeline version) ---
PARTITION_KEY="${PARTITION_KEY:-province}"
NUM_PARTITIONS="${NUM_PARTITIONS:-4}"

export MM_PARTITION_KEY_COLUMNS="$PARTITION_KEY"
export MM_NUM_PARTITIONS="$NUM_PARTITIONS"
export MM_BACKPRESSURE_THRESHOLD="${MM_BACKPRESSURE_THRESHOLD:-0.8}"
export MM_LOCK_AWARE_BATCH="${MM_LOCK_AWARE_BATCH:-true}"
export MM_SHUTDOWN_GRACE_PERIOD_MS="${MM_SHUTDOWN_GRACE_PERIOD_MS:-15000}"
export MM_ALLOW_NULL_PARTITION_KEY="${MM_ALLOW_NULL_PARTITION_KEY:-false}"

# TPS tracking
STEP0_START=0; STEP0_END=0
STEP1_START=0; STEP1_END=0
STEP2_START=0; STEP2_END=0
STEP3A_START=0; STEP3A_END=0
STEP3B_START=0; STEP3B_END=0
STEP3C_START=0; STEP3C_END=0
STEP3D_START=0; STEP3D_END=0
STEP3E_START=0; STEP3E_END=0

# Pass/fail counters
PASS=0
FAIL=0

# --- Helper Functions ---
print_header() {
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN} $1 ${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
    echo ""
}

print_step() {
    echo -e "${YELLOW}▶ $1${NC}"
}
print_success() {
    echo -e "${GREEN}✓ $1${NC}"
    PASS=$((PASS + 1))
}
print_error() {
    echo -e "${RED}✗ ERROR: $1${NC}"
    FAIL=$((FAIL + 1))
}
print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}
print_tps() {
    local step="$1"
    local desc="$2"
    local count="$3"
    local start_var="STEP${step}_START"
    local end_var="STEP${step}_END"
    eval "local start=\${$start_var}"
    eval "local end=\${$end_var}"
    local duration=$((end - start))
    if [ "$duration" -gt 0 ] && [ "$count" -gt 0 ]; then
        local tps=$((count / duration))
        printf "${MAGENTA}⏱ TPS: %-30s %12s records/sec (%ds)${NC}\n" "$desc" "$(format_number $tps)" "$duration"
    fi
}
format_duration() {
    local total_seconds=$1
    local minutes=$((total_seconds / 60))
    local seconds=$((total_seconds % 60))
    echo "${minutes}m ${seconds}s"
}
format_number() {
    printf "%'d" $1
}
run_psql() {
    PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -t -A "$@"
}

# --- Banner ---
clear
echo "================================================================================"
echo "  Mass Migrator v3 (Go) - 6-Step Equivalent WITHOUT pipeline mode"
echo "  Binary: $GO_BIN"
echo "================================================================================"
echo ""
echo "Replaces pipeline YAML with: psql DDL/DML + simple modes only"
echo "  Step 0:  Create province-district map (psql)"
echo "  Step 1:  Generate CSV          [gencsv]"
echo "  Step 2:  CSV → import_table    [csv2db]"
echo "  Step 3a: Create clone table    (psql DDL)"
echo "  Step 3b: Create staging table  (psql CREATE TABLE AS SELECT JOIN)"
echo "  Step 3c: staging → clone       [insert]  (DB-to-DB, replaces pipeline load step)"
echo "  Step 3d: Mass UPDATE balance   (psql DML)"
echo "  Step 3e: Restore from CSV      [update-ind]  (partition routed)"
echo "  Step 4:  Verify results        (psql)"
echo ""
echo "  Database:  $DB_TYPE://$DB_HOST:$DB_PORT/$DB_NAME"
echo "  Records:  $(format_number $RECORD_COUNT) | Threads: $THREADS | Batch: $(format_number $BATCH_SIZE)"
echo "  Partition: key=$PARTITION_KEY parts=$NUM_PARTITIONS | Backpressure: $MM_BACKPRESSURE_THRESHOLD | Lock-aware: $MM_LOCK_AWARE_BATCH"
echo "================================================================================"
echo ""

# --- Environment Validation ---
print_step "Validating environment..."

mkdir -p "$TEST_DIR"
print_success "Test directory: $TEST_DIR"

if [ ! -f "$GO_BIN" ]; then
    print_error "Go binary not found: $GO_BIN"
    print_info "Run 'go build -o mass-migrator' first"
    exit 1
fi
print_success "Go binary: $GO_BIN"

if ! command -v psql &> /dev/null 2>&1; then
    print_error "psql not found"
    exit 1
fi

if ! run_psql -c "SELECT 1" > /dev/null 2>&1; then
    print_error "Cannot connect to PostgreSQL"
    exit 1
fi
print_success "PostgreSQL connection verified"
echo ""

################################################################################
# STEP 0: Create Province-District Map Table
################################################################################

print_header "STEP 0: Create Province-District Map Table"

run_psql -c "DROP TABLE IF EXISTS $MAP_TABLE CASCADE" > /dev/null 2>&1
print_info "Dropped existing map table: $MAP_TABLE"

print_step "Creating and populating map table..."

STEP0_START=$(date +%s)

run_psql -c "
CREATE TABLE $MAP_TABLE (
    district_id INTEGER PRIMARY KEY,
    district_name VARCHAR(50) NOT NULL,
    province_id INTEGER NOT NULL,
    province_name VARCHAR(50) NOT NULL
)"

run_psql -c "
INSERT INTO $MAP_TABLE (district_id, district_name, province_id, province_name)
SELECT
    d AS district_id,
    'dist_' || d AS district_name,
    ((d - 1) % $PROVINCE_COUNT) + $PROVINCE_MIN AS province_id,
    'prov_' || (((d - 1) % $PROVINCE_COUNT) + $PROVINCE_MIN) AS province_name
FROM generate_series($DISTRICT_MIN, $DISTRICT_MAX) AS d
"

STEP0_END=$(date +%s)

MAP_COUNT=$(run_psql -c "SELECT COUNT(*) FROM $MAP_TABLE")

print_success "Step 0 Completed! Created $(format_number $MAP_COUNT) map records"
print_tps "0" "Map creation" "$MAP_COUNT"
echo ""

################################################################################
# STEP 1: Generate CSV Records  (mode: gencsv)
################################################################################

print_header "STEP 1: Generate CSV ($(format_number $RECORD_COUNT) Records)"

[ -f "$CSV_OUTPUT" ] && rm -f "$CSV_OUTPUT"

print_step "Starting CSV generation..."

STEP1_START=$(date +%s)

$GO_BIN $GO_OPTS gencsv \
  --output "$CSV_OUTPUT" \
  --records $RECORD_COUNT \
  --columns "id:BIGINT:SEQUENTIAL:1:$RECORD_COUNT,province:INTEGER:NORMAL:$PROVINCE_MIN:$PROVINCE_MAX,district:INTEGER:RANDOM:$DISTRICT_MIN:$DISTRICT_MAX,username:STRING:RANDOM:8:20,email:STRING:EMAIL,age:INTEGER:NORMAL:18:80,balance:DECIMAL:NORMAL:1000:50000:2,created_at:TIMESTAMP" \
  --threads $THREADS \
  --batch-size 1000 \
  --seed 12345 \
  --header

STEP1_END=$(date +%s)

if [ ! -f "$CSV_OUTPUT" ]; then
    print_error "CSV generation failed"
    exit 1
fi

CSV_LINES=$(wc -l < "$CSV_OUTPUT" | tr -d ' ')
CSV_RECORDS=$((CSV_LINES - 1))
CSV_SIZE=$(du -h "$CSV_OUTPUT" | cut -f1)

print_success "Step 1 Completed! $(format_number $CSV_RECORDS) records ($CSV_SIZE)"
print_tps "1" "CSV generation" "$CSV_RECORDS"
echo ""

################################################################################
# STEP 2: Import CSV to PostgreSQL  (mode: csv2db)
################################################################################

print_header "STEP 2: Import CSV → PostgreSQL ($IMPORT_TABLE)"

run_psql -c "DROP TABLE IF EXISTS $IMPORT_TABLE CASCADE" > /dev/null 2>&1
print_step "Starting CSV import..."

STEP2_START=$(date +%s)

$GO_BIN $GO_OPTS csv2db \
  --input "$CSV_OUTPUT" \
  --db-type postgresql \
  --db-url "$DB_URL" \
  --db-user "$DB_USER" \
  --db-password "$DB_PASSWORD" \
  --table "$IMPORT_TABLE" \
  --mapping "id:id:BIGINT,province:province:INTEGER,district:district:INTEGER,username:username:VARCHAR,email:email:VARCHAR,age:age:INTEGER,balance:balance:DECIMAL,created_at:created_at:TIMESTAMP" \
  --batch-size $BATCH_SIZE \
  --threads $THREADS \
  --create-table \
  --skip-header \
  --enable-tps-metrics

STEP2_END=$(date +%s)

IMPORTED_COUNT=$(run_psql -c "SELECT COUNT(*) FROM $IMPORT_TABLE")
IMPORTED_SUM=$(run_psql -c "SELECT ROUND(SUM(balance)::numeric, 2) FROM $IMPORT_TABLE")

print_success "Step 2 Completed! $(format_number $IMPORTED_COUNT) records"
echo "  Balance sum: $IMPORTED_SUM"
print_tps "2" "CSV import" "$IMPORTED_COUNT"
echo ""

################################################################################
# STEP 3a: Create Clone Table  (psql DDL — replaces pipeline setup_clone step)
################################################################################

print_header "STEP 3a: Create Clone Table (psql DDL)"

run_psql -c "DROP TABLE IF EXISTS $CLONE_TABLE CASCADE" > /dev/null 2>&1

STEP3A_START=$(date +%s)

run_psql -c "
CREATE TABLE $CLONE_TABLE (
    id BIGINT PRIMARY KEY,
    province INTEGER,
    district INTEGER,
    username VARCHAR(255),
    email VARCHAR(255),
    age INTEGER,
    balance DECIMAL(10,2),
    created_at TIMESTAMP,
    province_name VARCHAR(100),
    district_name VARCHAR(100)
)"

STEP3A_END=$(date +%s)

print_success "Step 3a Completed! Clone table created: $CLONE_TABLE"
echo ""

################################################################################
# STEP 3b: Create Staging Table via JOIN  (psql — replaces pipeline enrich step)
#
# The pipeline version did this via `shared_datasets` + `set_op lookup`.
# Without pipeline mode, we materialize the same enrichment in SQL:
# `CREATE TABLE AS SELECT ... JOIN ...`. The staging table has the exact same
# shape as the clone table, so a straight DB-to-DB insert can copy it.
################################################################################

print_header "STEP 3b: Materialize Enrichment via JOIN → Staging Table"

run_psql -c "DROP TABLE IF EXISTS $STAGING_TABLE CASCADE" > /dev/null 2>&1

STEP3B_START=$(date +%s)

run_psql -c "
CREATE TABLE $STAGING_TABLE AS
SELECT
    s.id,
    s.province,
    s.district,
    s.username,
    s.email,
    s.age,
    s.balance,
    s.created_at,
    m.province_name,
    m.district_name
FROM $IMPORT_TABLE s
LEFT JOIN $MAP_TABLE m ON s.district = m.district_id
"

STEP3B_END=$(date +%s)

STAGING_COUNT=$(run_psql -c "SELECT COUNT(*) FROM $STAGING_TABLE")
NULL_PROVINCE_STAGING=$(run_psql -c "SELECT COUNT(*) FROM $STAGING_TABLE WHERE province_name IS NULL")

print_success "Step 3b Completed! Staging table populated: $(format_number $STAGING_COUNT) rows"
if [ "$NULL_PROVINCE_STAGING" -eq 0 ]; then
    print_success "All rows enriched (no NULL province_name)"
else
    print_error "Staging has $NULL_PROVINCE_STAGING NULL province_name rows"
fi
print_tps "3B" "JOIN+materialize (psql)" "$STAGING_COUNT"
echo ""

################################################################################
# STEP 3c: Copy Staging → Clone via DB-to-DB `insert` mode
#
# Replaces pipeline `load_clone` step. Uses the SAME PostgreSQL instance as
# both source and target — mass-migrator's `insert` subcommand doesn't care
# whether source and target databases are the same or different.
################################################################################

print_header "STEP 3c: Copy Staging → Clone via [insert] DB-to-DB mode"

print_step "Starting DB-to-DB insert..."

STEP3C_START=$(date +%s)

# Target credentials come from the GLOBAL --db-user / --db-password flags.
# The insert subcommand only exposes --source-username / --source-password for
# the source side; the target side uses the global creds (validated in
# internal/app/validate_connection.go:20-33). For same-host source+target like
# this test, both sides share the same user/pass — set globally once.
$GO_BIN $GO_OPTS insert \
  --source-jdbc-url "$JDBC_URL" \
  --source-username "$DB_USER" \
  --source-password "$DB_PASSWORD" \
  --source-table "$STAGING_TABLE" \
  --target-jdbc-url "$JDBC_URL" \
  --target-table "$CLONE_TABLE" \
  --db-user "$DB_USER" \
  --db-password "$DB_PASSWORD" \
  --columns "id,province,district,username,email,age,balance,created_at,province_name,district_name" \
  --batch-size $BATCH_SIZE \
  --threads $THREADS \
  --enable-tps-metrics

STEP3C_END=$(date +%s)

CLONED_COUNT=$(run_psql -c "SELECT COUNT(*) FROM $CLONE_TABLE")
CLONED_SUM=$(run_psql -c "SELECT ROUND(SUM(balance)::numeric, 2) FROM $CLONE_TABLE")

print_success "Step 3c Completed! $(format_number $CLONED_COUNT) records in clone"
echo "  Balance sum (pre-mass-update): $CLONED_SUM"
print_tps "3C" "insert (DB-to-DB)" "$CLONED_COUNT"
echo ""

################################################################################
# STEP 3d: Mass UPDATE  (psql DML — replaces pipeline mass_update sql step)
################################################################################

print_header "STEP 3d: Mass UPDATE balance = $UPDATE5_MASS_VALUE (psql DML)"

STEP3D_START=$(date +%s)

run_psql -c "UPDATE $CLONE_TABLE SET balance = $UPDATE5_MASS_VALUE"

STEP3D_END=$(date +%s)

MASS_UPDATE_SUM=$(run_psql -c "SELECT ROUND(SUM(balance)::numeric, 2) FROM $CLONE_TABLE")
EXPECTED_MASS_SUM=$(echo "scale=2; $CLONED_COUNT * $UPDATE5_MASS_VALUE" | bc -l 2>/dev/null || python3 -c "print(round($CLONED_COUNT * $UPDATE5_MASS_VALUE, 2))")

print_success "Step 3d Completed! All balances set to $UPDATE5_MASS_VALUE"
echo "  Balance sum (post-mass-update): $MASS_UPDATE_SUM"
echo "  Expected:                       $EXPECTED_MASS_SUM"
print_tps "3D" "Mass UPDATE (psql)" "$CLONED_COUNT"
echo ""

################################################################################
# STEP 3e: Restore from CSV via [update-ind]
#
# Replaces both pipeline `restore_balances` (selective restore via key_columns)
# AND the original test's "Step 3b" partition-routed update-ind. Single
# update-ind pass restores ALL balances from the original CSV using id key.
################################################################################

print_header "STEP 3e: Restore Balances from CSV via [update-ind]"

ZERO_BEFORE=$(run_psql -c "SELECT COUNT(*) FROM $CLONE_TABLE WHERE balance = $UPDATE5_MASS_VALUE")
print_info "Rows at mass-update value before restore: $(format_number $ZERO_BEFORE)"

print_step "Starting update-ind (partition-routed CSV → DB update)..."

STEP3E_START=$(date +%s)

$GO_BIN \
    --mode update-ind \
    --jdbc-url="$JDBC_URL" \
    --db-user "$DB_USER" \
    --db-password "$DB_PASSWORD" \
    --input-file "$CSV_OUTPUT" \
    --target-table "$CLONE_TABLE" \
    --csv-mapping "id:id:BIGINT,province:province:INTEGER,district:district:INTEGER,username:username:VARCHAR,email:email:VARCHAR,age:age:INTEGER,balance:balance:DECIMAL,created_at:created_at:TIMESTAMP" \
    --key-columns "id" \
    --batch-size $BATCH_SIZE \
    --threads $THREADS \
    --enable-tps-metrics

STEP3E_END=$(date +%s)

REMAINING_AT_MASS=$(run_psql -c "SELECT COUNT(*) FROM $CLONE_TABLE WHERE balance = $UPDATE5_MASS_VALUE")
RESTORED_SUM=$(run_psql -c "SELECT ROUND(SUM(balance)::numeric, 2) FROM $CLONE_TABLE")

if [ "$REMAINING_AT_MASS" -eq 0 ]; then
    print_success "update-ind restored all balances (none still at mass-update value)"
else
    print_error "update-ind left $REMAINING_AT_MASS rows at mass-update value"
fi
echo "  Balance sum (after restore): $RESTORED_SUM"
print_tps "3E" "update-ind (partitioned)" "$CLONED_COUNT"
echo ""

################################################################################
# STEP 4: Verify Results
################################################################################

print_header "STEP 4: Verify Results"

echo "Record Count Verification:"
echo "  CSV generated:     $(format_number $CSV_RECORDS)"
echo "  Import table:      $(format_number $IMPORTED_COUNT)"
echo "  Staging table:     $(format_number $STAGING_COUNT)"
echo "  Clone table:       $(format_number $CLONED_COUNT)"

if [ "$IMPORTED_COUNT" -eq "$CSV_RECORDS" ]; then
    print_success "Import count matches CSV ($IMPORTED_COUNT)"
else
    print_error "Import count mismatch: expected=$CSV_RECORDS actual=$IMPORTED_COUNT"
fi

if [ "$STAGING_COUNT" -eq "$IMPORTED_COUNT" ]; then
    print_success "Staging count matches import ($STAGING_COUNT)"
else
    print_error "Staging count mismatch: expected=$IMPORTED_COUNT actual=$STAGING_COUNT"
fi

if [ "$CLONED_COUNT" -eq "$STAGING_COUNT" ]; then
    print_success "Clone count matches staging ($CLONED_COUNT)"
else
    print_error "Clone count mismatch: expected=$STAGING_COUNT actual=$CLONED_COUNT"
fi
echo ""

# Check balance sums
echo "Balance Sum Verification:"
echo "  Original (import):    $IMPORTED_SUM"
echo "  Pre-mass-update:      $CLONED_SUM"
echo "  Post-mass-update:     $MASS_UPDATE_SUM (expected ${EXPECTED_MASS_SUM})"
echo "  After restore:        $RESTORED_SUM"

if [ "$CLONED_SUM" = "$IMPORTED_SUM" ]; then
    print_success "Pre-mass-update clone sum matches import (enrichment preserved balance)"
else
    print_error "Pre-mass-update sum mismatch: expected=$IMPORTED_SUM actual=$CLONED_SUM"
fi

if [ "$RESTORED_SUM" = "$IMPORTED_SUM" ]; then
    print_success "Restored balance sums match original"
else
    print_error "Restored balance sums mismatch: expected=$IMPORTED_SUM actual=$RESTORED_SUM"
fi
echo ""

# Check enrichment
echo "Enrichment Verification:"
NULL_PROVINCE=$(run_psql -c "SELECT COUNT(*) FROM $CLONE_TABLE WHERE province_name IS NULL")
NULL_DISTRICT=$(run_psql -c "SELECT COUNT(*) FROM $CLONE_TABLE WHERE district_name IS NULL")

echo "  NULL province_name: $NULL_PROVINCE"
echo "  NULL district_name: $NULL_DISTRICT"

if [ "$NULL_PROVINCE" -eq 0 ]; then
    print_success "All province_names populated"
else
    print_error "Some province_names are NULL ($NULL_PROVINCE)"
fi
if [ "$NULL_DISTRICT" -eq 0 ]; then
    print_success "All district_names populated"
else
    print_error "Some district_names are NULL ($NULL_DISTRICT)"
fi
echo ""

# Check province distribution
# Threshold scales with RECORD_COUNT because gencsv uses NORMAL distribution
# across PROVINCE_COUNT=99 buckets. At small N the tails statistically miss
# some buckets. Formula: expected = MIN(95, MAX(5, RECORD_COUNT/20)).
#   N=1000  -> threshold 50  (NORMAL covers ~90/99 reliably)
#   N=2000  -> threshold 95  (clipped)
#   N=50000 -> threshold 95  (matches the strict pipeline-test threshold)
echo "Province Distribution Verification:"
PROVINCE_DIST=$(run_psql -c "SELECT COUNT(DISTINCT province) FROM $CLONE_TABLE")
PROVINCE_EXPECTED=$(( RECORD_COUNT / 20 ))
[ $PROVINCE_EXPECTED -gt 95 ] && PROVINCE_EXPECTED=95
[ $PROVINCE_EXPECTED -lt 5 ] && PROVINCE_EXPECTED=5
if [ "$PROVINCE_DIST" -ge "$PROVINCE_EXPECTED" ]; then
    print_success "Province distribution: $PROVINCE_DIST distinct provinces (>= expected $PROVINCE_EXPECTED for N=$RECORD_COUNT)"
else
    print_error "Province distribution too low: $PROVINCE_DIST (expected >= $PROVINCE_EXPECTED for N=$RECORD_COUNT)"
fi
echo ""

# Sample data
echo "Sample Data (first 5 rows from clone table):"
run_psql -c "SELECT id, province, province_name, district, district_name, balance FROM $CLONE_TABLE ORDER BY id LIMIT 5"
echo ""

# Cleanup
echo "Cleanup Commands:"
echo "  PGPASSWORD=$DB_PASSWORD psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -c \"DROP TABLE IF EXISTS $MAP_TABLE, $IMPORT_TABLE, $STAGING_TABLE, $CLONE_TABLE CASCADE\""
echo "  rm -rf $TEST_DIR"
echo ""

# Summary
TOTAL_END=$(date +%s)
TOTAL_DURATION=$((TOTAL_END - STEP0_START))

echo ""
echo "================================================================================"
print_success "Simple-mode equivalent completed at $(date)"
echo "================================================================================"
echo ""
echo "Performance Metrics (TPS):"
print_tps "0"  "Map creation"             "$MAP_COUNT"
print_tps "1"  "CSV generation"           "$CSV_RECORDS"
print_tps "2"  "CSV import [csv2db]"      "$IMPORTED_COUNT"
print_tps "3B" "JOIN+materialize (psql)"  "$STAGING_COUNT"
print_tps "3C" "insert (DB-to-DB)"        "$CLONED_COUNT"
print_tps "3D" "Mass UPDATE (psql)"       "$CLONED_COUNT"
print_tps "3E" "update-ind (partitioned)" "$CLONED_COUNT"
echo ""
echo "Total Duration:       $(format_duration $TOTAL_DURATION)"
echo ""
echo "  ${GREEN}PASS: $PASS${NC}  ${RED}FAIL: $FAIL${NC}"
echo ""
echo "Modes Used (no pipeline mode):"
echo "  gencsv                   — Step 1 (test data generation)"
echo "  csv2db                   — Step 2 (CSV → import_table)"
echo "  insert  (DB-to-DB)       — Step 3c (staging → clone, replaces pipeline load step)"
echo "  update-ind               — Step 3e (CSV → clone with key matching + partition routing)"
echo "  + psql for DDL (CREATE TABLE), the enrichment JOIN, and the mass UPDATE — these are"
echo "    not mode-able operations in mass-migrator regardless of whether pipeline is used."
echo ""
echo "Pipeline → Simple-Mode Mapping:"
echo "  Pipeline shared_datasets + set_op lookup  →  psql CREATE TABLE AS SELECT ... JOIN"
echo "  Pipeline load step (insert strategy)      →  insert subcommand (DB-to-DB)"
echo "  Pipeline sql step (UPDATE)                →  psql UPDATE"
echo "  Pipeline sql step with key_columns        →  update-ind (CSV-driven)"
echo "  Pipeline DAG dependencies                 →  shell script execution order"
echo "  Pipeline staged partitioning              →  partition routing via MM_NUM_PARTITIONS"
echo ""
echo "================================================================================"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
