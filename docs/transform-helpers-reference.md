# Mass Migrator v3 -- JavaScript Transform Helper Functions Reference

**Version**: v3 (Go)
**Total registered helpers**: 148 functions
**Source**: `internal/transform/engine.go` -- `bindHelpers()`, `bindLookupService()`, and `TransformContext` methods

All functions below are available in transform step JavaScript scripts. They are registered onto the goja JS runtime at engine initialization.

---

## Table of Contents

1. [String Functions](#1-string-functions) (21)
2. [Date/Time Functions](#2-datetime-functions) (24)
3. [Math Functions](#3-math-functions) (14)
4. [Hash/UUID Functions](#4-hashuuid-functions) (4)
5. [Type Conversion Functions](#5-type-conversion-functions) (12)
6. [Validation Functions](#6-validation-functions) (7)
7. [Masking Functions](#7-masking-functions) (6)
8. [Array Functions](#8-array-functions) (16)
9. [Regex Functions](#9-regex-functions) (5)
10. [JSON Functions](#10-json-functions) (14)
11. [XML Functions](#11-xml-functions) (12)
12. [Encoding Functions](#12-encoding-functions) (6)
13. [Statistics Functions](#13-statistics-functions) (4)
14. [Cross-Record Functions](#14-cross-record-functions) (17)
15. [Window Functions](#15-window-functions) (3)
16. [Misc/SQL-Like Functions](#16-miscsql-like-functions) (11)
17. [Context Functions](#17-context-functions) (via `ctx` object) (19)
18. [Lookup Functions](#18-lookup-functions) (2)
19. [Typed Record Accessors](#19-typed-record-accessors) (5)

---

## 1. String Functions

### Function: `coalesce(...values) -> any`

**What**: Returns the first non-null, non-empty argument.

**Why**: Handle nullable fields by providing fallback values, similar to SQL `COALESCE`.

**How**: Iterates arguments; returns first where `v != nil && v != ""`.

**Where**: `internal/transform/helpers.go`, registered in `engine.go` with a variadic wrapper.

**When**: Data cleansing when multiple source fields may contain the desired value.

**Signature**: `coalesce(val1, val2, ...) -> any`

**Parameters**:
| Param | Type | Description |
|-------|------|-------------|
| `...values` | any | Candidate values, checked left to right |

**Returns**: First non-null/non-empty value, or `null` if all are null/empty.

**Example**:
```javascript
record.name = coalesce(record.preferred_name, record.first_name, "Unknown");
```

---

### Function: `nvl(value, default) -> any`

**What**: Returns `value` if non-null/non-empty, otherwise `default`.

**Why**: Oracle-style null substitution for single-field defaults.

**How**: Checks `value == nil || value == ""`; returns `defaultValue` if true.

**Where**: `internal/transform/helpers.go`

**When**: Replacing null/empty database columns with defaults.

**Signature**: `nvl(value, defaultValue) -> any`

**Parameters**:
| Param | Type | Description |
|-------|------|-------------|
| `value` | any | Value to check |
| `defaultValue` | any | Fallback if value is null/empty |

**Returns**: `value` if non-null/non-empty, otherwise `defaultValue`.

**Example**:
```javascript
record.status = nvl(record.status, "ACTIVE");
```

---

### Function: `trim(s) -> string`

**What**: Removes leading and trailing whitespace from a string.

**Why**: Clean up padded database fields and user input.

**How**: Calls `strings.TrimSpace(s)`.

**Where**: `internal/transform/helpers.go`

**When**: Data normalization before comparison or storage.

**Signature**: `trim(s) -> string`

**Parameters**:
| Param | Type | Description |
|-------|------|-------------|
| `s` | string | Input string |

**Returns**: String with leading/trailing whitespace removed.

**Example**:
```javascript
record.code = trim(record.code);  // "  ABC  " -> "ABC"
```

---

### Function: `upper(s) -> string`

**What**: Converts a string to uppercase.

**Why**: Normalize casing for matching, display, or storage consistency.

**How**: Calls `strings.ToUpper(s)`.

**Where**: `internal/transform/helpers.go`

**When**: Case-insensitive comparisons, standardizing codes.

**Signature**: `upper(s) -> string`

**Parameters**:
| Param | Type | Description |
|-------|------|-------------|
| `s` | string | Input string |

**Returns**: Uppercase version of the input string.

**Example**:
```javascript
record.country_code = upper(record.country_code);  // "us" -> "US"
```

---

### Function: `lower(s) -> string`

**What**: Converts a string to lowercase.

**Why**: Normalize casing for email addresses, URLs, identifiers.

**How**: Calls `strings.ToLower(s)`.

**Where**: `internal/transform/helpers.go`

**When**: Standardizing email, username, or slug fields.

**Signature**: `lower(s) -> string`

**Parameters**:
| Param | Type | Description |
|-------|------|-------------|
| `s` | string | Input string |

**Returns**: Lowercase version of the input string.

**Example**:
```javascript
record.email = lower(record.email);  // "User@EXAMPLE.COM" -> "user@example.com"
```

---

### Function: `substr(s, start, length) -> string`

**What**: Extracts a Unicode-safe substring.

**Why**: Truncate or extract portions of strings, handling multi-byte characters correctly.

**How**: Converts to rune slice; supports negative `start` (from end).

**Where**: `internal/transform/helpers.go`

**When**: Fixed-width field extraction, truncating long strings.

**Signature**: `substr(s, start, length) -> string`

**Parameters**:
| Param | Type | Description |
|-------|------|-------------|
| `s` | string | Input string |
| `start` | int | Start index (0-based; negative counts from end) |
| `length` | int | Number of characters to extract |

**Returns**: Extracted substring.

**Example**:
```javascript
record.area_code = substr(record.phone, 0, 3);  // "5551234567" -> "555"
record.last3 = substr(record.code, -3, 3);       // "ABCDEF" -> "DEF"
```

---

### Function: `replace(s, old, new) -> string`

**What**: Replaces all occurrences of `old` with `new` in a string.

**Why**: Data cleansing, character substitution, format normalization.

**How**: Calls `strings.ReplaceAll(s, old, newStr)`.

**Where**: `internal/transform/helpers.go`

**When**: Removing unwanted characters, formatting fixes.

**Signature**: `replace(s, old, new) -> string`

**Parameters**:
| Param | Type | Description |
|-------|------|-------------|
| `s` | string | Input string |
| `old` | string | Substring to find |
| `new` | string | Replacement string |

**Returns**: String with all occurrences replaced.

**Example**:
```javascript
record.phone = replace(record.phone, "-", "");  // "555-123-4567" -> "5551234567"
```

---

### Function: `split(s, sep) -> string[]`

**What**: Splits a string by a separator into an array.

**Why**: Parse delimited values (CSV-in-field, tags, etc.).

**How**: Calls `strings.Split(s, sep)`.

**Where**: `internal/transform/helpers.go`

**When**: Breaking apart compound fields.

**Signature**: `split(s, sep) -> string[]`

**Parameters**:
| Param | Type | Description |
|-------|------|-------------|
| `s` | string | Input string |
| `sep` | string | Separator/delimiter |

**Returns**: Array of substrings.

**Example**:
```javascript
var tags = split(record.tags, ",");  // "a,b,c" -> ["a","b","c"]
```

---

### Function: `join(arr, sep) -> string`

**What**: Joins a string array into a single string with a separator.

**Why**: Reassemble delimited values after transformation.

**How**: Calls `strings.Join(arr, sep)`.

**Where**: `internal/transform/helpers.go`

**When**: Building composite strings from arrays.

**Signature**: `join(arr, sep) -> string`

**Parameters**:
| Param | Type | Description |
|-------|------|-------------|
| `arr` | string[] | Array of strings |
| `sep` | string | Separator to insert between elements |

**Returns**: Joined string.

**Example**:
```javascript
record.full_address = join([record.street, record.city, record.state], ", ");
```

---

### Function: `left(s, n) -> string`

**What**: Returns the leftmost `n` characters (Unicode-safe).

**Why**: Extract fixed-width prefixes from codes, identifiers.

**How**: Converts to rune slice; takes first `n` runes.

**Where**: `internal/transform/helpers.go`

**When**: Extracting prefixes, truncating to max length.

**Signature**: `left(s, n) -> string`

**Parameters**:
| Param | Type | Description |
|-------|------|-------------|
| `s` | string | Input string |
| `n` | int | Number of characters from left |

**Returns**: First `n` characters.

**Example**:
```javascript
record.prefix = left(record.product_code, 3);  // "ABC123" -> "ABC"
```

---

### Function: `right(s, n) -> string`

**What**: Returns the rightmost `n` characters (Unicode-safe).

**Why**: Extract suffixes such as last digits of an account number.

**How**: Converts to rune slice; takes last `n` runes.

**Where**: `internal/transform/helpers.go`

**When**: Extracting suffixes, last-N-digits.

**Signature**: `right(s, n) -> string`

**Parameters**:
| Param | Type | Description |
|-------|------|-------------|
| `s` | string | Input string |
| `n` | int | Number of characters from right |

**Returns**: Last `n` characters.

**Example**:
```javascript
record.last4 = right(record.account, 4);  // "123456789" -> "6789"
```

---

### Function: `length(s) -> int`

**What**: Returns the Unicode character count of a string.

**Why**: Validate field lengths, calculate padding.

**How**: Calls `utf8.RuneCountInString(s)` (not byte count).

**Where**: `internal/transform/helpers.go`

**When**: Length validation, conditional logic.

**Signature**: `length(s) -> int`

**Parameters**:
| Param | Type | Description |
|-------|------|-------------|
| `s` | string | Input string |

**Returns**: Number of Unicode characters.

**Example**:
```javascript
if (length(record.name) > 50) { record.name = left(record.name, 50); }
```

---

### Function: `padLeft(s, totalLen, padChar) -> string`

**What**: Left-pads a string to `totalLen` using `padChar`.

**Why**: Fixed-width formatting (zero-padded numbers, aligned codes).

**How**: Prepends repeated `padChar` until Unicode length equals `totalLen`.

**Where**: `internal/transform/helpers.go`

**When**: Formatting account numbers, sequence IDs.

**Signature**: `padLeft(s, totalLen, padChar) -> string`

**Parameters**:
| Param | Type | Description |
|-------|------|-------------|
| `s` | string | Input string |
| `totalLen` | int | Desired total length |
| `padChar` | string | Character to pad with |

**Returns**: Left-padded string. Returns original if already >= `totalLen`.

**Example**:
```javascript
record.id = padLeft(toString(record.id), 10, "0");  // "42" -> "0000000042"
```

---

### Function: `padRight(s, totalLen, padChar) -> string`

**What**: Right-pads a string to `totalLen` using `padChar`.

**Why**: Fixed-width formatting for right-aligned fields.

**How**: Appends repeated `padChar` until Unicode length equals `totalLen`.

**Where**: `internal/transform/helpers.go`

**When**: Fixed-width file output, column alignment.

**Signature**: `padRight(s, totalLen, padChar) -> string`

**Parameters**:
| Param | Type | Description |
|-------|------|-------------|
| `s` | string | Input string |
| `totalLen` | int | Desired total length |
| `padChar` | string | Character to pad with |

**Returns**: Right-padded string. Returns original if already >= `totalLen`.

**Example**:
```javascript
record.name = padRight(record.name, 30, " ");
```

---

### Function: `contains(s, substr) -> bool`

**What**: Checks if a string contains a substring.

**Why**: Conditional logic based on string content.

**How**: Calls `strings.Contains(s, substr)`.

**Where**: `internal/transform/helpers.go`

**When**: Filtering, conditional transformations.

**Signature**: `contains(s, substr) -> bool`

**Parameters**:
| Param | Type | Description |
|-------|------|-------------|
| `s` | string | String to search in |
| `substr` | string | Substring to find |

**Returns**: `true` if `substr` is found in `s`.

**Example**:
```javascript
if (contains(record.description, "URGENT")) { record.priority = "HIGH"; }
```

---

### Function: `startsWith(s, prefix) -> bool`

**What**: Checks if a string starts with a given prefix.

**Why**: Pattern matching on codes, identifiers, prefixed values.

**How**: Calls `strings.HasPrefix(s, prefix)`.

**Where**: `internal/transform/helpers.go`

**When**: Routing, categorization by prefix.

**Signature**: `startsWith(s, prefix) -> bool`

**Parameters**:
| Param | Type | Description |
|-------|------|-------------|
| `s` | string | String to check |
| `prefix` | string | Expected prefix |

**Returns**: `true` if `s` starts with `prefix`.

**Example**:
```javascript
if (startsWith(record.code, "INT")) { record.type = "INTERNATIONAL"; }
```

---

### Function: `endsWith(s, suffix) -> bool`

**What**: Checks if a string ends with a given suffix.

**Why**: File extension checks, suffix-based categorization.

**How**: Calls `strings.HasSuffix(s, suffix)`.

**Where**: `internal/transform/helpers.go`

**When**: Suffix-based routing or validation.

**Signature**: `endsWith(s, suffix) -> bool`

**Parameters**:
| Param | Type | Description |
|-------|------|-------------|
| `s` | string | String to check |
| `suffix` | string | Expected suffix |

**Returns**: `true` if `s` ends with `suffix`.

**Example**:
```javascript
if (endsWith(record.filename, ".csv")) { record.format = "CSV"; }
```

---

### Function: `initCap(s) -> string`

**What**: Capitalizes the first letter of each word (title case).

**Why**: Name formatting, display normalization.

**How**: Iterates runes; uppercases first letter after non-alphanumeric boundaries.

**Where**: `internal/transform/helpers_string.go`

**When**: Formatting names, titles, addresses.

**Signature**: `initCap(s) -> string`

**Parameters**:
| Param | Type | Description |
|-------|------|-------------|
| `s` | string | Input string |

**Returns**: Title-cased string.

**Example**:
```javascript
record.name = initCap(record.name);  // "john doe" -> "John Doe"
```

---

### Function: `reverseStr(s) -> string`

**What**: Reverses a string (Unicode-safe).

**Why**: Data obfuscation, palindrome checks, custom sorting.

**How**: Reverses the rune slice.

**Where**: `internal/transform/helpers_string.go`

**When**: Specialized transformations.

**Signature**: `reverseStr(s) -> string`

**Parameters**:
| Param | Type | Description |
|-------|------|-------------|
| `s` | string | Input string |

**Returns**: Reversed string.

**Example**:
```javascript
record.reversed = reverseStr("hello");  // "olleh"
```

---

### Function: `repeatStr(s, count) -> string`

**What**: Repeats a string `count` times.

**Why**: Generate padding, separator lines, repeated patterns.

**How**: Calls `strings.Repeat(s, count)`.

**Where**: `internal/transform/helpers_string.go`

**When**: Generating formatted output.

**Signature**: `repeatStr(s, count) -> string`

**Parameters**:
| Param | Type | Description |
|-------|------|-------------|
| `s` | string | String to repeat |
| `count` | int | Number of repetitions (<=0 returns empty) |

**Returns**: Repeated string.

**Example**:
```javascript
record.separator = repeatStr("-", 40);  // "----------------------------------------"
```

---

### Function: `slugify(s) -> string`

**What**: Converts a string to a URL-friendly slug.

**Why**: Generate URL slugs from titles, create filesystem-safe names.

**How**: Removes accents, lowercases, replaces non-alphanumeric with hyphens, collapses consecutive hyphens.

**Where**: `internal/transform/helpers_string.go`

**When**: URL generation, key normalization.

**Signature**: `slugify(s) -> string`

**Parameters**:
| Param | Type | Description |
|-------|------|-------------|
| `s` | string | Input string |

**Returns**: URL-safe slug.

**Example**:
```javascript
record.slug = slugify("Hello World! Cafe");  // "hello-world-cafe"
```

---

### Function: `camelCase(s) -> string`

**What**: Converts a string to camelCase.

**Why**: Normalize field names for JSON APIs or code generation.

**How**: Splits on word boundaries (spaces, underscores, camelCase transitions); lowercases first word, capitalizes subsequent.

**Where**: `internal/transform/helpers_string.go`

**When**: Field name transformation between conventions.

**Signature**: `camelCase(s) -> string`

**Parameters**:
| Param | Type | Description |
|-------|------|-------------|
| `s` | string | Input string |

**Returns**: camelCase string.

**Example**:
```javascript
record.field = camelCase("user_first_name");  // "userFirstName"
```

---

### Function: `snakeCase(s) -> string`

**What**: Converts a string to snake_case.

**Why**: Normalize field names for database columns or Python conventions.

**How**: Splits on word boundaries; joins with underscores, all lowercase.

**Where**: `internal/transform/helpers_string.go`

**When**: Field name transformation for database targets.

**Signature**: `snakeCase(s) -> string`

**Parameters**:
| Param | Type | Description |
|-------|------|-------------|
| `s` | string | Input string |

**Returns**: snake_case string.

**Example**:
```javascript
record.col = snakeCase("userFirstName");  // "user_first_name"
```

---

### Function: `removeAccents(s) -> string`

**What**: Strips diacritical marks (accents) from Unicode characters.

**Why**: Normalize international text for ASCII-only systems, search indexing.

**How**: Uses `unicode/norm.NFD` decomposition then removes `unicode.Mn` (nonspacing marks).

**Where**: `internal/transform/helpers_string.go`

**When**: Migrating to systems that do not support Unicode accents.

**Signature**: `removeAccents(s) -> string`

**Parameters**:
| Param | Type | Description |
|-------|------|-------------|
| `s` | string | Input string |

**Returns**: String with accents removed.

**Example**:
```javascript
record.name = removeAccents("cafe resume naive");  // "cafe resume naive"
```

---

## 2. Date/Time Functions

### Function: `parseDate(s, format) -> Time`

**What**: Parses a date string using a Go time layout.

**Why**: Convert string representations to date objects for arithmetic.

**How**: Calls `time.Parse(format, s)`. Uses Go layout syntax (e.g., `"2006-01-02"`).

**Where**: `internal/transform/helpers.go`

**When**: Importing dates from string-formatted sources.

**Signature**: `parseDate(s, format) -> Time`

**Parameters**:
| Param | Type | Description |
|-------|------|-------------|
| `s` | string | Date string to parse |
| `format` | string | Go time layout (e.g., `"2006-01-02"`, `"01/02/2006 15:04:05"`) |

**Returns**: Parsed time value (zero time on parse failure).

**Example**:
```javascript
var dt = parseDate("2024-03-15", "2006-01-02");
```

---

### Function: `formatDate(t, format) -> string`

**What**: Formats a time value to a string using a Go time layout.

**Why**: Convert dates to specific output formats for target systems.

**How**: Calls `t.Format(format)`.

**Where**: `internal/transform/helpers.go`

**When**: Reformatting dates during migration.

**Signature**: `formatDate(t, format) -> string`

**Parameters**:
| Param | Type | Description |
|-------|------|-------------|
| `t` | Time | Time value |
| `format` | string | Go time layout |

**Returns**: Formatted date string.

**Example**:
```javascript
record.date_str = formatDate(parseDate(record.dt, "2006-01-02"), "01/02/2006");
```

---

### Function: `now() -> Time`

**What**: Returns the current date and time.

**Why**: Stamp records with current timestamp, compute age/freshness.

**How**: Calls `time.Now()`.

**Where**: `internal/transform/helpers.go`

**When**: Adding audit timestamps, computing relative dates.

**Signature**: `now() -> Time`

**Returns**: Current time.

**Example**:
```javascript
record.processed_at = formatDate(now(), "2006-01-02T15:04:05Z07:00");
```

---

### Function: `addDays(t, days) -> Time`

**What**: Adds (or subtracts) days to a time value.

**Why**: Date arithmetic for deadlines, expiry, scheduling.

**How**: Calls `t.AddDate(0, 0, days)`.

**Where**: `internal/transform/helpers.go`

**When**: Computing future/past dates.

**Signature**: `addDays(t, days) -> Time`

**Parameters**:
| Param | Type | Description |
|-------|------|-------------|
| `t` | Time | Base time |
| `days` | int | Days to add (negative to subtract) |

**Returns**: Adjusted time.

**Example**:
```javascript
record.due_date = formatDate(addDays(parseDate(record.start, "2006-01-02"), 30), "2006-01-02");
```

---

### Function: `addMonths(t, months) -> Time`

**What**: Adds (or subtracts) months to a time value.

**Why**: Monthly billing cycles, subscription renewals.

**How**: Calls `t.AddDate(0, months, 0)`.

**Where**: `internal/transform/helpers.go`

**When**: Subscription/billing date calculations.

**Signature**: `addMonths(t, months) -> Time`

**Parameters**:
| Param | Type | Description |
|-------|------|-------------|
| `t` | Time | Base time |
| `months` | int | Months to add (negative to subtract) |

**Returns**: Adjusted time.

**Example**:
```javascript
record.renewal = addMonths(parseDate(record.signup, "2006-01-02"), 12);
```

---

### Function: `dateDiff(t1, t2) -> int`

**What**: Returns the number of days between two time values.

**Why**: Compute age, duration, SLA compliance.

**How**: Returns `int(t2.Sub(t1).Hours() / 24)`.

**Where**: `internal/transform/helpers.go`

**When**: Duration calculations on Time objects.

**Signature**: `dateDiff(t1, t2) -> int`

**Parameters**:
| Param | Type | Description |
|-------|------|-------------|
| `t1` | Time | Start time |
| `t2` | Time | End time |

**Returns**: Number of days (can be negative).

**Example**:
```javascript
record.age_days = dateDiff(parseDate(record.created, "2006-01-02"), now());
```

---

### Function: `year(t) -> int`

**What**: Extracts the year from a time value.

**Where**: `internal/transform/helpers.go`

**Signature**: `year(t) -> int`

**Example**:
```javascript
record.yr = year(parseDate(record.date, "2006-01-02"));  // 2024
```

---

### Function: `month(t) -> int`

**What**: Extracts the month (1-12) from a time value.

**Where**: `internal/transform/helpers.go`

**Signature**: `month(t) -> int`

**Example**:
```javascript
record.mo = month(parseDate(record.date, "2006-01-02"));  // 3
```

---

### Function: `day(t) -> int`

**What**: Extracts the day of month from a time value.

**Where**: `internal/transform/helpers.go`

**Signature**: `day(t) -> int`

**Example**:
```javascript
record.dy = day(parseDate(record.date, "2006-01-02"));  // 15
```

---

### Function: `hour(t) -> int`

**What**: Extracts the hour (0-23) from a time value.

**Where**: `internal/transform/helpers.go`

**Signature**: `hour(t) -> int`

---

### Function: `minute(t) -> int`

**What**: Extracts the minute (0-59) from a time value.

**Where**: `internal/transform/helpers.go`

**Signature**: `minute(t) -> int`

---

### Function: `second(t) -> int`

**What**: Extracts the second (0-59) from a time value.

**Where**: `internal/transform/helpers.go`

**Signature**: `second(t) -> int`

---

### Function: `quarter(t) -> int`

**What**: Returns the fiscal quarter (1-4) for a time value.

**How**: Computes `(month - 1) / 3 + 1`.

**Where**: `internal/transform/helpers.go`

**Signature**: `quarter(t) -> int`

**Example**:
```javascript
record.q = quarter(parseDate("2024-08-15", "2006-01-02"));  // 3
```

---

### Function: `dayOfWeek(t) -> int`

**What**: Returns the day of week (0=Sunday, 6=Saturday).

**Where**: `internal/transform/helpers.go`

**Signature**: `dayOfWeek(t) -> int`

---

### Function: `weekOfYear(t) -> int`

**What**: Returns the ISO week number (1-53).

**How**: Calls `t.ISOWeek()`.

**Where**: `internal/transform/helpers.go`

**Signature**: `weekOfYear(t) -> int`

---

### Function: `addHours(t, n) -> Time`

**What**: Adds hours to a time value.

**Where**: `internal/transform/helpers.go`

**Signature**: `addHours(t, n) -> Time`

**Parameters**:
| Param | Type | Description |
|-------|------|-------------|
| `t` | Time | Base time |
| `n` | int | Hours to add (negative to subtract) |

---

### Function: `truncateDate(t, unit) -> Time`

**What**: Truncates a time value to the specified unit boundary.

**Why**: Group data by day/month/year, strip time components.

**How**: Zeroes out components below the unit. Units: `"year"`, `"month"`, `"day"`, `"hour"`.

**Where**: `internal/transform/helpers.go`

**Signature**: `truncateDate(t, unit) -> Time`

**Parameters**:
| Param | Type | Description |
|-------|------|-------------|
| `t` | Time | Time to truncate |
| `unit` | string | `"year"`, `"month"`, `"day"`, `"hour"` |

**Example**:
```javascript
record.month_start = truncateDate(parseDate(record.date, "2006-01-02"), "month");
```

---

### Function: `dateAdd(date, amount, unit) -> string`

**What**: Adds an amount to a date *string* and returns a date string.

**Why**: Date arithmetic directly on string-formatted dates without explicit parse/format.

**How**: Auto-parses date string (supports RFC3339, `YYYY-MM-DD`, `YYYY-MM-DDTHH:MM:SS`, `MM/DD/YYYY`, `DD-Mon-YYYY`). Units: `"day"`, `"month"`, `"year"`, `"hour"`, `"minute"`.

**Where**: `internal/transform/helpers_datetime.go`

**Signature**: `dateAdd(date, amount, unit) -> string`

**Parameters**:
| Param | Type | Description |
|-------|------|-------------|
| `date` | string | Date string |
| `amount` | int | Amount to add |
| `unit` | string | `"day"`, `"month"`, `"year"`, `"hour"`, `"minute"` |

**Returns**: Result date string (format preserved).

**Example**:
```javascript
record.expiry = dateAdd("2024-03-15", 90, "day");  // "2024-06-13"
```

---

### Function: `dateDiffStr(d1, d2, unit) -> int`

**What**: Computes the difference between two date strings in the given unit.

**Why**: Duration calculations directly on string dates.

**How**: Auto-parses both dates. Units: `"day"`, `"month"`, `"year"`, `"hour"`, `"minute"`, `"second"`.

**Where**: `internal/transform/helpers_datetime.go`

**Signature**: `dateDiffStr(d1, d2, unit) -> int`

**Parameters**:
| Param | Type | Description |
|-------|------|-------------|
| `d1` | string | Start date string |
| `d2` | string | End date string |
| `unit` | string | Unit for result |

**Returns**: Difference in the specified unit.

**Example**:
```javascript
record.months_active = dateDiffStr(record.start_date, record.end_date, "month");
```

---

### Function: `dateTrunc(date, unit) -> string`

**What**: Truncates a date string to the given unit boundary.

**How**: Auto-parses; units: `"day"`, `"month"`, `"year"`.

**Where**: `internal/transform/helpers_datetime.go`

**Signature**: `dateTrunc(date, unit) -> string`

**Example**:
```javascript
record.month_start = dateTrunc("2024-03-15", "month");  // "2024-03-01"
```

---

### Function: `toTimezone(date, fromTZ, toTZ) -> string`

**What**: Converts a date string from one timezone to another.

**Why**: Timezone normalization during cross-region migration.

**How**: Parses date, interprets in `fromTZ`, converts to `toTZ` using `time.LoadLocation`.

**Where**: `internal/transform/helpers_datetime.go`

**Signature**: `toTimezone(date, fromTZ, toTZ) -> string`

**Parameters**:
| Param | Type | Description |
|-------|------|-------------|
| `date` | string | Date/time string |
| `fromTZ` | string | Source timezone (IANA name, e.g., `"America/New_York"`) |
| `toTZ` | string | Target timezone |

**Returns**: Converted date string.

**Example**:
```javascript
record.utc_date = toTimezone(record.local_date, "America/New_York", "UTC");
```

---

### Function: `extractYear(date) -> int`

**What**: Extracts the year from a date string (auto-parsed).

**Where**: `internal/transform/helpers_datetime.go`

**Signature**: `extractYear(date) -> int`

---

### Function: `extractMonth(date) -> int`

**What**: Extracts the month (1-12) from a date string (auto-parsed).

**Where**: `internal/transform/helpers_datetime.go`

**Signature**: `extractMonth(date) -> int`

---

### Function: `extractDay(date) -> int`

**What**: Extracts the day from a date string (auto-parsed).

**Where**: `internal/transform/helpers_datetime.go`

**Signature**: `extractDay(date) -> int`

---

### Function: `extractHour(date) -> int`

**What**: Extracts the hour from a date/time string (auto-parsed).

**Where**: `internal/transform/helpers_datetime.go`

**Signature**: `extractHour(date) -> int`

---

### Function: `daysBetween(d1, d2) -> int`

**What**: Returns the absolute number of days between two date strings.

**How**: Auto-parses both dates; returns `abs(t2 - t1)` in days.

**Where**: `internal/transform/helpers_datetime.go`

**Signature**: `daysBetween(d1, d2) -> int`

**Example**:
```javascript
record.days = daysBetween("2024-01-01", "2024-03-15");  // 74
```

---

### Function: `monthsBetween(d1, d2) -> int`

**What**: Returns the absolute number of months between two date strings.

**Where**: `internal/transform/helpers_datetime.go`

**Signature**: `monthsBetween(d1, d2) -> int`

**Example**:
```javascript
record.months = monthsBetween("2024-01-15", "2024-06-20");  // 5
```

---

## 3. Math Functions

### Function: `round(x) -> float`

**What**: Rounds to the nearest integer (as float64).

**How**: Calls `math.Round(x)`.

**Where**: `internal/transform/helpers.go`

**Signature**: `round(x) -> float`

**Example**:
```javascript
record.amount = round(record.amount);  // 3.7 -> 4
```

---

### Function: `roundTo(x, places) -> float`

**What**: Rounds a number to the specified decimal places.

**How**: Multiplies by `10^places`, rounds, divides back.

**Where**: `internal/transform/helpers.go`

**Signature**: `roundTo(x, places) -> float`

**Parameters**:
| Param | Type | Description |
|-------|------|-------------|
| `x` | float | Number to round |
| `places` | int | Number of decimal places |

**Example**:
```javascript
record.price = roundTo(record.price, 2);  // 3.14159 -> 3.14
```

---

### Function: `floor(x) -> float`

**What**: Rounds down to the nearest integer.

**Where**: `internal/transform/helpers.go`

**Example**: `floor(3.9)` returns `3`.

---

### Function: `ceil(x) -> float`

**What**: Rounds up to the nearest integer.

**Where**: `internal/transform/helpers.go`

**Example**: `ceil(3.1)` returns `4`.

---

### Function: `abs(x) -> float`

**What**: Returns the absolute value.

**Where**: `internal/transform/helpers.go`

**Example**: `abs(-5.3)` returns `5.3`.

---

### Function: `min(a, b) -> float`

**What**: Returns the smaller of two numbers.

**Where**: `internal/transform/helpers.go`

**Example**: `min(3, 7)` returns `3`.

---

### Function: `max(a, b) -> float`

**What**: Returns the larger of two numbers.

**Where**: `internal/transform/helpers.go`

**Example**: `max(3, 7)` returns `7`.

---

### Function: `pow(x, y) -> float`

**What**: Returns x raised to the power y.

**Where**: `internal/transform/helpers.go`

**Example**: `pow(2, 10)` returns `1024`.

---

### Function: `sqrt(x) -> float`

**What**: Returns the square root.

**Where**: `internal/transform/helpers.go`

**Example**: `sqrt(144)` returns `12`.

---

### Function: `random() -> float`

**What**: Returns a random float in `[0.0, 1.0)`.

**Where**: `internal/transform/helpers.go`

---

### Function: `randomInt(min, max) -> int`

**What**: Returns a random integer in `[min, max]` (inclusive).

**Where**: `internal/transform/helpers.go`

**Example**: `randomInt(1, 100)` returns a value between 1 and 100.

---

### Function: `clamp(value, min, max) -> float`

**What**: Restricts a value to be within `[min, max]`.

**Where**: `internal/transform/helpers_misc.go`

**Example**: `clamp(150, 0, 100)` returns `100`.

---

### Function: `mod(a, b) -> float`

**What**: Returns the floating-point remainder of `a / b`.

**How**: Calls `math.Mod(a, b)`. Returns `0` if `b` is 0.

**Where**: `internal/transform/helpers_misc.go`

**Example**: `mod(10, 3)` returns `1`.

---

### Function: `percentage(value, total) -> float`

**What**: Calculates `(value / total) * 100`.

**How**: Returns `0` if total is 0.

**Where**: `internal/transform/helpers_misc.go`

**Example**: `percentage(25, 200)` returns `12.5`.

---

## 4. Hash/UUID Functions

### Function: `hash(s) -> string`

**What**: Computes a SHA-256 hash of the input string.

**Why**: Deterministic record fingerprinting, deduplication keys.

**How**: Returns hex-encoded SHA-256 digest.

**Where**: `internal/transform/helpers.go`

**Signature**: `hash(s) -> string`

**Example**:
```javascript
record.fingerprint = hash(record.email + record.name);
```

---

### Function: `md5(s) -> string`

**What**: Computes an MD5 hash (deprecated).

**Why**: Backward compatibility with legacy systems. Use `sha256` for new work.

**How**: Returns hex-encoded MD5 digest. Logs a one-time deprecation warning.

**Where**: `internal/transform/helpers.go`

**Signature**: `md5(s) -> string`

---

### Function: `sha256(s) -> string`

**What**: Computes a SHA-256 hash.

**Why**: Secure hashing for checksums, fingerprinting.

**How**: Returns hex-encoded SHA-256 digest.

**Where**: `internal/transform/helpers.go`

**Signature**: `sha256(s) -> string`

---

### Function: `uuid() -> string`

**What**: Generates a new UUID v4.

**Why**: Create unique identifiers for new records.

**How**: Calls `uuid.New().String()`.

**Where**: `internal/transform/helpers.go`

**Signature**: `uuid() -> string`

**Example**:
```javascript
record.id = uuid();  // "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
```

---

## 5. Type Conversion Functions

### Function: `toInt(v) -> int`

**What**: Converts any value to int.

**How**: Handles int, int64, float64, string. Returns 0 on failure.

**Where**: `internal/transform/helpers.go`

**Example**: `toInt("42")` returns `42`.

---

### Function: `toFloat(v) -> float`

**What**: Converts any value to float64.

**How**: Handles float64, int, int64, string. Returns 0 on failure.

**Where**: `internal/transform/helpers.go`

**Example**: `toFloat("3.14")` returns `3.14`.

---

### Function: `toString(v) -> string`

**What**: Converts any value to string.

**How**: Returns `""` for nil, `fmt.Sprintf("%v", v)` otherwise.

**Where**: `internal/transform/helpers.go`

**Example**: `toString(42)` returns `"42"`.

---

### Function: `toBool(v) -> bool`

**What**: Converts a value to boolean.

**How**: Handles bool, string (`"true"`/`"1"`), int/float (non-zero = true).

**Where**: `internal/transform/helpers.go`

**Example**: `toBool("true")` returns `true`.

---

### Function: `isNull(v) -> bool`

**What**: Returns true if value is nil/null.

**Where**: `internal/transform/helpers.go`

**Example**: `isNull(null)` returns `true`.

---

### Function: `isBlank(v) -> bool`

**What**: Returns true if value is nil or a whitespace-only string.

**Where**: `internal/transform/helpers.go`

**Example**: `isBlank("  ")` returns `true`.

---

### Function: `toBigInt(v) -> int64`

**What**: Converts any value to int64 with extended type support.

**How**: Handles int, int32, int64, float32, float64, string (parses int then float), bool.

**Where**: `internal/transform/helpers_type.go`

**Example**: `toBigInt("9999999999")` returns `9999999999`.

---

### Function: `toFloatExt(v) -> float64`

**What**: Converts any value to float64 with extended type support (includes float32, int32, bool).

**Where**: `internal/transform/helpers_type.go`

---

### Function: `toDecimal(v, scale) -> string`

**What**: Converts a value to a fixed-precision decimal string.

**Why**: Format numbers with exact decimal places for financial systems.

**How**: Converts to float, then `strconv.FormatFloat(f, 'f', scale, 64)`.

**Where**: `internal/transform/helpers_type.go`

**Signature**: `toDecimal(v, scale) -> string`

**Parameters**:
| Param | Type | Description |
|-------|------|-------------|
| `v` | any | Numeric value |
| `scale` | int | Number of decimal places |

**Example**:
```javascript
record.amount = toDecimal(record.amount, 2);  // 3.1 -> "3.10"
```

---

### Function: `toBoolean(v) -> bool`

**What**: Extended boolean conversion handling `"yes"`, `"no"`, `"y"`, `"n"`, `"on"`.

**How**: Extends `toBool` with additional string values.

**Where**: `internal/transform/helpers_type.go`

**Example**: `toBoolean("yes")` returns `true`.

---

### Function: `toTimestamp(v, layout) -> int64`

**What**: Parses a date string and returns Unix timestamp in seconds.

**Where**: `internal/transform/helpers_type.go`

**Signature**: `toTimestamp(v, layout) -> int64`

**Example**:
```javascript
record.ts = toTimestamp("2024-03-15", "2006-01-02");  // 1710460800
```

---

### Function: `autoType(v) -> any`

**What**: Auto-detects and converts a string to its most likely native type.

**Why**: Automatically type untyped CSV/text input.

**How**: Tries in order: int64, float64, bool (`"true"`/`"false"`), date (RFC3339, `YYYY-MM-DD`); returns original string if none match.

**Where**: `internal/transform/helpers_type.go`

**Example**:
```javascript
record.value = autoType("42");      // int64(42)
record.value = autoType("3.14");    // float64(3.14)
record.value = autoType("true");    // bool(true)
record.value = autoType("hello");   // "hello"
```

---

## 6. Validation Functions

> **Note**: Requires license feature `feature.validation`.

### Function: `isEmail(s) -> bool`

**What**: Validates email format (simplified RFC 5322).

**Where**: `internal/transform/helpers_validate.go`

**Example**: `isEmail("user@example.com")` returns `true`.

---

### Function: `isPhone(s) -> bool`

**What**: Validates phone number format (7-15 digits, international formats accepted).

**Where**: `internal/transform/helpers_validate.go`

**Example**: `isPhone("+1 (555) 123-4567")` returns `true`.

---

### Function: `isURL(s) -> bool`

**What**: Validates URL format (requires scheme and host).

**Where**: `internal/transform/helpers_validate.go`

**Example**: `isURL("https://example.com")` returns `true`.

---

### Function: `isIP(s) -> bool`

**What**: Validates IPv4 or IPv6 address.

**How**: Uses `net.ParseIP(s)`.

**Where**: `internal/transform/helpers_validate.go`

**Example**: `isIP("192.168.1.1")` returns `true`.

---

### Function: `isUUID(s) -> bool`

**What**: Validates UUID format (v1-v5, 8-4-4-4-12 hex).

**Where**: `internal/transform/helpers_validate.go`

**Example**: `isUUID("550e8400-e29b-41d4-a716-446655440000")` returns `true`.

---

### Function: `isNumeric(s) -> bool`

**What**: Checks if a string represents a numeric value (int or float).

**How**: Attempts `strconv.ParseFloat`.

**Where**: `internal/transform/helpers_validate.go`

**Example**: `isNumeric("3.14")` returns `true`.

---

### Function: `inRange(v, min, max) -> bool`

**What**: Checks if a numeric value is between min and max (inclusive).

**How**: Converts all three to float64, checks `val >= lo && val <= hi`.

**Where**: `internal/transform/helpers_validate.go`

**Signature**: `inRange(v, min, max) -> bool`

**Example**:
```javascript
if (!inRange(record.age, 0, 150)) { record._invalid = true; }
```

---

## 7. Masking Functions

> **Note**: Requires license feature `feature.masking`.

### Function: `maskSSN(s) -> string`

**What**: Masks a Social Security Number, showing only last 4 digits.

**Where**: `internal/transform/helpers_mask.go`

**Example**: `maskSSN("123-45-6789")` returns `"***-**-6789"`.

---

### Function: `maskEmail(s) -> string`

**What**: Masks an email, showing first character and full domain.

**Where**: `internal/transform/helpers_mask.go`

**Example**: `maskEmail("user@example.com")` returns `"u***@example.com"`.

---

### Function: `maskPhone(s) -> string`

**What**: Masks a phone number, showing only last 4 digits.

**Where**: `internal/transform/helpers_mask.go`

**Example**: `maskPhone("555-123-4567")` returns `"******4567"`.

---

### Function: `maskCard(s) -> string`

**What**: Masks a credit card number, showing only last 4 digits.

**Where**: `internal/transform/helpers_mask.go`

**Example**: `maskCard("4111111111111111")` returns `"************1111"`.

---

### Function: `redact(s) -> string`

**What**: Replaces entire string with `"[REDACTED]"`.

**Where**: `internal/transform/helpers_mask.go`

**Example**: `redact("sensitive data")` returns `"[REDACTED]"`.

---

### Function: `tokenize(s) -> string`

**What**: Produces a deterministic 32-character hex token from a string.

**Why**: Pseudonymization -- same input always produces the same token.

**How**: SHA-256 hash truncated to 16 bytes (32 hex chars).

**Where**: `internal/transform/helpers_mask.go`

**Example**:
```javascript
record.email_token = tokenize(record.email);  // deterministic hex string
```

---

## 8. Array Functions

### Function: `arrayContains(arr, item) -> bool`

**What**: Checks if an array contains a value.

**Where**: `internal/transform/helpers.go`

**Signature**: `arrayContains(arr, item) -> bool`

**Example**:
```javascript
if (arrayContains(record.tags, "premium")) { record.tier = "gold"; }
```

---

### Function: `arrayIndexOf(arr, item) -> int`

**What**: Returns the index of an item in an array, or -1 if not found.

**Where**: `internal/transform/helpers.go`

---

### Function: `arrayJoin(arr, sep) -> string`

**What**: Joins an array of any type into a string (converts each element via `fmt.Sprintf`).

**Where**: `internal/transform/helpers.go`

**Example**: `arrayJoin([1, 2, 3], ",")` returns `"1,2,3"`.

---

### Function: `arrayPush(arr, item) -> array`

**What**: Appends an item to an array and returns the new array.

**Where**: `internal/transform/helpers.go`

---

### Function: `unique(arr) -> array`

**What**: Removes duplicate values from an array (O(n) deduplication).

**Where**: `internal/transform/helpers.go`

**Example**: `unique([1, 2, 2, 3])` returns `[1, 2, 3]`.

---

### Function: `filter(arr, predicate) -> array`

**What**: Filters an array using a JavaScript predicate expression.

**Why**: Inline array filtering with arrow function syntax.

**How**: Compiles the predicate string as JS, evaluates for each element.

**Where**: `internal/transform/helpers.go` (ArrayFilter), registered with wrapper in `engine.go`

**Signature**: `filter(arr, predicate) -> array`

**Parameters**:
| Param | Type | Description |
|-------|------|-------------|
| `arr` | array | Input array |
| `predicate` | string | JS arrow function string, e.g., `"x => x.active"` |

**Example**:
```javascript
var active = filter(records, "x => x.status == 'ACTIVE'");
```

---

### Function: `map(arr, mapper) -> array`

**What**: Transforms each element of an array using a JS mapper expression.

**Where**: `internal/transform/helpers.go` (ArrayMap)

**Signature**: `map(arr, mapper) -> array`

**Parameters**:
| Param | Type | Description |
|-------|------|-------------|
| `arr` | array | Input array |
| `mapper` | string | JS arrow function string, e.g., `"x => x.name"` |

**Example**:
```javascript
var names = map(records, "x => x.name");
```

---

### Function: `sort(arr, comparator) -> array`

**What**: Sorts an array using a JS comparator expression.

**Where**: `internal/transform/helpers.go` (ArraySort)

**Signature**: `sort(arr, comparator) -> array`

**Parameters**:
| Param | Type | Description |
|-------|------|-------------|
| `arr` | array | Input array |
| `comparator` | string | JS comparator, e.g., `"(a, b) => a.age - b.age"` |

**Example**:
```javascript
var sorted = sort(records, "(a, b) => a.amount - b.amount");
```

---

### Function: `flatMap(arr, mapper) -> array`

**What**: Maps each element to an array and flattens the result (one level).

**Where**: `internal/transform/helpers.go` (ArrayFlatMap)

**Example**:
```javascript
var allItems = flatMap(orders, "x => x.items");
```

---

### Function: `arraySum(arr) -> float`

**What**: Computes the sum of numeric values in an array.

**How**: Converts each element via `ToFloat`, sums.

**Where**: `internal/transform/helpers.go`

**Example**: `arraySum([1, 2, 3])` returns `6`.

---

### Function: `arrayAvg(arr) -> float`

**What**: Computes the average of numeric values in an array.

**Where**: `internal/transform/helpers.go`

**Example**: `arrayAvg([10, 20, 30])` returns `20`.

---

### Function: `arrayCount(arr) -> int`

**What**: Counts non-null elements in an array.

**Where**: `internal/transform/helpers.go`

---

### Function: `arrayMin(arr) -> float`

**What**: Finds the minimum numeric value in an array.

**Where**: `internal/transform/helpers.go`

---

### Function: `arrayMax(arr) -> float`

**What**: Finds the maximum numeric value in an array.

**Where**: `internal/transform/helpers.go`

---

### Function: `in(value, arr) -> bool`

**What**: Checks if a value exists in an array (natural syntax alias for `arrayContains`).

**Why**: SQL-style `IN` operator for cleaner scripts.

**Where**: Registered inline in `engine.go`

**Example**:
```javascript
if (in(record.status, ["ACTIVE", "PENDING"])) { /* ... */ }
```

---

## 9. Regex Functions

### Function: `regexTest(pattern, text) -> bool`

**What**: Tests if a regex pattern matches anywhere in the text.

**Where**: `internal/transform/helpers.go`

**Example**: `regexTest("^\\d{3}", "123ABC")` returns `true`.

---

### Function: `regexMatch(pattern, text) -> string[]`

**What**: Returns all non-overlapping matches of a pattern.

**Where**: `internal/transform/helpers.go`

**Example**: `regexMatch("\\d+", "abc123def456")` returns `["123", "456"]`.

---

### Function: `regexReplace(pattern, text, replacement) -> string`

**What**: Replaces all regex matches with a replacement string.

**Where**: `internal/transform/helpers.go`

**Example**: `regexReplace("\\s+", "a  b  c", " ")` returns `"a b c"`.

---

### Function: `regexSplit(pattern, text) -> string[]`

**What**: Splits text by a regex pattern.

**Where**: `internal/transform/helpers.go`

**Example**: `regexSplit("[,;]", "a,b;c")` returns `["a", "b", "c"]`.

---

### Function: `regexCapture(pattern, text, group) -> string`

**What**: Returns a specific capture group from the first match.

**Where**: `internal/transform/helpers.go`

**Signature**: `regexCapture(pattern, text, group) -> string`

**Parameters**:
| Param | Type | Description |
|-------|------|-------------|
| `pattern` | string | Regex with capture groups |
| `text` | string | Input text |
| `group` | int | Group index (0 = full match, 1 = first group) |

**Example**:
```javascript
var area = regexCapture("\\((\\d{3})\\)", "(555) 123-4567", 1);  // "555"
```

---

## 10. JSON Functions

### Function: `jsonParse(text) -> any`

**What**: Parses a JSON string into a JavaScript object/array.

**Where**: `internal/transform/helpers.go`

**Example**:
```javascript
var obj = jsonParse('{"name":"Alice"}');  // {name: "Alice"}
```

---

### Function: `jsonStringify(obj) -> string`

**What**: Serializes an object to a compact JSON string.

**Where**: `internal/transform/helpers.go`

---

### Function: `jsonStringifyPretty(obj) -> string`

**What**: Serializes an object to pretty-printed JSON with 2-space indentation.

**Where**: `internal/transform/helpers.go`

---

### Function: `jsonExtract(obj, path) -> any`

**What**: Extracts a value from a parsed JSON object using dot-path notation.

**How**: Navigates maps and arrays. Array indices are numeric path segments.

**Where**: `internal/transform/helpers.go`

**Signature**: `jsonExtract(obj, path) -> any`

**Example**:
```javascript
var name = jsonExtract(obj, "user.name");
var first = jsonExtract(obj, "users.0.name");
```

---

### Function: `jsonSet(jsonStr, path, value) -> string`

**What**: Sets a value in a JSON string at the given dot-notation path.

**Why**: Modify nested JSON without full parse/modify/serialize cycle in user code.

**How**: Parses JSON, navigates/creates path, sets value, re-serializes.

**Where**: `internal/transform/helpers.go`

**Signature**: `jsonSet(jsonStr, path, value) -> string`

**Example**:
```javascript
record.data = jsonSet(record.data, "user.name", "Bob");
```

---

### Function: `batchToJson(records, fields) -> string`

**What**: Converts an array of record maps to a JSON array string, optionally selecting specific fields.

**Where**: `internal/transform/json_encapsulation.go`

**Signature**: `batchToJson(records, fields) -> string`

**Parameters**:
| Param | Type | Description |
|-------|------|-------------|
| `records` | map[] | Array of record maps |
| `fields` | string[] | Fields to include (null/empty = all fields) |

---

### Function: `batchToJsonPretty(records, fields) -> string`

**What**: Same as `batchToJson` but with 2-space indented output.

**Where**: `internal/transform/json_encapsulation.go`

---

### Function: `jsonMerge(...jsonStrs) -> string`

**What**: Merges multiple JSON object strings into one. Later keys override earlier.

**Where**: `internal/transform/json_encapsulation.go`

**Example**:
```javascript
var merged = jsonMerge('{"a":1}', '{"b":2}');  // '{"a":1,"b":2}'
```

---

### Function: `jsonArrayToTable(jsonArray) -> map[]`

**What**: Parses a JSON array string and flattens nested objects using dot notation.

**Where**: `internal/transform/json_encapsulation.go`

---

### Function: `jsonTemplate(template, record) -> string`

**What**: Applies a JSON template with `{{field}}` placeholders to a record.

**Where**: `internal/transform/json_encapsulation.go`

**Example**:
```javascript
var result = jsonTemplate('{"name": {{name}}, "id": {{id}}}', record);
```

---

### Function: `jsonBatchTemplate(template, records) -> string`

**What**: Applies a JSON template to a batch. Supports `{{records}}` and `{{count}}` placeholders.

**Where**: `internal/transform/json_encapsulation.go`

---

### Function: `jsonSelectFields(jsonStr, fields) -> string`

**What**: Returns a JSON string containing only the specified fields.

**Where**: `internal/transform/json_encapsulation.go`

**Example**:
```javascript
var subset = jsonSelectFields(record.data, ["name", "email"]);
```

---

### Function: `jsonRenameFields(jsonStr, fieldMap) -> string`

**What**: Renames fields in a JSON string based on a mapping.

**Where**: `internal/transform/json_encapsulation.go`

**Signature**: `jsonRenameFields(jsonStr, fieldMap) -> string`

**Parameters**:
| Param | Type | Description |
|-------|------|-------------|
| `jsonStr` | string | Input JSON |
| `fieldMap` | object | `{oldName: newName, ...}` |

**Example**:
```javascript
var renamed = jsonRenameFields(data, {"first_name": "firstName", "last_name": "lastName"});
```

---

## 11. XML Functions

### Function: `XMLParse(xmlStr) -> map`

**What**: Parses an XML string into a JavaScript map. Root element is stripped.

**Where**: `internal/transform/xml_encapsulation.go`

**Example**:
```javascript
var obj = XMLParse("<root><name>Alice</name></root>");  // {name: "Alice"}
```

---

### Function: `XMLStringify(rootElement, record) -> string`

**What**: Converts a record map to an XML string with the given root element.

**Where**: `internal/transform/xml_encapsulation.go`

**Example**:
```javascript
var xml = XMLStringify("person", {name: "Alice", age: 30});
// "<person><name>Alice</name><age>30</age></person>"
```

---

### Function: `XMLStringifyPretty(rootElement, record) -> string`

**What**: Same as `XMLStringify` but with indented output.

**Where**: `internal/transform/xml_encapsulation.go`

---

### Function: `XMLStringifyBatch(rootElement, itemElement, records) -> string`

**What**: Converts an array of records to an XML document with root and item elements.

**Where**: `internal/transform/xml_encapsulation.go`

**Signature**: `XMLStringifyBatch(rootElement, itemElement, records) -> string`

---

### Function: `XMLExtract(xmlStr, path) -> any`

**What**: Extracts a value from XML using dot-notation path.

**How**: Parses XML to map, then navigates path. Skips root element name if not found.

**Where**: `internal/transform/xml_encapsulation.go`

**Example**:
```javascript
var name = XMLExtract("<root><user><name>Alice</name></user></root>", "user.name");
```

---

### Function: `XMLExtractAttributes(xmlStr, elementName) -> map`

**What**: Extracts all attributes (prefixed with `@`) from parsed XML.

**Where**: `internal/transform/xml_encapsulation.go`

---

### Function: `XMLBuild(name, attrs, content) -> string`

**What**: Builds an XML element with attributes and content.

**Where**: `internal/transform/xml_encapsulation.go`

**Signature**: `XMLBuild(name, attrs, content) -> string`

**Parameters**:
| Param | Type | Description |
|-------|------|-------------|
| `name` | string | Element name |
| `attrs` | map | Attributes `{key: value}` (null for none) |
| `content` | any | String content, nested map, or null for self-closing |

**Example**:
```javascript
var el = XMLBuild("item", {"id": "1"}, "Hello");  // '<item id="1">Hello</item>'
```

---

### Function: `XMLWithCDATA(content) -> string`

**What**: Wraps content in a CDATA section.

**Where**: `internal/transform/xml_encapsulation.go`

**Example**: `XMLWithCDATA("some <data>")` returns `"<![CDATA[some <data>]]>"`.

---

### Function: `XMLToJSON(xmlStr) -> string`

**What**: Converts XML to a JSON string.

**How**: Parses XML to map, then serializes to JSON.

**Where**: `internal/transform/xml_encapsulation.go`

---

### Function: `JSONToXML(jsonStr, rootElement) -> string`

**What**: Converts a JSON string to XML with the given root element.

**Where**: `internal/transform/xml_encapsulation.go`

---

### Function: `XMLTemplate(template, record) -> string`

**What**: Applies an XML template with `{{field}}` placeholders (XML-escaped values).

**Where**: `internal/transform/xml_encapsulation.go`

---

### Function: `XMLSelectFields(xmlStr, rootElement, fields) -> string`

**What**: Returns XML containing only the specified fields.

**Where**: `internal/transform/xml_encapsulation.go`

---

## 12. Encoding Functions

### Function: `base64Encode(text) -> string`

**What**: Encodes a string to Base64 (standard encoding).

**Where**: `internal/transform/helpers.go`

**Example**: `base64Encode("hello")` returns `"aGVsbG8="`.

---

### Function: `base64Decode(text) -> string`

**What**: Decodes a Base64 string. Returns empty string on error.

**Where**: `internal/transform/helpers.go`

---

### Function: `urlEncode(text) -> string`

**What**: URL-encodes a string (query-escape).

**Where**: `internal/transform/helpers.go`

**Example**: `urlEncode("hello world")` returns `"hello+world"`.

---

### Function: `urlDecode(text) -> string`

**What**: URL-decodes a string. Returns original on error.

**Where**: `internal/transform/helpers.go`

---

### Function: `htmlEscape(text) -> string`

**What**: Escapes HTML special characters (`<`, `>`, `&`, `"`, `'`).

**Where**: `internal/transform/helpers.go`

**Example**: `htmlEscape("<b>hi</b>")` returns `"&lt;b&gt;hi&lt;/b&gt;"`.

---

### Function: `htmlUnescape(text) -> string`

**What**: Unescapes HTML entities back to characters.

**Where**: `internal/transform/helpers.go`

---

## 13. Statistics Functions

### Function: `percentile(arr, p) -> float`

**What**: Computes the p-th percentile (0-100) of a numeric array using linear interpolation.

**Where**: `internal/transform/helpers.go`

**Signature**: `percentile(arr, p) -> float`

**Parameters**:
| Param | Type | Description |
|-------|------|-------------|
| `arr` | float[] | Numeric array |
| `p` | float | Percentile (0-100) |

**Example**:
```javascript
var p95 = percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 95);  // 9.55
```

---

### Function: `median(arr) -> float`

**What**: Computes the median (50th percentile) of a numeric array.

**Where**: `internal/transform/helpers.go`

---

### Function: `stddev(arr) -> float`

**What**: Computes the population standard deviation.

**How**: `sqrt(variance(arr))`.

**Where**: `internal/transform/helpers.go`

---

### Function: `variance(arr) -> float`

**What**: Computes the population variance using Welford's online algorithm (numerically stable).

**Where**: `internal/transform/helpers.go`

---

## 14. Cross-Record Functions

### Function: `filterRecords(records, filter) -> array`

**What**: Filters an array of records by field=value conditions (all must match).

**Where**: `internal/transform/helpers_cross_record.go`

**Signature**: `filterRecords(records, filter) -> array`

**Parameters**:
| Param | Type | Description |
|-------|------|-------------|
| `records` | array | Array of record maps |
| `filter` | object | `{field: value, ...}` -- all must match |

**Example**:
```javascript
var headers = filterRecords(records, {Code: "HEADER"});
```

---

### Function: `parseFilter(expr) -> map`

**What**: Parses a string filter expression into a filter map.

**How**: Supports `"Code='TOTAL'"` and `"Code='A' AND Value='X'"` syntax.

**Where**: `internal/transform/helpers_cross_record.go`

**Example**:
```javascript
var f = parseFilter("Code='TOTAL' AND Type='SUM'");  // {Code: "TOTAL", Type: "SUM"}
```

---

### Function: `crossEquals(records, filter1, filter2, field) -> bool`

**What**: Checks if a field value matches between two filtered record groups.

**Where**: `internal/transform/helpers_cross_record.go`

**Example**:
```javascript
var ok = crossEquals(records, {Code: "A"}, {Code: "B"}, "Amount");
```

---

### Function: `crossUnique(records, filter, field) -> bool`

**What**: Checks if all values for a field are unique among filtered records.

**Where**: `internal/transform/helpers_cross_record.go`

---

### Function: `crossDepends(records, ifFilter, thenFilter) -> bool`

**What**: Checks: IF any records match `ifFilter`, THEN at least one must match `thenFilter`.

**Where**: `internal/transform/helpers_cross_record.go`

**Example**:
```javascript
var ok = crossDepends(records, {Type: "HEADER"}, {Type: "DETAIL"});
```

---

### Function: `crossSumLimit(records, filter, field, operator, limit) -> bool`

**What**: Sums a numeric field across filtered records and checks against a limit.

**Where**: `internal/transform/helpers_cross_record.go`

**Signature**: `crossSumLimit(records, filter, field, operator, limit) -> bool`

**Parameters**:
| Param | Type | Description |
|-------|------|-------------|
| `records` | array | All records |
| `filter` | object | Filter to select records |
| `field` | string | Numeric field to sum |
| `operator` | string | `"<"`, `"<="`, `">"`, `">="`, `"=="` |
| `limit` | float | Threshold value |

---

### Function: `crossCountRange(records, filter, min, max) -> bool`

**What**: Checks that the count of filtered records is within [min, max].

**Where**: `internal/transform/helpers_cross_record.go`

---

### Function: `markFail(records, filter, detail)`

**What**: Sets `_cross_record_fail=true` and appends to `check_detail` on matching records.

**Why**: Mark records that fail cross-record validation with a reason.

**Where**: `internal/transform/helpers_cross_record.go`

---

### Function: `findRecord(records, filter) -> map|null`

**What**: Returns the first record matching the filter, or null.

**Where**: `internal/transform/helpers_cross_record.go`

---

### Function: `lookupValue(records, filter, field, defaultVal) -> any`

**What**: Finds the first matching record and returns a specific field, or a default.

**Where**: `internal/transform/helpers_cross_record.go`

**Example**:
```javascript
var total = lookupValue(records, {Code: "TOTAL"}, "Amount", 0);
```

---

### Function: `joinRecords(left, right, leftKeys, rightKeys) -> array`

**What**: In-memory inner join of two record arrays by key field(s).

**How**: Builds hash index on right side. Keys can be a string or string array (composite key).

**Where**: `internal/transform/helpers_cross_record.go`

**Example**:
```javascript
var joined = joinRecords(orders, customers, "customer_id", "id");
```

---

### Function: `leftJoinRecords(left, right, leftKeys, rightKeys) -> array`

**What**: Left outer join. Unmatched left records are included without right fields.

**Where**: `internal/transform/helpers_cross_record.go`

---

### Function: `correlate(records, field1, field2) -> bool`

**What**: Checks if values in `field1` consistently map 1:1 to `field2` values.

**Why**: Validate referential consistency across records.

**Where**: `internal/transform/helpers_cross_record.go`

**Example**:
```javascript
var consistent = correlate(records, "dept_code", "dept_name");  // true if 1:1
```

---

### Function: `pivot(records, keyFields, valueField) -> map`

**What**: Transforms rows into columns -- each unique key becomes a map key with the corresponding value.

**Where**: `internal/transform/helpers_cross_record.go`

**Example**:
```javascript
var p = pivot(records, "Code", "Amount");
// [{Code:"A", Amount:100}, {Code:"B", Amount:200}] -> {A: 100, B: 200}
```

---

### Function: `unpivot(record, columns, idFields) -> array`

**What**: Transforms columns into rows. Each specified column becomes a `{column, value}` row.

**Where**: `internal/transform/helpers_cross_record.go`

**Signature**: `unpivot(record, columns, idFields) -> array`

**Parameters**:
| Param | Type | Description |
|-------|------|-------------|
| `record` | map | Input record |
| `columns` | string[] | Column names to unpivot |
| `idFields` | string[] | Fields to carry into each output row |

**Example**:
```javascript
var rows = unpivot({id: 1, jan: 10, feb: 20}, ["jan", "feb"], ["id"]);
// [{id:1, column:"jan", value:10}, {id:1, column:"feb", value:20}]
```

---

### Function: `deltaValue(records, field, orderBy) -> array`

**What**: Sorts records by `orderBy` then computes the difference between consecutive values of `field`, adding a `delta` field to each record.

**Where**: `internal/transform/helpers_cross_record.go`

---

### Function: `matchPairs(records, filter1, filter2, matchField) -> array`

**What**: Finds matching pairs between two filtered groups by a match field.

**Why**: Reconciliation -- match header/detail or debit/credit records.

**How**: Indexes group2 by matchField, then finds corresponding entries from group1.

**Where**: `internal/transform/helpers_cross_record.go`

**Returns**: `[{left: record, right: record, match_value: "X"}, ...]`

---

### Function: `crossDependsAdvanced(records, ifCond, thenCond) -> bool`

**What**: Advanced dependency check with structured AND/OR/NOT condition trees.

**Why**: Complex cross-record validation rules beyond simple field=value.

**How**: Conditions are nested objects: `{and: [...]}, {or: [...]}, {not: ...}, {field, op, value}`.

**Where**: `internal/transform/helpers_cross_record.go`

**Supported operators**: `eq`, `ne`, `gt`, `gte`, `lt`, `lte`, `in`, `not_in`, `is_null`, `is_not_null`, `starts_with`, `ends_with`, `contains`, `regex`.

**Example**:
```javascript
var ok = crossDependsAdvanced(records,
    {and: [{field: "Type", op: "eq", value: "HEADER"}, {field: "Status", op: "ne", value: "DELETED"}]},
    {field: "Type", op: "eq", value: "DETAIL"}
);
```

---

### Function: `filterByCondition(records, cond) -> array`

**What**: Filters records using a structured condition tree (same format as `crossDependsAdvanced`).

**Where**: `internal/transform/helpers_cross_record.go`

---

### Function: `evalCondition(record, cond) -> bool`

**What**: Evaluates a structured condition tree against a single record.

**Where**: `internal/transform/helpers_cross_record.go`

---

## 15. Window Functions

### Function: `firstValue(records, column) -> any`

**What**: Returns the value of the specified column from the first record in an array.

**Where**: `internal/transform/helpers_window.go`

**Example**:
```javascript
var first = firstValue(records, "amount");
```

---

### Function: `lastValue(records, column) -> any`

**What**: Returns the value of the specified column from the last record in an array.

**Where**: `internal/transform/helpers_window.go`

---

### Function: `nthValue(records, column, n) -> any`

**What**: Returns the value of the specified column from the nth record (1-indexed).

**Where**: `internal/transform/helpers_window.go`

**Signature**: `nthValue(records, column, n) -> any`

**Example**:
```javascript
var second = nthValue(records, "amount", 2);
```

---

## 16. Misc/SQL-Like Functions

### Function: `nvl2(value, ifNotNull, ifNull) -> any`

**What**: Returns `ifNotNull` when value is non-null/non-empty, otherwise `ifNull`.

**Why**: Oracle NVL2 equivalent -- conditional branching on null.

**Where**: `internal/transform/helpers_misc.go`

**Example**:
```javascript
record.label = nvl2(record.name, "Named: " + record.name, "Anonymous");
```

---

### Function: `emptyToNull(v) -> any`

**What**: Converts empty/whitespace-only strings to null. Other types pass through.

**Where**: `internal/transform/helpers_misc.go`

---

### Function: `nullToEmpty(v) -> any`

**What**: Converts null to empty string. Other values pass through.

**Where**: `internal/transform/helpers_misc.go`

---

### Function: `decode(value, match1, result1, ..., default) -> any`

**What**: Oracle DECODE -- matches value against pairs, returns corresponding result.

**How**: Compares as strings. If odd remaining args, last is default.

**Where**: `internal/transform/helpers_misc.go`

**Example**:
```javascript
record.label = decode(record.status, "A", "Active", "I", "Inactive", "Unknown");
```

---

### Function: `between(value, low, high) -> bool`

**What**: Checks if a numeric value is in [low, high] (inclusive). Same as `inRange` but in misc.

**Where**: `internal/transform/helpers_misc.go`

---

### Function: `greatest(...values) -> any`

**What**: Returns the maximum value from a list (compared as float64).

**Where**: `internal/transform/helpers_misc.go`

**Example**: `greatest(3, 7, 1, 9)` returns `9`.

---

### Function: `least(...values) -> any`

**What**: Returns the minimum value from a list (compared as float64).

**Where**: `internal/transform/helpers_misc.go`

**Example**: `least(3, 7, 1, 9)` returns `1`.

---

### Function: `tag(record, name, value) -> map`

**What**: Adds a key-value pair to a record and returns a new copy.

**Why**: Non-destructively tag records with metadata.

**Where**: `internal/transform/helpers_misc.go`

**Example**:
```javascript
record = tag(record, "source", "legacy_db");
```

---

### Function: `normalizeUnicode(s, form) -> string`

**What**: Normalizes a string to the given Unicode form.

**How**: Forms: `"NFC"`, `"NFD"`, `"NFKC"`, `"NFKD"`.

**Where**: `internal/transform/helpers_misc.go`

---

### Function: `categorize(value, ranges) -> string`

**What**: Maps a numeric value to a category based on range definitions.

**How**: Ranges map uses `{category: [min, max]}`. Matches `min <= value < max`.

**Where**: `internal/transform/helpers.go`

**Example**:
```javascript
record.tier = categorize(record.amount, {
    "Bronze": [0, 1000],
    "Silver": [1000, 5000],
    "Gold":   [5000, Infinity]
});
```

---

## 17. Context Functions

The `ctx` object (`TransformContext`) is available in all transform scripts and provides stateful operations across records.

### Function: `ctx.GetState(key) -> any`

**What**: Retrieves a value from shared state by key.

**Where**: `internal/transform/context.go`

---

### Function: `ctx.SetState(key, value)`

**What**: Stores a value in shared state.

**Where**: `internal/transform/context.go`

---

### Function: `ctx.HasState(key) -> bool`

**What**: Checks if a key exists in shared state.

**Where**: `internal/transform/context.go`

---

### Function: `ctx.NextSequence(name) -> int64`

**What**: Increments and returns the next sequence value for the named sequence.

**Where**: `internal/transform/context.go`

**Example**:
```javascript
record.seq_id = ctx.NextSequence("order_seq");
```

---

### Function: `ctx.CurrentSequence(name) -> int64`

**What**: Returns the current sequence value without incrementing.

**Where**: `internal/transform/context.go`

---

### Function: `ctx.ResetSequence(name)`

**What**: Resets a named sequence to 0.

**Where**: `internal/transform/context.go`

---

### Function: `ctx.Accumulate(key, value) -> float64`

**What**: Adds a value to a running sum and returns the new total.

**Where**: `internal/transform/context.go`

**Example**:
```javascript
record.running_total = ctx.Accumulate("total", record.amount);
```

---

### Function: `ctx.TrackMin(key, value) -> float64`

**What**: Tracks the minimum value seen for a key. Returns the current minimum.

**Where**: `internal/transform/context.go`

---

### Function: `ctx.TrackMax(key, value) -> float64`

**What**: Tracks the maximum value seen for a key. Returns the current maximum.

**Where**: `internal/transform/context.go`

---

### Function: `ctx.TrackAverage(key, value) -> float64`

**What**: Tracks a running average for a key. Returns the current average.

**Where**: `internal/transform/context.go`

---

### Function: `ctx.GetAverage(key) -> float64`

**What**: Returns the current running average without adding a new value.

**Where**: `internal/transform/context.go`

---

### Function: `ctx.Increment(key) -> int64`

**What**: Increments an integer counter by 1 (starts from 0).

**Where**: `internal/transform/context.go`

---

### Function: `ctx.IncrementBy(key, delta) -> int64`

**What**: Increments an integer counter by a custom delta.

**Where**: `internal/transform/context.go`

---

### Function: `ctx.RowNumber(partitionKey) -> int64`

**What**: Returns an incrementing row number within a partition.

**Where**: `internal/transform/context.go`

**Example**:
```javascript
record.row_num = ctx.RowNumber(record.department);
```

---

### Function: `ctx.Rank(partitionKey, orderValue) -> int64`

**What**: Returns the rank within a partition (same value = same rank, gaps on next different value).

**Where**: `internal/transform/context.go`

---

### Function: `ctx.DenseRank(partitionKey, orderValue) -> int64`

**What**: Returns the dense rank within a partition (same value = same rank, no gaps).

**Where**: `internal/transform/context.go`

---

### Function: `ctx.RunningSum(key, value) -> float64`

**What**: Maintains a running sum for a named accumulator.

**Where**: `internal/transform/context.go`

---

### Function: `ctx.RunningCount(key) -> int64`

**What**: Maintains a running count for a named counter.

**Where**: `internal/transform/context.go`

---

### Function: `ctx.Lag(windowName, field, offset) -> any`

**What**: Returns a field value from a previous record in a named window.

**Where**: `internal/transform/context.go`

**Example**:
```javascript
record.prev_amount = ctx.Lag("main", "amount", 1);
```

---

### Function: `ctx.Lead(windowName, field, offset) -> any`

**What**: Returns a field value from a future record in a named window.

**Where**: `internal/transform/context.go`

---

### Function: `ctx.NTile(partitionKey, n) -> int`

**What**: Divides rows into n buckets (1-indexed) within a partition.

**Where**: `internal/transform/context.go`

---

## 18. Lookup Functions

> Available only when a `LookupService` is configured on the engine.

### Function: `lookup(dbName, query, ...args) -> map[]`

**What**: Executes a SELECT query against a named database and returns all rows.

**Why**: Enrich records with data from reference tables during transformation.

**How**: Validates query is SELECT-only (no INSERT/UPDATE/DELETE/DROP). Arguments are positional bind parameters.

**Where**: `internal/transform/lookup.go`

**Signature**: `lookup(dbName, query, ...args) -> map[]`

**Example**:
```javascript
var refs = lookup("refdb", "SELECT code, name FROM lookup_table WHERE code = $1", record.code);
if (refs.length > 0) { record.name = refs[0].name; }
```

---

### Function: `lookupOne(dbName, query, ...args) -> map|null`

**What**: Executes a SELECT query and returns the first row, or null.

**Where**: `internal/transform/lookup.go`

**Example**:
```javascript
var ref = lookupOne("refdb", "SELECT name FROM countries WHERE code = $1", record.country_code);
if (ref) { record.country_name = ref.name; }
```

---

## 19. Typed Record Accessors

Groovy-compatible typed accessors for reading record fields with automatic type conversion.

### Function: `getString(record, field) -> string`

**What**: Returns a record field as string (empty string if null).

**Where**: `internal/transform/helpers_cross_record.go`

---

### Function: `getLong(record, field) -> int64`

**What**: Returns a record field as int64 (0 if null/unparseable).

**Where**: `internal/transform/helpers_cross_record.go`

---

### Function: `getInteger(record, field) -> int`

**What**: Returns a record field as int (0 if null/unparseable).

**Where**: `internal/transform/helpers_cross_record.go`

---

### Function: `getDouble(record, field) -> float64`

**What**: Returns a record field as float64 (0 if null/unparseable).

**Where**: `internal/transform/helpers_cross_record.go`

---

### Function: `getTimestamp(record, field) -> int64`

**What**: Returns a record field as int64 (unix millis). Alias for `getLong`.

**Where**: `internal/transform/helpers_cross_record.go`

---

## Additional Registered Helpers

### Function: `groupBy(records, keyFields) -> map`

**What**: Groups an array of records by key field(s), returning `{key: [records...]}`.

**How**: `keyFields` can be a string (single) or array (composite key).

**Where**: `internal/transform/helpers_cross_record.go`

**Example**:
```javascript
var byDept = groupBy(records, "department");
var byCompKey = groupBy(records, ["region", "department"]);
```

---

### Function: `checkPrecisionScale(value, precision, scale) -> bool`

**What**: Validates that a numeric value fits within `NUMBER(precision, scale)`.

**Why**: Oracle NUMBER constraint validation during migration.

**How**: Strips sign, splits on decimal, counts significant and decimal digits.

**Where**: `internal/transform/helpers_cross_record.go`

**Example**:
```javascript
if (!checkPrecisionScale(record.amount, 10, 2)) { record._invalid = true; }
```

---

### Function: `jsonEncapsulate(record) -> string`

**What**: Converts a record map to a JSON string.

**Where**: `internal/transform/helpers_json_xml.go`

---

### Function: `jsonDecapsulate(jsonStr) -> map`

**What**: Parses a JSON string into a record map.

**Where**: `internal/transform/helpers_json_xml.go`

---

### Function: `xmlEncapsulate(record, rootTag) -> string`

**What**: Converts a record map to XML with the given root tag.

**Where**: `internal/transform/helpers_json_xml.go`

---

### Function: `xmlDecapsulate(xmlStr, rootTag) -> map`

**What**: Parses an XML string into a record map.

**Where**: `internal/transform/helpers_json_xml.go`

---

### Function: `flattenJSON(obj, prefix) -> map`

**What**: Flattens a nested map into a flat map using dot-notation keys.

**Where**: `internal/transform/helpers_json_xml.go`

**Example**:
```javascript
var flat = flattenJSON({user: {name: "Alice", age: 30}}, "");
// {"user.name": "Alice", "user.age": 30}
```

---

### Function: `flattenXML(xmlStr) -> map`

**What**: Parses XML and flattens into a flat map using dot-notation keys.

**Where**: `internal/transform/helpers_json_xml.go`

---

### Function: `jsonPathExtract(obj, path) -> any`

**What**: Extracts a value from a JSON-like object using path notation. Supports bracket notation (`items[0].price`) in addition to dots.

**Where**: `internal/transform/helpers_json_xml.go`

---

## Function Count Summary

| Category | Count |
|----------|-------|
| String | 24 |
| Date/Time | 24 |
| Math | 14 |
| Hash/UUID | 4 |
| Type Conversion | 12 |
| Validation | 7 |
| Masking | 6 |
| Array | 16 |
| Regex | 5 |
| JSON | 14 |
| XML | 12 |
| Encoding | 6 |
| Statistics | 4 |
| Cross-Record | 17 |
| Window | 3 |
| Misc/SQL-Like | 11 |
| Context (ctx.*) | 22 |
| Lookup | 2 |
| Typed Accessors | 5 |
| Additional (groupBy, checkPrecisionScale, encapsulation) | 9 |
| **Total** | **~196 (including ctx methods)** |

> The `bindHelpers()` function in `engine.go` registers **126 top-level JS functions**. The `TransformContext` exposes an additional **22 methods** via the `ctx` object, and `bindLookupService()` adds **2 more** when a lookup service is configured.
