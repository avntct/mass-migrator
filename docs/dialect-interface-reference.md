# Mass Migrator v3 -- Dialect Interface 5W1H Reference Guide

**Source**: `internal/dialect/` package
**Composite Interface**: `DatabaseDialect` (27 methods across 12 sub-interfaces)
**Implementations**: PostgreSQL, MySQL, SQLite, SQL Server, Oracle, Neo4j, Netezza
**Version Wrapper**: `VersionedDialect` for version-sensitive behavior overrides

---

## Part A: Interface Methods (27 Methods)

---

### Sub-Interface: DialectMetadata (6 methods)

Defined at `dialect.go:85-98`.

---

#### Method: `GetDatabaseType() string`

**What**: Returns the canonical string identifier for the database type.

**Why**: Used throughout the codebase to branch on database type for dialect-specific logic (e.g., version detection queries, watermark filter generation, pipeline configuration validation).

**How**: Returns a hardcoded string constant. No computation involved.

**Where**: `DialectMetadata` interface in `dialect.go:87`.

**When**: Called during pipeline initialization, configuration validation, version detection (`DetectVersion` in `version.go`), and anywhere dialect-specific branching is needed.

**Dialect values**:

| Dialect | Return Value |
|---------|-------------|
| PostgreSQL | `"postgresql"` |
| MySQL | `"mysql"` |
| SQLite | `"sqlite"` |
| SQL Server | `"sqlserver"` |
| Oracle | `"oracle"` |
| Neo4j | `"neo4j"` |
| Netezza | `"netezza"` |

---

#### Method: `GetDriverName() string`

**What**: Returns the Go `database/sql` driver name used in `sql.Open()`.

**Why**: The migrator needs to know which driver string to pass to `sql.Open()` when establishing database connections. Each driver package registers itself under a specific name.

**How**: Returns a hardcoded string constant matching the driver registration name.

**Where**: `DialectMetadata` interface in `dialect.go:89`.

**When**: Called when opening new database connections during pipeline execution.

**Dialect values**:

| Dialect | Driver Name | Import Path |
|---------|------------|-------------|
| PostgreSQL | `"pgx"` | `github.com/jackc/pgx/v5/stdlib` |
| MySQL | `"mysql"` | `github.com/go-sql-driver/mysql` |
| SQLite | `"sqlite"` | `modernc.org/sqlite` |
| SQL Server | `"sqlserver"` | `github.com/microsoft/go-mssqldb` |
| Oracle | `"oracle"` | `github.com/sijms/go-ora/v2` |
| Neo4j | `"neo4j"` | Neo4j Go driver |
| Netezza | `"netezza"` | Netezza ODBC/Go driver |

---

#### Method: `GetOptimalBatchSize() int`

**What**: Returns the recommended number of rows per batch for bulk INSERT/UPDATE/UPSERT operations.

**Why**: Different databases have different optimal batch sizes based on network round-trip cost, parameter limits, transaction log overhead, and lock contention characteristics. Using the wrong batch size causes either excessive round-trips (too small) or memory/lock issues (too large).

**How**: Returns a hardcoded integer tuned for each database's characteristics.

**Where**: `DialectMetadata` interface in `dialect.go:91`.

**When**: Called by the executor when partitioning source data into batches for write operations.

**Dialect values**:

| Dialect | Batch Size | Rationale |
|---------|-----------|-----------|
| PostgreSQL | 50,000 | High throughput, MVCC avoids lock contention |
| MySQL | 50,000 | InnoDB handles large batches well |
| SQLite | 5,000 | Single-writer, file-level locking |
| SQL Server | 10,000 | Lock escalation risk at higher counts |
| Oracle | 10,000 | Redo log and undo segment considerations |
| Neo4j | 1,000 | Graph operations are more expensive per row |
| Netezza | 10,000 | MPP data warehouse, moderate batch size |

---

#### Method: `SupportsConcurrentWrites() bool`

**What**: Returns whether the database supports multiple concurrent write transactions without serialization.

**Why**: The executor uses this flag to decide whether to run batch writes in parallel goroutines or serialize them. Running parallel writes against a database that does not support concurrency (SQLite) causes lock contention and errors.

**How**: Returns a hardcoded boolean. `false` triggers `MaxOpenConns=1` at the connection level.

**Where**: `DialectMetadata` interface in `dialect.go:93`.

**When**: Called during executor setup to configure connection pool and worker count.

**Dialect values**:

| Dialect | Value | Reason |
|---------|-------|--------|
| PostgreSQL | `true` | MVCC, row-level locking |
| MySQL | `true` | InnoDB row-level locking |
| SQLite | **`false`** | Single-writer, file-level locking |
| SQL Server | `true` | Row-level locking with lock escalation |
| Oracle | `true` | MVCC via undo segments |
| Neo4j | `true` | Graph-level concurrency |
| Netezza | `true` | MPP architecture |

---

#### Method: `SupportsUpsert() bool`

**What**: Returns whether the database has native single-statement upsert (insert-or-update) capability.

**Why**: Databases without native upsert (SQL Server, Oracle, Netezza) must use MERGE or transactional UPDATE+INSERT fallback. The executor checks this to decide which write strategy to use.

**How**: Returns a hardcoded boolean. The `VersionedDialect` wrapper overrides this for PostgreSQL versions below 9.5 (which lack `ON CONFLICT`).

**Where**: `DialectMetadata` interface in `dialect.go:95`.

**When**: Called when selecting the write strategy (insert/update/upsert/merge) for a pipeline step.

**Dialect values**:

| Dialect | Value | Mechanism |
|---------|-------|-----------|
| PostgreSQL | `true` | `ON CONFLICT ... DO UPDATE` (9.5+) |
| MySQL | `true` | `ON DUPLICATE KEY UPDATE` |
| SQLite | `true` | `ON CONFLICT ... DO UPDATE` (3.24+) |
| SQL Server | **`false`** | Uses MERGE instead |
| Oracle | **`false`** | Uses MERGE instead |
| Neo4j | `true` | Cypher `MERGE` is native upsert |
| Netezza | **`false`** | No native upsert or merge |

**Version-sensitive**: `VersionedDialect.SupportsUpsert()` returns `false` for PostgreSQL < 9.5.

---

#### Method: `IsConnectionValid(ctx context.Context, db *sql.DB) error`

**What**: Validates that the database connection is alive and responsive.

**Why**: Before executing a pipeline, the system verifies that both source and target connections are usable. Dead connections would cause cryptic errors during batch processing.

**How**: All 7 dialects delegate to `db.PingContext(ctx)`, which sends a driver-level ping to the database server.

**Where**: `DialectMetadata` interface in `dialect.go:97`.

**When**: Called at pipeline startup for connection health checks, and potentially during long-running operations.

**Dialect differences**: All dialects use the same implementation (`db.PingContext(ctx)`). No variation.

---

### Sub-Interface: PlaceholderProvider (1 method)

Defined at `dialect.go:100-105`.

---

#### Method: `Placeholder(idx int) string`

**What**: Returns the SQL parameter placeholder for the given 1-based index position.

**Why**: SQL parameter placeholder syntax varies fundamentally across databases. Using the wrong placeholder causes parse errors. This method abstracts the difference so statement builders can generate correct parameterized SQL regardless of target database.

**How**: Formats the index into the dialect-specific placeholder string. Positional dialects (PostgreSQL, SQL Server, Oracle, Neo4j, Netezza) use the index; positional-agnostic dialects (MySQL, SQLite) ignore it and return `?`.

**Where**: `PlaceholderProvider` interface in `dialect.go:103`.

**When**: Called by every statement builder method (insert, update, upsert, merge) for each parameterized column.

**Dialect differences**:

| Dialect | Pattern | Example (idx=1, 2, 3) |
|---------|---------|----------------------|
| PostgreSQL | `$N` | `$1`, `$2`, `$3` |
| MySQL | `?` | `?`, `?`, `?` |
| SQLite | `?` | `?`, `?`, `?` |
| SQL Server | `@pN` | `@p1`, `@p2`, `@p3` |
| Oracle | `:N` | `:1`, `:2`, `:3` |
| Neo4j | `$N` | `$1`, `$2`, `$3` |
| Netezza | `$N` | `$1`, `$2`, `$3` |

---

### Sub-Interface: IdentifierEscaper (2 methods)

Defined at `dialect.go:107-117`.

---

#### Method: `EscapeIdentifier(identifier string) string`

**What**: Wraps a database identifier (table name, column name) in the dialect's quoting characters, escaping any embedded quote characters.

**Why**: Identifiers may contain reserved words, spaces, or special characters. Proper quoting prevents SQL parse errors and SQL injection via identifier names.

**How**: Wraps the identifier in the dialect's quote characters and doubles any embedded quotes to escape them.

**Where**: `IdentifierEscaper` interface in `dialect.go:110`.

**When**: Called by every statement builder for every table and column reference in generated SQL.

**Dialect differences**:

| Dialect | Quote Char | Escape Method | Example Input `my"col` |
|---------|-----------|---------------|----------------------|
| PostgreSQL | `"` | `""` | `"my""col"` |
| MySQL | `` ` `` | ` `` ` | `` `my"col` `` |
| SQLite | `"` | `""` | `"my""col"` |
| SQL Server | `[` `]` | `]]` | `[my"col]` |
| Oracle | `"` | `""` | `"my""col"` |
| Neo4j | `` ` `` | ` `` ` | `` `my"col` `` |
| Netezza | `"` | `""` | `"my""col"` |

---

#### Method: `CastPlaceholder(placeholder string, sqlType string) string`

**What**: Wraps a parameter placeholder with an explicit type cast appropriate for the dialect. Used in batch `UPDATE...FROM (VALUES ...)` statements where some databases need explicit casts to avoid type mismatch errors.

**Why**: PostgreSQL's strict typing causes `"operator does not exist: bigint = text"` errors when comparing typed columns against untyped parameter placeholders in CTE/VALUES constructs. SQL Server and Oracle also benefit from explicit casts in certain contexts.

**How**: Maps the generic SQL type name to a dialect-specific type and wraps the placeholder. Dialects that handle implicit coercion (MySQL, SQLite, Neo4j, Netezza) return the placeholder unchanged.

**Where**: `IdentifierEscaper` interface in `dialect.go:116`.

**When**: Called during batch UPDATE statement generation when using VALUES-based multi-row updates.

**Dialect differences**:

| Dialect | Example (`$1`, `BIGINT`) | Approach |
|---------|--------------------------|----------|
| PostgreSQL | `$1::int8` | `::` cast operator, maps to PG-native types |
| MySQL | `?` (unchanged) | Implicit coercion |
| SQLite | `?` (unchanged) | Dynamic typing |
| SQL Server | `CAST(@p1 AS BIGINT)` | `CAST(... AS ...)` function |
| Oracle | `CAST(:1 AS NUMBER(19))` | `CAST(... AS ...)` function |
| Neo4j | `$1` (unchanged) | No casting needed |
| Netezza | `$1` (unchanged) | Implicit coercion |

**PostgreSQL type mappings** (selected): `BIGINT` -> `int8`, `INTEGER` -> `int4`, `DECIMAL` -> `numeric`, `BOOLEAN` -> `bool`, `TIMESTAMP` -> `timestamp`, `TEXT/VARCHAR` -> `text`, `BLOB` -> `bytea`.

**SQL Server type mappings** (selected): `BIGINT` -> `BIGINT`, `BOOLEAN` -> `BIT`, `TIMESTAMP` -> `DATETIME2`, `TEXT` -> `NVARCHAR(MAX)`, `BLOB` -> `VARBINARY(MAX)`.

**Oracle type mappings** (selected): `BIGINT` -> `NUMBER(19)`, `INTEGER` -> `NUMBER(10)`, `BOOLEAN` -> `NUMBER(1)`, `FLOAT` -> `BINARY_FLOAT`, `DOUBLE` -> `BINARY_DOUBLE`, `TEXT` -> `CLOB`.

---

### Sub-Interface: AutoIncrementDetector (2 methods)

Defined at `dialect.go:119-125`.

---

#### Method: `IsAutoIncrementColumn(ctx context.Context, db *sql.DB, table, column string) (bool, error)`

**What**: Checks whether a specific column in a table is an auto-increment (identity/serial/sequence) column.

**Why**: Auto-increment columns must be excluded from INSERT statements (unless explicitly overridden with IDENTITY_INSERT on SQL Server). The migrator needs to detect them to avoid inserting explicit values into auto-generated columns.

**How**: Queries database-specific system catalogs/metadata tables.

**Where**: `AutoIncrementDetector` interface in `dialect.go:122`.

**When**: Called during pipeline setup to build the `autoInc map[string]bool` used by statement builders.

**Dialect differences**:

| Dialect | Detection Method |
|---------|-----------------|
| PostgreSQL | Queries `information_schema.columns` for `column_default` containing `NEXTVAL` (sequence-based) |
| MySQL | Queries `information_schema.COLUMNS.EXTRA` for `auto_increment` |
| SQLite | Parses `sqlite_master.sql` for `AUTOINCREMENT` keyword or `INTEGER PRIMARY KEY` pattern |
| SQL Server | Queries `sys.columns.is_identity` |
| Oracle | **Dual detection**: (1) 12c+ `ALL_TAB_COLUMNS.IDENTITY_COLUMN = 'YES'`; (2) 10g/11g fallback checks `ALL_TRIGGERS` for INSERT triggers (heuristic) |
| Neo4j | Always returns `false` (no auto-increment concept in graph DB) |
| Netezza | Queries `_v_table_column_def.attidentity = 'Y'` |

---

#### Method: `GetAutoIncrementColumns(ctx context.Context, db *sql.DB, table string) (map[string]bool, error)`

**What**: Returns a map of all auto-increment column names for a given table.

**Why**: Rather than checking each column individually, this method efficiently retrieves all auto-increment columns in one query. The returned map is passed to `BuildInsertStatement`, `BuildUpsertStatement`, and `BuildMergeStatement`.

**How**: Queries the same system catalogs as `IsAutoIncrementColumn` but returns all matching columns at once.

**Where**: `AutoIncrementDetector` interface in `dialect.go:124`.

**When**: Called once per table during pipeline setup. The result is cached and reused for all batch operations.

**Dialect differences**:

| Dialect | Query Target |
|---------|-------------|
| PostgreSQL | `information_schema.columns WHERE column_default LIKE 'nextval%'` |
| MySQL | `information_schema.COLUMNS WHERE EXTRA LIKE '%auto_increment%'` |
| SQLite | `PRAGMA table_info` + check `pk=1 AND type=INTEGER` |
| SQL Server | `sys.columns WHERE is_identity = 1` |
| Oracle | `ALL_TAB_COLUMNS WHERE IDENTITY_COLUMN = 'YES'` (12c+ only; returns empty for 10g/11g) |
| Neo4j | Returns empty `map[string]bool{}` |
| Netezza | `_v_table_column_def WHERE attidentity = 'Y'` |

---

### Sub-Interface: InsertBuilder (2 methods)

Defined at `dialect.go:127-134`.

---

#### Method: `BuildInsertStatement(table string, columns []string, autoInc map[string]bool) string`

**What**: Generates a parameterized `INSERT INTO ... VALUES (...)` statement, automatically excluding auto-increment columns.

**Why**: Each dialect uses different placeholder syntax, identifier quoting, and auto-increment handling. This method centralizes INSERT generation so the executor can call it uniformly.

**How**: Iterates columns, skips those in the `autoInc` map, builds column list with escaped identifiers and value list with dialect-specific placeholders.

**Where**: `InsertBuilder` interface in `dialect.go:131`.

**When**: Called by `InsertStrategy.ExecuteBatch` for every batch of records.

**Dialect differences**:

| Dialect | Output Example (table=`users`, cols=`[name, email]`) |
|---------|------------------------------------------------------|
| PostgreSQL | `INSERT INTO "users" ("name", "email") VALUES ($1, $2)` |
| MySQL | ``INSERT INTO `users` (`name`, `email`) VALUES (?, ?)`` |
| SQLite | `INSERT INTO "users" ("name", "email") VALUES (?, ?)` |
| SQL Server | `INSERT INTO [users] ([name], [email]) VALUES (@p1, @p2)` |
| Oracle | `INSERT INTO "users" ("name", "email") VALUES (:1, :2)` |
| Neo4j | `CREATE (n:`\``users`\`` {`\``name`\``: $1, `\``email`\``: $2})` (Cypher, delegates to BuildMergeStatement) |
| Netezza | `INSERT INTO "users" ("name", "email") VALUES ($1, $2)` |

---

#### Method: `BuildInsertStatementWithStatic(table string, dataCols, staticCols, staticVals []string) string`

**What**: Generates an INSERT statement that mixes parameterized data columns with static (literal/expression) values that are embedded directly in the SQL.

**Why**: Pipeline steps can define static values (e.g., `NOW()`, `'MIGRATED'`, `42`) that should be embedded as raw SQL expressions rather than bound as parameters. This supports computed defaults, audit timestamps, and fixed literals.

**How**: Builds the column/value lists with placeholders for `dataCols` and raw `staticVals` strings for `staticCols`. The caller is responsible for pre-quoting string literals via `staticval.QuoteLiteral`.

**Where**: `InsertBuilder` interface in `dialect.go:133`.

**When**: Called when a pipeline step has `staticValues` configured for certain columns.

**Dialect differences**:

| Dialect | Static Value Handling |
|---------|----------------------|
| PostgreSQL | Embeds `staticVals` as-is alongside `$N` placeholders |
| MySQL | Embeds `staticVals` as-is alongside `?` placeholders |
| SQLite | Embeds `staticVals` as-is alongside `?` placeholders |
| SQL Server | Embeds `staticVals` as-is alongside `@pN` placeholders |
| Oracle | Embeds `staticVals` as-is alongside `:N` placeholders |
| Neo4j | **Ignores static columns** -- delegates to `BuildInsertStatement(table, dataCols, nil)` |
| Netezza | **Ignores static columns** -- delegates to `BuildInsertStatement(table, dataCols, nil)` |

---

### Sub-Interface: UpdateBuilder (2 methods)

Defined at `dialect.go:136-142`.

---

#### Method: `BuildUpdateStatement(table string, columns []string, keyColumns []string) string`

**What**: Generates a parameterized `UPDATE ... SET ... WHERE ...` statement. Key columns appear only in the WHERE clause, not in SET.

**Why**: Updates must set non-key columns while using key columns to identify the target row. The parameter index must be continuous across SET and WHERE clauses.

**How**: Iterates `columns`, adds non-key columns to SET with incrementing placeholders, then adds key columns to WHERE with continuing placeholder indices.

**Where**: `UpdateBuilder` interface in `dialect.go:139`.

**When**: Called by `UpdateStrategy.ExecuteBatch` for every batch.

**Dialect differences**:

| Dialect | Output Example (cols=`[id, name, email]`, keys=`[id]`) |
|---------|---------------------------------------------------------|
| PostgreSQL | `UPDATE "t" SET "name" = $1, "email" = $2 WHERE "id" = $3` |
| MySQL | ``UPDATE `t` SET `name` = ?, `email` = ? WHERE `id` = ?`` |
| SQLite | `UPDATE "t" SET "name" = ?, "email" = ? WHERE "id" = ?` |
| SQL Server | `UPDATE [t] SET [name] = @p1, [email] = @p2 WHERE [id] = @p3` |
| Oracle | `UPDATE "t" SET "name" = :1, "email" = :2 WHERE "id" = :3` |
| Neo4j | ``MATCH (n:`t`) WHERE n.`id` = $3 SET n.`name` = $1, n.`email` = $2`` (Cypher) |
| Netezza | `UPDATE "t" SET "id" = $1, "name" = $2, "email" = $3 WHERE "id" = $4` (**Note**: Netezza does NOT skip key columns from SET) |

**Important Netezza difference**: The Netezza implementation does not exclude key columns from the SET clause -- it includes all columns in SET, then appends key columns to WHERE with separate placeholder indices. This is a behavioral deviation from the other 6 dialects.

---

#### Method: `BuildUpdateStatementWithStatic(table string, dataCols, keyCols, staticCols, staticVals []string) string`

**What**: Generates an UPDATE statement with both parameterized data columns and static literal/expression values in the SET clause.

**Why**: Same rationale as `BuildInsertStatementWithStatic` -- supports audit timestamps, fixed values, and computed expressions during updates.

**How**: Builds SET clause with parameterized non-key data columns first, then appends static column=value pairs. Key columns go in WHERE.

**Where**: `UpdateBuilder` interface in `dialect.go:141`.

**When**: Called when a pipeline step has `staticValues` configured for certain columns during update operations.

**Dialect differences**:

| Dialect | Static Value Handling |
|---------|----------------------|
| PostgreSQL | Static `col = expr` appended after parameterized SET entries |
| MySQL | Static `col = expr` appended after parameterized SET entries |
| SQLite | Static `col = expr` appended after parameterized SET entries |
| SQL Server | Static `col = expr` appended after parameterized SET entries |
| Oracle | Static `col = expr` appended after parameterized SET entries |
| Neo4j | **Ignores static columns** -- delegates to `BuildUpdateStatement` |
| Netezza | **Ignores static columns** -- delegates to `BuildUpdateStatement` |

---

### Sub-Interface: UpsertBuilder (2 methods)

Defined at `dialect.go:144-150`.

---

#### Method: `BuildUpsertStatement(table string, columns []string, keyColumns []string, autoInc map[string]bool) string`

**What**: Generates a dialect-specific upsert (insert-or-update) statement. Key columns are excluded from the UPDATE SET clause to avoid updating primary keys.

**Why**: Upsert is the most common write strategy for incremental data migration. Each dialect uses a completely different SQL syntax for this operation.

**How**: PostgreSQL/SQLite use `ON CONFLICT ... DO UPDATE SET`, MySQL uses `ON DUPLICATE KEY UPDATE`, SQL Server/Oracle delegate to `BuildMergeStatement`, Netezza generates a comment with transactional UPDATE+INSERT.

**Where**: `UpsertBuilder` interface in `dialect.go:147`.

**When**: Called by `UpsertStrategy.ExecuteBatch`. Central to incremental sync workflows.

**Dialect differences**:

| Dialect | Syntax Pattern |
|---------|---------------|
| PostgreSQL | `INSERT INTO "t" (...) VALUES (...) ON CONFLICT ("key") DO UPDATE SET "col" = EXCLUDED."col"` |
| MySQL | ``INSERT INTO `t` (...) VALUES (...) ON DUPLICATE KEY UPDATE `col` = VALUES(`col`)`` |
| SQLite | `INSERT INTO "t" (...) VALUES (...) ON CONFLICT ("key") DO UPDATE SET "col" = EXCLUDED."col"` |
| SQL Server | Delegates to `BuildMergeStatement` (MERGE INTO ... USING ... WHEN MATCHED/NOT MATCHED) |
| Oracle | Delegates to `BuildMergeStatement` (MERGE INTO ... USING DUAL ... WHEN MATCHED/NOT MATCHED) |
| Neo4j | Delegates to `BuildMergeStatement` (Cypher MERGE) |
| Netezza | Returns SQL comment: `-- UPSERT for Netezza requires transactional UPDATE+INSERT: ...` |

**Key design decision**: Key columns are excluded from the UPDATE SET clause in all dialects that support upsert. This prevents accidental primary key modification.

**Version-sensitive**: `VersionedDialect.BuildUpsertStatement` falls back to `BuildMergeStatement` for PostgreSQL < 9.5.

---

#### Method: `BuildUpsertStatementWithStatic(table string, dataCols, keyCols, staticCols, staticVals []string) string`

**What**: Generates an upsert statement with both parameterized and static values.

**Why**: Supports the same static value use cases as insert/update with static values, but in the upsert context. Static columns are included in both the INSERT values and the ON CONFLICT UPDATE SET.

**How**: Appends static columns to the column/value lists and adds them to the conflict update clause.

**Where**: `UpsertBuilder` interface in `dialect.go:149`.

**When**: Called when upsert operations have `staticValues` configured.

**Dialect differences**: Follow the same patterns as `BuildUpsertStatement`, with static values embedded as raw SQL. Neo4j and Netezza ignore static columns (delegate to non-static variants).

---

### Sub-Interface: MergeBuilder (2 methods)

Defined at `dialect.go:152-158`.

---

#### Method: `BuildMergeStatement(table string, columns []string, keyColumns []string, autoInc map[string]bool) string`

**What**: Generates a MERGE statement (or dialect equivalent). MERGE is the most complex DML pattern, supporting conditional INSERT and UPDATE in a single statement.

**Why**: SQL Server and Oracle have native MERGE syntax but no ON CONFLICT. PostgreSQL, MySQL, and SQLite have upsert but not MERGE -- they delegate merge to their upsert implementation. Neo4j's Cypher MERGE is a natural graph upsert. Netezza has neither.

**How**: Each dialect implements its own pattern:

**Where**: `MergeBuilder` interface in `dialect.go:155`.

**When**: Called by `MergeStrategy.ExecuteBatch` and as fallback for upsert on databases that lack native upsert.

**Dialect differences**:

| Dialect | Implementation Strategy |
|---------|------------------------|
| PostgreSQL | **Delegates to `BuildUpsertStatement`** -- `ON CONFLICT` is semantically equivalent |
| MySQL | **Delegates to `BuildUpsertStatement`** -- `ON DUPLICATE KEY UPDATE` is semantically equivalent |
| SQLite | **Delegates to `BuildUpsertStatement`** -- `ON CONFLICT` is semantically equivalent |
| SQL Server | Full `MERGE INTO target USING (SELECT @p1, @p2, ...) AS src (...) ON target.key = src.key WHEN MATCHED THEN UPDATE SET ... WHEN NOT MATCHED THEN INSERT (...) VALUES (...);` |
| Oracle | Full `MERGE INTO target USING (SELECT :1 AS "col", ... FROM DUAL) src ON (target."key" = src."key") WHEN MATCHED THEN UPDATE SET ... WHEN NOT MATCHED THEN INSERT (...) VALUES (...)` |
| Neo4j | Cypher: `MERGE (n:Label {key: $1}) SET n += $props` (with key columns) or `CREATE (n:Label {props})` (without key columns) |
| Netezza | **Delegates to `BuildUpsertStatement`** -- returns the same SQL comment about transactional fallback |

**SQL Server vs Oracle MERGE differences**:
- SQL Server uses `AS target` / `AS src` aliases and terminates with `;`
- Oracle uses `target` (no AS) and `USING (SELECT ... FROM DUAL)` (no subquery)
- SQL Server source is `USING (SELECT @p1, @p2, ...) AS src (col1, col2, ...)`
- Oracle source is `USING (SELECT :1 AS "col1", :2 AS "col2" FROM DUAL) src`

---

#### Method: `BuildMergeStatementWithStatic(table string, dataCols, keyCols, staticCols, staticVals []string) string`

**What**: Generates a MERGE statement with both parameterized and static values.

**Why**: Supports static expressions (timestamps, literals) in merge operations.

**How**: Same pattern as `BuildMergeStatement` but interleaves static values into the source row definition and update SET clause.

**Where**: `MergeBuilder` interface in `dialect.go:157`.

**When**: Called when merge operations have `staticValues` configured.

**Dialect differences**: PostgreSQL/MySQL/SQLite delegate to their respective `BuildUpsertStatementWithStatic`. SQL Server and Oracle embed static values into the USING subquery and UPDATE SET clause. Neo4j and Netezza delegate to their non-static merge variants (ignoring static columns).

---

### Sub-Interface: TypeMapper (3 methods)

Defined at `dialect.go:160-168`.

---

#### Method: `MapDataType(genericType string, length, precision, scale *int) string`

**What**: Converts a generic/portable data type name (e.g., `VARCHAR`, `BIGINT`, `BOOLEAN`) to the dialect-specific native type.

**Why**: CREATE TABLE DDL must use native types. The migrator's pipeline configuration uses generic type names for portability; this method handles the translation.

**How**: Switch on uppercase generic type name, applying optional length/precision/scale parameters.

**Where**: `TypeMapper` interface in `dialect.go:163`.

**When**: Called by `BuildCreateTableStatement` and potentially during schema comparison operations.

**Cross-dialect type mapping table**:

| Generic Type | PostgreSQL | MySQL | SQLite | SQL Server | Oracle | Neo4j | Netezza |
|-------------|-----------|-------|--------|-----------|--------|-------|---------|
| `VARCHAR` | `VARCHAR(N)` / `VARCHAR(255)` | `VARCHAR(N)` / `VARCHAR(255)` | `TEXT` | `NVARCHAR(N)` / `NVARCHAR(255)` | `VARCHAR2(N)` / `VARCHAR2(255)` | `STRING` | `VARCHAR(N)` / `VARCHAR(255)` |
| `INTEGER` | `INTEGER` | `INT` | `INTEGER` | `INT` | `NUMBER(10)` | `INTEGER` | `INTEGER` |
| `BIGINT` | `BIGINT` | `BIGINT` | `INTEGER` | `BIGINT` | `NUMBER(19)` | `LONG` | `BIGINT` |
| `DECIMAL` | `NUMERIC(P,S)` / `NUMERIC(19,4)` | `DECIMAL(P,S)` / `DECIMAL(19,4)` | `REAL` | `DECIMAL(P,S)` / `DECIMAL(19,4)` | `NUMBER(P,S)` / `NUMBER(19,4)` | *(unmapped)* | `NUMERIC(P,S)` / `NUMERIC(18,2)` |
| `FLOAT` | `REAL` | `FLOAT` | `REAL` | `REAL` | `BINARY_FLOAT` | `FLOAT` | `FLOAT` |
| `DOUBLE` | `DOUBLE PRECISION` | `DOUBLE` | `REAL` | `FLOAT` | `BINARY_DOUBLE` | `DOUBLE` | `DOUBLE` |
| `BOOLEAN` | `BOOLEAN` | `TINYINT(1)` | `INTEGER` | `BIT` | `NUMBER(1)` | `BOOLEAN` | `BOOLEAN` |
| `DATE` | `DATE` | `DATE` | `TEXT` | `DATE` | `DATE` | `DATE` | `DATE` |
| `TIMESTAMP` | `TIMESTAMP` | `DATETIME` | `TEXT` | `DATETIME2` | `TIMESTAMP` | `DATETIME` | `TIMESTAMP` |
| `TEXT` | `TEXT` | `LONGTEXT` | `TEXT` | `NVARCHAR(MAX)` | `CLOB` | `STRING` | `VARCHAR(64000)` |
| `BLOB` | `BYTEA` | `LONGBLOB` | `BLOB` | `VARBINARY(MAX)` | `BLOB` | `BLOB` | `BYTEA` |
| Default | `VARCHAR(255)` | `VARCHAR(255)` | `TEXT` | `NVARCHAR(255)` | `VARCHAR2(255)` | `STRING` | `VARCHAR(255)` |

---

#### Method: `BuildCreateTableStatement(table string, cols []ColumnDefinition, pks []string) string`

**What**: Generates a complete `CREATE TABLE` DDL statement with column definitions, auto-increment markers, nullability, defaults, and primary key constraints.

**Why**: The migrator can auto-create target tables when they do not exist. Each database has different DDL syntax for auto-increment, identity, and primary key declaration.

**How**: Iterates `ColumnDefinition` structs, builds column type + constraints, applies `sanitizeDefaultValue()` for injection safety, appends PK constraint.

**Where**: `TypeMapper` interface in `dialect.go:165`.

**When**: Called during the `gencsv`/`genschema` modes or when auto-creating target tables.

**Dialect differences for auto-increment columns**:

| Dialect | Auto-Increment Syntax |
|---------|----------------------|
| PostgreSQL | `SERIAL` type keyword |
| MySQL | `AUTO_INCREMENT` suffix after type |
| SQLite | `INTEGER PRIMARY KEY AUTOINCREMENT` (inline PK, no separate PK constraint) |
| SQL Server | `IDENTITY(1,1)` suffix after type |
| Oracle | `GENERATED ALWAYS AS IDENTITY` suffix |
| Neo4j | `CREATE CONSTRAINT ON (n:Label) ASSERT n.col IS UNIQUE` (no tables) |
| Netezza | `IDENTITY(1,1)` suffix after type |

**SQLite special behavior**: When an auto-increment column exists, the separate `PRIMARY KEY (...)` constraint is omitted because `INTEGER PRIMARY KEY AUTOINCREMENT` already declares the PK inline.

**Neo4j special behavior**: Returns uniqueness constraints for auto-increment columns, or `-- Neo4j is schema-less; no table structure needed` if none.

**Default value safety**: All dialects pass default values through `sanitizeDefaultValue()` which rejects anything not matching the safe pattern (numbers, quoted strings, NULL, TRUE, FALSE, known SQL functions). Unsafe defaults are silently dropped.

---

#### Method: `GetPrimaryKeyColumns(ctx context.Context, db *sql.DB, table string) ([]string, error)`

**What**: Queries the database to discover the primary key columns of an existing table.

**Why**: When key columns are not explicitly configured in the pipeline YAML, the migrator auto-detects them from the target table's primary key. This is needed for UPDATE, UPSERT, and MERGE statements.

**How**: Queries dialect-specific system catalog tables.

**Where**: `TypeMapper` interface in `dialect.go:167`.

**When**: Called during pipeline setup when `keyColumns` are not explicitly specified.

**Dialect differences**:

| Dialect | System Catalog Query |
|---------|---------------------|
| PostgreSQL | `pg_index` + `pg_attribute` joined on `indrelid`, filtered by `indisprimary` |
| MySQL | `information_schema.KEY_COLUMN_USAGE WHERE CONSTRAINT_NAME = 'PRIMARY'` |
| SQLite | `PRAGMA table_info(...)` filtered by `pk > 0` |
| SQL Server | `sys.index_columns` + `sys.columns` + `sys.indexes` filtered by `is_primary_key = 1` |
| Oracle | `ALL_CONSTRAINTS` + `ALL_CONS_COLUMNS` filtered by `CONSTRAINT_TYPE = 'P'` (table name uppercased) |
| Neo4j | Returns empty slice (no traditional PKs) |
| Netezza | `_v_table_key_key WHERE name = $1 ORDER BY seq_num` (table name uppercased) |

---

### Sub-Interface: ReturningHandler (3 methods)

Defined at `dialect.go:170-178`.

---

#### Method: `SupportsReturningClause() bool`

**What**: Returns whether the database supports a `RETURNING` (or `OUTPUT`) clause on INSERT statements to retrieve generated values.

**Why**: When inserting rows with auto-generated columns (identity, serial, default values), the migrator may need the generated values for downstream steps. RETURNING is more efficient than a separate SELECT.

**How**: Returns a hardcoded boolean.

**Where**: `ReturningHandler` interface in `dialect.go:173`.

**When**: Checked when deciding whether to append RETURNING/OUTPUT to INSERT statements.

**Dialect values**:

| Dialect | Value | Mechanism |
|---------|-------|-----------|
| PostgreSQL | `true` | `RETURNING *` clause |
| MySQL | **`false`** | No RETURNING support |
| SQLite | `true` | `RETURNING *` (3.35+) |
| SQL Server | `true` | `OUTPUT INSERTED.*` clause |
| Oracle | `true` | `RETURNING ... INTO ...` clause |
| Neo4j | **`false`** | N/A |
| Netezza | **`false`** | No RETURNING support |

---

#### Method: `SupportsBatchReturning() bool`

**What**: Returns whether the RETURNING clause works correctly with multi-row (batch) INSERT statements.

**Why**: Some databases support RETURNING for single-row inserts but not multi-row VALUES lists. If batch returning is not supported, the executor must fall back to single-row inserts when generated values are needed.

**How**: Returns a hardcoded boolean.

**Where**: `ReturningHandler` interface in `dialect.go:175`.

**When**: Checked when the executor needs to decide between batch insert with RETURNING or single-row inserts.

**Dialect values**:

| Dialect | Value | Notes |
|---------|-------|-------|
| PostgreSQL | `true` | Full batch RETURNING support |
| MySQL | **`false`** | N/A (no RETURNING at all) |
| SQLite | **`false`** | RETURNING exists but unreliable with multi-row |
| SQL Server | `true` | OUTPUT works with multi-row |
| Oracle | **`false`** | RETURNING INTO does not work with multi-row |
| Neo4j | **`false`** | N/A |
| Netezza | **`false`** | N/A |

---

#### Method: `GetLastInsertIdQuery() string`

**What**: Returns a SQL query to retrieve the last auto-generated insert ID when RETURNING is not available or not used.

**Why**: Fallback mechanism for databases/scenarios where RETURNING is not used. MySQL, for example, lacks RETURNING and must use `LAST_INSERT_ID()`.

**How**: Returns a hardcoded query string.

**Where**: `ReturningHandler` interface in `dialect.go:177`.

**When**: Called after single-row inserts when the generated ID is needed and RETURNING was not used.

**Dialect values**:

| Dialect | Query | Notes |
|---------|-------|-------|
| PostgreSQL | `SELECT lastval()` | Returns last sequence value in session |
| MySQL | `SELECT LAST_INSERT_ID()` | Returns last auto-increment value |
| SQLite | `SELECT last_insert_rowid()` | Returns last ROWID |
| SQL Server | `SELECT SCOPE_IDENTITY()` | Returns last identity in current scope |
| Oracle | `""` (empty) | Not applicable -- uses RETURNING or sequences directly |
| Neo4j | `""` (empty) | Not applicable |
| Netezza | `SELECT LAST_INSERT_ID()` | Netezza identity retrieval |

---

### Sub-Interface: IdentityHandler (3 methods)

Defined at `dialect.go:180-188`.

---

#### Method: `NeedsIdentityInsert(autoInc map[string]bool, columns []string) bool`

**What**: Returns whether `SET IDENTITY_INSERT ON` is required before inserting data into the table. This is exclusively a SQL Server concern.

**Why**: SQL Server prevents inserting explicit values into IDENTITY columns unless `IDENTITY_INSERT` is enabled for the table. When migrating data that includes identity column values (e.g., preserving original IDs), this must be turned on.

**How**: SQL Server checks if any column in the insert list is in the `autoInc` map. All other dialects return `false`.

**Where**: `IdentityHandler` interface in `dialect.go:183`.

**When**: Called before executing INSERT batches to determine if IDENTITY_INSERT wrapper statements are needed.

**Dialect values**:

| Dialect | Behavior |
|---------|----------|
| PostgreSQL | Always `false` |
| MySQL | Always `false` |
| SQLite | Always `false` |
| SQL Server | `true` if any insert column is in `autoInc` map |
| Oracle | Always `false` |
| Neo4j | Always `false` |
| Netezza | Always `false` |

---

#### Method: `GetIdentityInsertOnStatement(table string) string`

**What**: Returns the SQL statement to enable IDENTITY_INSERT for a table.

**Why**: SQL Server requires this before inserting explicit values into identity columns. Must be executed within the same transaction as the INSERT.

**How**: SQL Server returns `SET IDENTITY_INSERT [table] ON`. All other dialects return empty string.

**Where**: `IdentityHandler` interface in `dialect.go:185`.

**When**: Called before INSERT execution when `NeedsIdentityInsert` returns `true`.

**Dialect values**:

| Dialect | Output |
|---------|--------|
| SQL Server | `SET IDENTITY_INSERT [tablename] ON` |
| All others | `""` (empty string) |

---

#### Method: `GetIdentityInsertOffStatement(table string) string`

**What**: Returns the SQL statement to disable IDENTITY_INSERT for a table.

**Why**: IDENTITY_INSERT must be turned off after the insert operation completes. Only one table can have IDENTITY_INSERT ON at a time per session in SQL Server.

**How**: SQL Server returns `SET IDENTITY_INSERT [table] OFF`. All other dialects return empty string.

**Where**: `IdentityHandler` interface in `dialect.go:187`.

**When**: Called after INSERT execution when `NeedsIdentityInsert` returned `true`.

**Dialect values**:

| Dialect | Output |
|---------|--------|
| SQL Server | `SET IDENTITY_INSERT [tablename] OFF` |
| All others | `""` (empty string) |

---

### Sub-Interface: StaticExpressionMapper (1 method)

Defined at `dialect.go:190-196`.

---

#### Method: `MapStaticExpression(expr string) (string, error)`

**What**: Translates a generic/portable static expression (e.g., `NOW()`, `UUID()`, `CURRENT_DATE`) to the dialect-specific SQL equivalent. Also validates that the expression is safe for direct SQL embedding.

**Why**: Pipeline configurations use portable expression names (`NOW()`, `UUID()`). Each database has different function names for the same operation. Additionally, this method acts as a security gate -- rejecting arbitrary SQL to prevent injection in DDL/DML contexts.

**How**: Uppercases the input, looks it up in a dialect-specific mapping table. If not found, checks against `safeDefaultPattern` (numbers, quoted strings, NULL, TRUE, FALSE, known SQL functions). Returns an error for unrecognized/unsafe expressions.

**Where**: `StaticExpressionMapper` interface in `dialect.go:195`.

**When**: Called during pipeline step configuration to translate static expressions before embedding them in SQL statements.

**Expression mapping table**:

| Generic Expression | PostgreSQL | MySQL | SQLite | SQL Server | Oracle | Neo4j | Netezza |
|-------------------|-----------|-------|--------|-----------|--------|-------|---------|
| `NOW()` | `NOW()` | `NOW()` | `datetime('now')` | `GETDATE()` | `SYSDATE` | `datetime()` | `NOW()` |
| `CURRENT_TIMESTAMP` | `CURRENT_TIMESTAMP` | `CURRENT_TIMESTAMP` | `CURRENT_TIMESTAMP` | `CURRENT_TIMESTAMP` | `CURRENT_TIMESTAMP` | `datetime()` | `CURRENT_TIMESTAMP` |
| `CURRENT_DATE` | `CURRENT_DATE` | `CURRENT_DATE` | `date('now')` | `CAST(GETDATE() AS DATE)` | `TRUNC(SYSDATE)` | `date()` | `CURRENT_DATE` |
| `CURRENT_TIME` | `CURRENT_TIME` | `CURRENT_TIME` | `time('now')` | `CAST(GETDATE() AS TIME)` | `CURRENT_TIMESTAMP` | `time()` | `CURRENT_TIME` |
| `UUID()` | `GEN_RANDOM_UUID()` | `UUID()` | `lower(hex(randomblob(16)))` | `NEWID()` | `SYS_GUID()` | `randomUUID()` | `UUID()` |

**Safe literal passthrough**: Numbers (`42`, `-3.14`), quoted strings (`'hello'`), `NULL`, `TRUE`, `FALSE` pass through unchanged for all dialects.

**Unsafe expression rejection**: Expressions like `DROP TABLE x`, `1; DELETE FROM y`, `SELECT * FROM users` return an error: `"unsafe static expression: ... (not in whitelist)"`.

**Case insensitivity**: Lookups are case-insensitive -- `now()`, `Now()`, `NOW()` all map correctly.

**Whitespace tolerance**: Leading/trailing whitespace is trimmed before lookup.

---

## Part B: Per-Dialect Summaries

---

### PostgreSQL

| Property | Value |
|----------|-------|
| **Struct** | `PostgreSQLDialect` |
| **Driver name** | `pgx` (`github.com/jackc/pgx/v5/stdlib`) |
| **Database type** | `"postgresql"` |
| **Placeholder style** | `$1`, `$2`, `$3` (positional) |
| **Identifier quoting** | Double quotes: `"identifier"` |
| **Optimal batch size** | 50,000 |
| **Concurrent writes** | Yes (MVCC) |
| **Upsert support** | `ON CONFLICT ... DO UPDATE SET` (9.5+) |
| **Merge strategy** | Delegates to upsert (ON CONFLICT) |
| **Auto-increment** | Sequences via `SERIAL` type; detected by `NEXTVAL` in column_default |
| **RETURNING** | Full support, including batch |
| **IDENTITY_INSERT** | Not applicable |
| **CastPlaceholder** | `$1::int8` style PostgreSQL cast operator |
| **UUID function** | `GEN_RANDOM_UUID()` |
| **Special behaviors** | Only dialect that uses `::` cast syntax. CastPlaceholder maps all types to PG-native names (int8, int4, int2, numeric, float4, float8, bool, date, timestamp, text, bytea). |
| **Version-aware features** | `VersionedDialect` disables upsert for PG < 9.5 and falls back upsert to merge (which is also upsert on PG, creating a circular delegation). |

---

### MySQL

| Property | Value |
|----------|-------|
| **Struct** | `MySQLDialect` |
| **Driver name** | `mysql` (`github.com/go-sql-driver/mysql`) |
| **Database type** | `"mysql"` |
| **Placeholder style** | `?` (positional-agnostic, index ignored) |
| **Identifier quoting** | Backticks: `` `identifier` `` |
| **Optimal batch size** | 50,000 |
| **Concurrent writes** | Yes (InnoDB row-level locking) |
| **Upsert support** | `ON DUPLICATE KEY UPDATE col = VALUES(col)` |
| **Merge strategy** | Delegates to upsert (ON DUPLICATE KEY UPDATE) |
| **Auto-increment** | `AUTO_INCREMENT` column attribute; detected via `EXTRA` in information_schema |
| **RETURNING** | Not supported |
| **IDENTITY_INSERT** | Not applicable |
| **CastPlaceholder** | Returns placeholder unchanged (implicit coercion) |
| **UUID function** | `UUID()` (native) |
| **Special behaviors** | BOOLEAN maps to `TINYINT(1)`. TEXT maps to `LONGTEXT`. BLOB maps to `LONGBLOB`. TIMESTAMP maps to `DATETIME`. No RETURNING clause -- must use `SELECT LAST_INSERT_ID()`. |

---

### SQLite

| Property | Value |
|----------|-------|
| **Struct** | `SQLiteDialect` |
| **Driver name** | `sqlite` (`modernc.org/sqlite`) |
| **Database type** | `"sqlite"` |
| **Placeholder style** | `?` (positional-agnostic, index ignored) |
| **Identifier quoting** | Double quotes: `"identifier"` |
| **Optimal batch size** | 5,000 (smallest of all dialects) |
| **Concurrent writes** | **No** (single-writer, file-level locking) |
| **Upsert support** | `ON CONFLICT ... DO UPDATE SET col = EXCLUDED.col` (3.24+) |
| **Merge strategy** | Delegates to upsert (ON CONFLICT) |
| **Auto-increment** | `INTEGER PRIMARY KEY AUTOINCREMENT`; detected by parsing CREATE TABLE SQL from sqlite_master |
| **RETURNING** | Supported (3.35+) but NOT for batch (multi-row) inserts |
| **IDENTITY_INSERT** | Not applicable |
| **CastPlaceholder** | Returns placeholder unchanged (dynamic typing) |
| **UUID function** | `lower(hex(randomblob(16)))` (no native UUID) |
| **Special behaviors** | `SupportsConcurrentWrites()=false` forces `MaxOpenConns=1`. All numeric types (`BIGINT`, `DECIMAL`, `FLOAT`, `DOUBLE`) map to either `INTEGER` or `REAL`. All temporal types (`DATE`, `TIMESTAMP`) map to `TEXT`. In `BuildCreateTableStatement`, when auto-increment exists, the PK constraint is declared inline (`INTEGER PRIMARY KEY AUTOINCREMENT`) and the separate `PRIMARY KEY (...)` clause is omitted. |

---

### SQL Server

| Property | Value |
|----------|-------|
| **Struct** | `SQLServerDialect` |
| **Driver name** | `sqlserver` (`github.com/microsoft/go-mssqldb`) |
| **Database type** | `"sqlserver"` |
| **Placeholder style** | `@p1`, `@p2`, `@p3` (named positional) |
| **Identifier quoting** | Square brackets: `[identifier]` |
| **Optimal batch size** | 10,000 |
| **Concurrent writes** | Yes |
| **Upsert support** | **No native upsert** -- delegates to MERGE |
| **Merge strategy** | Full ANSI MERGE: `MERGE INTO target AS target USING (SELECT @p1, @p2) AS src (col1, col2) ON target.key = src.key WHEN MATCHED THEN UPDATE SET ... WHEN NOT MATCHED THEN INSERT (...) VALUES (...);` |
| **Auto-increment** | `IDENTITY(1,1)`; detected via `sys.columns.is_identity` |
| **RETURNING** | Yes via `OUTPUT` clause, supports batch |
| **IDENTITY_INSERT** | **Yes** -- only dialect that implements this. `NeedsIdentityInsert` returns `true` when inserting into identity columns. Wraps inserts with `SET IDENTITY_INSERT [table] ON/OFF`. |
| **CastPlaceholder** | `CAST(@p1 AS BIGINT)` style |
| **UUID function** | `NEWID()` |
| **Special behaviors** | Only dialect requiring IDENTITY_INSERT management. Uses NVARCHAR instead of VARCHAR (Unicode-aware). BOOLEAN maps to BIT. MERGE statement terminates with semicolon. Uses `SCOPE_IDENTITY()` for last insert ID (not `@@IDENTITY`, which crosses scopes). CastPlaceholder maps to SQL Server native types (BIT, DATETIME2, NVARCHAR, VARBINARY). Version detection parses SQL Server year (2019, 2022) as the major version. |

---

### Oracle

| Property | Value |
|----------|-------|
| **Struct** | `OracleDialect` |
| **Driver name** | `oracle` (`github.com/sijms/go-ora/v2`) |
| **Database type** | `"oracle"` |
| **Placeholder style** | `:1`, `:2`, `:3` (colon-prefixed positional) |
| **Identifier quoting** | Double quotes: `"identifier"` |
| **Optimal batch size** | 10,000 |
| **Concurrent writes** | Yes (MVCC via undo segments) |
| **Upsert support** | **No native upsert** -- delegates to MERGE |
| **Merge strategy** | Oracle MERGE with DUAL: `MERGE INTO "t" target USING (SELECT :1 AS "col1", :2 AS "col2" FROM DUAL) src ON (target."key" = src."key") WHEN MATCHED THEN UPDATE SET ... WHEN NOT MATCHED THEN INSERT (...) VALUES (...)` |
| **Auto-increment** | **Dual detection**: 12c+ `GENERATED ALWAYS AS IDENTITY`; 10g/11g fallback checks for INSERT triggers (heuristic, not 100% accurate) |
| **RETURNING** | Supported for single rows, NOT for batch |
| **IDENTITY_INSERT** | Not applicable |
| **CastPlaceholder** | `CAST(:1 AS NUMBER(19))` style |
| **UUID function** | `SYS_GUID()` |
| **Special behaviors** | Table/column names are uppercased in catalog queries (Oracle stores metadata in uppercase). Uses `NUMBER(N)` for all integer types (no native INT/BIGINT). `FLOAT` maps to `BINARY_FLOAT`, `DOUBLE` to `BINARY_DOUBLE`. `GetLastInsertIdQuery` returns empty string (Oracle uses RETURNING or explicit sequence.NEXTVAL). MERGE uses `FROM DUAL` instead of a subquery. `NOW()` maps to `SYSDATE` (not a function call). `CURRENT_DATE` maps to `TRUNC(SYSDATE)`. |

---

### Neo4j

| Property | Value |
|----------|-------|
| **Struct** | `Neo4jDialect` (has `version` field, default `"5.0.0"`) |
| **Driver name** | `neo4j` (official Neo4j Go driver) |
| **Database type** | `"neo4j"` |
| **Placeholder style** | `$1`, `$2`, `$3` (same as PostgreSQL/Netezza) |
| **Identifier quoting** | Backticks: `` `identifier` `` (same as MySQL) |
| **Optimal batch size** | 1,000 (smallest non-SQLite) |
| **Concurrent writes** | Yes |
| **Upsert support** | Yes (Cypher MERGE is native upsert) |
| **Merge strategy** | Cypher: `MERGE (n:Label {key: $N}) SET n += $props` or `CREATE (n:Label {props})` |
| **Auto-increment** | Not applicable -- always returns `false`/empty map |
| **RETURNING** | Not supported |
| **IDENTITY_INSERT** | Not applicable |
| **CastPlaceholder** | Returns placeholder unchanged |
| **UUID function** | `randomUUID()` |
| **Special behaviors** | Graph database -- fundamentally different from relational dialects. `BuildCreateTableStatement` creates uniqueness constraints (not tables): `CREATE CONSTRAINT ON (n:Label) ASSERT n.col IS UNIQUE`. If no auto-increment columns, returns `-- Neo4j is schema-less; no table structure needed`. `GetPrimaryKeyColumns` returns empty slice. `BuildInsertStatement` delegates to `BuildMergeStatement`. All `*WithStatic` methods **ignore static columns** and delegate to non-static equivalents. `BuildUpdateStatement` generates Cypher: `MATCH (n:Label) WHERE n.key = $N SET n.col = $N`. |

---

### Netezza

| Property | Value |
|----------|-------|
| **Struct** | `NetezzaDialect` (has `version` field, default `"7.0.0"`) |
| **Driver name** | `netezza` |
| **Database type** | `"netezza"` |
| **Placeholder style** | `$1`, `$2`, `$3` (same as PostgreSQL) |
| **Identifier quoting** | Double quotes: `"identifier"` (same as PostgreSQL) |
| **Optimal batch size** | 10,000 |
| **Concurrent writes** | Yes (MPP architecture) |
| **Upsert support** | **No** -- no native upsert or merge |
| **Merge strategy** | Returns SQL comment: `-- UPSERT for Netezza requires transactional UPDATE+INSERT: ...` |
| **Auto-increment** | `IDENTITY(1,1)` columns; detected via `_v_table_column_def.attidentity = 'Y'` |
| **RETURNING** | Not supported |
| **IDENTITY_INSERT** | Not applicable |
| **CastPlaceholder** | Returns placeholder unchanged (implicit coercion) |
| **UUID function** | `UUID()` |
| **Special behaviors** | PostgreSQL-derived but with significant limitations. No MERGE, no UPSERT, no RETURNING. TEXT maps to `VARCHAR(64000)` (Netezza's max VARCHAR). Table names uppercased in catalog queries. `BuildUpdateStatement` does NOT exclude key columns from SET (behavioral deviation from all other dialects). All `*WithStatic` methods **ignore static columns** and delegate to non-static equivalents. `GetLastInsertIdQuery` returns `SELECT LAST_INSERT_ID()`. Has `parseVersion()` helper for major version extraction. |

---

## Cross-Dialect Quick Reference Tables

### Placeholder and Quoting Styles

| Dialect | Placeholder | Quote Start | Quote End | Quote Escape |
|---------|------------|-------------|-----------|-------------|
| PostgreSQL | `$N` | `"` | `"` | `""` |
| MySQL | `?` | `` ` `` | `` ` `` | ` `` ` |
| SQLite | `?` | `"` | `"` | `""` |
| SQL Server | `@pN` | `[` | `]` | `]]` |
| Oracle | `:N` | `"` | `"` | `""` |
| Neo4j | `$N` | `` ` `` | `` ` `` | ` `` ` |
| Netezza | `$N` | `"` | `"` | `""` |

### Capability Matrix

| Capability | PG | MySQL | SQLite | SS | Oracle | Neo4j | Netezza |
|-----------|-----|-------|--------|-----|--------|-------|---------|
| Concurrent Writes | Y | Y | **N** | Y | Y | Y | Y |
| Native Upsert | Y | Y | Y | **N** | **N** | Y | **N** |
| RETURNING Clause | Y | **N** | Y | Y | Y | **N** | **N** |
| Batch RETURNING | Y | **N** | **N** | Y | **N** | **N** | **N** |
| IDENTITY_INSERT | N/A | N/A | N/A | **Y** | N/A | N/A | N/A |
| CastPlaceholder | `::` | noop | noop | `CAST()` | `CAST()` | noop | noop |
| Static Values in SQL | Y | Y | Y | Y | Y | **ignored** | **ignored** |

### Upsert/Merge Strategy Matrix

| Dialect | Upsert Method | Merge Method |
|---------|--------------|-------------|
| PostgreSQL | `ON CONFLICT ... DO UPDATE` | Delegates to Upsert |
| MySQL | `ON DUPLICATE KEY UPDATE` | Delegates to Upsert |
| SQLite | `ON CONFLICT ... DO UPDATE` | Delegates to Upsert |
| SQL Server | Delegates to Merge | `MERGE INTO ... USING (SELECT) AS src ON ... WHEN MATCHED/NOT MATCHED` |
| Oracle | Delegates to Merge | `MERGE INTO ... USING (SELECT FROM DUAL) ON ... WHEN MATCHED/NOT MATCHED` |
| Neo4j | Delegates to Merge | Cypher `MERGE (n:Label {key}) SET n += $props` |
| Netezza | SQL comment (transactional fallback) | Delegates to Upsert (same comment) |

---

## VersionedDialect Wrapper

**File**: `internal/dialect/version.go`

**What**: `VersionedDialect` wraps any `DatabaseDialect` implementation and overrides version-sensitive behavior. All 27 interface methods are delegated to the inner dialect; only version-affected methods have override logic.

**Version Detection**: `DetectVersion(ctx, db, dbType)` queries:
- PostgreSQL/MySQL: `SELECT version()`
- SQL Server: `SELECT @@VERSION`
- Oracle: `SELECT BANNER FROM V$VERSION WHERE ROWNUM = 1`
- SQLite: `SELECT sqlite_version()`

**Version Parsing**: `ParseVersion(raw)` extracts `Major.Minor.Patch` from version strings. Special handling for SQL Server which returns `"Microsoft SQL Server 20XX"` -- extracts year as major version.

**Current Version-Sensitive Overrides**:

| Method | Override Condition | Behavior |
|--------|-------------------|----------|
| `SupportsUpsert()` | PostgreSQL < 9.5 | Returns `false` |
| `BuildUpsertStatement()` | PostgreSQL < 9.5 | Falls back to `BuildMergeStatement` |
| `BuildUpsertStatementWithStatic()` | PostgreSQL < 9.5 | Falls back to `BuildMergeStatementWithStatic` |

**DBVersion.AtLeast(major, minor)**: Comparison method used for version checks. Compares major first, then minor. Patch is not considered.

---

## Helper Functions (Internal)

**`escapeStaticValue(v string) string`** (`dialect.go:12`): Doubles single quotes in static values. Note: current architecture has the caller pre-quote literals via `staticval.QuoteLiteral`, so this function exists but statement builders embed static values as-is.

**`sanitizeDefaultValue(val string) string`** (`dialect.go:42`): Validates that a DEFAULT value is safe for DDL inclusion. Returns the value if it matches `safeDefaultPattern`, or empty string if potentially dangerous. Used by all `BuildCreateTableStatement` implementations.

**`safeDefaultPattern`** (`dialect.go:21`): Regex matching safe DEFAULT values: numbers, single-quoted strings, NULL, TRUE, FALSE, CURRENT_TIMESTAMP, CURRENT_DATE, CURRENT_TIME, NOW(), GETDATE(), SYSDATE, NEWID(), UUID(), GEN_RANDOM_UUID().

**`mapStaticExpression(expr, dialectMap)`** (`dialect.go:287`): Shared implementation used by all 7 dialects' `MapStaticExpression`. Uppercases input, checks dialect map, falls back to safeDefaultPattern, returns error for unsafe expressions.

**`isKeyColumn(col, keyColumns)`** (`dialect.go:275`): Linear scan to check if a column is in the key column list.

**`joinEscaped(d, cols)`** (`dialect.go:251`): Builds comma-separated escaped identifiers.

**`joinPlaceholders(d, startIdx, count)`** (`dialect.go:263`): Builds comma-separated placeholders for a range of indices.
