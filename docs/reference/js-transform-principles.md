# JS Transform Principles — High-Throughput Record Processing

**Target**: 300K+ records/sec for 1:1 transforms, 100K+ records/sec for N:N group operations.

---

## 1. The Four Transform Modes

| Mode | Script Receives | Script Returns | Use Case |
|------|----------------|----------------|----------|
| **1:1** (one_to_one) | `record` — single map | `record` — single map | Field transforms, enrichment, type conversion |
| **1:N** (one_to_many) | `record` — single map | `[record, ...]` — array of maps | Explode arrays, split delimited fields, unpivot |
| **N:1** (many_to_one) | `records` — array of maps | `record` — single map | Aggregate, summarize, pivot EAV→wide |
| **N:N** (many_to_many) | `records` — array of maps | `[record, ...]` — array of maps | Cross-record validation, ranking, fill-forward |

For N:1 and N:N, records are **grouped by `group_by` columns** before the script runs. Each group is processed independently.

```yaml
- id: transform
  type: transform
  input: source_data
  output: result
  mode: many_to_many        # or one_to_one, one_to_many, many_to_one
  group_by: [entity_id]     # required for N:1 and N:N
  threads: 4                # parallel worker goroutines
  script: |
    // your JS code here
```

---

## 2. Core Principles

### Principle 1: Return early, return the right type

Every script **must** return a value. The return type must match the mode:

```javascript
// 1:1 — return a single record (the modified input or a new object)
record.name = upper(record.name);
record;                              // GOOD: returns the record

// 1:N — return an array of records
var results = [];
results.push({id: record.id, type: 'header'});
results.push({id: record.id, type: 'detail'});
results;                             // GOOD: returns array

// N:1 — return a single aggregated record
var sum = 0;
for (var i = 0; i < records.length; i++) sum += records[i].amount;
({entity_id: records[0].entity_id, total: sum});  // GOOD: returns one record

// N:N — return an array (same or different length as input)
records;                             // GOOD: returns the group
```

**Common mistake**: forgetting the trailing expression. The last expression is the return value — if the last line is an assignment (`var x = ...`), the return is `undefined` and the engine throws an error.

### Principle 2: Mutate in place for 1:1, copy for everything else

**1:1 mode**: mutate `record` directly. The engine passes a map reference — modifications are captured without allocating a new object.

```javascript
// GOOD: mutate in place (fast, no allocation)
record.name = upper(record.name);
record.hash = hash(record.id + record.name);
record;

// SLOW: creating a new object (unnecessary copy)
var out = {};
for (var k in record) out[k] = record[k];
out.name = upper(out.name);
out;
```

**N:N mode**: if you modify records in place, the original dataset is unaffected (the engine copies records before passing them to your script). But if you return fewer/more records than input, you must build a new array.

### Principle 3: Minimize Go↔JS boundary crossings

Every built-in helper call (e.g., `upper()`, `hash()`, `toFloat()`) crosses the Go↔JS boundary. Each crossing costs ~100ns. At 300K records/sec, you have ~3.3μs per record — that's roughly **33 helper calls max** before you exceed budget.

```javascript
// GOOD: 5 helper calls per record (~500ns overhead)
record.name = upper(record.name);
record.domain = split(record.email, '@')[1];
record.hash = hash(toString(record.id));
record.age_group = record.age < 30 ? 'young' : 'senior';
record.rounded = roundTo(record.balance, 0);
record;

// BAD: 20+ helper calls per record (~2μs overhead, eats into budget)
record.f1 = trim(record.f1);
record.f2 = trim(record.f2);
// ... repeat for 20 fields
```

**Optimization**: batch similar operations in native JS when possible:

```javascript
// BETTER: one loop in JS instead of 20 helper calls
var fields = ['f1','f2','f3','f4','f5','f6','f7','f8','f9','f10'];
for (var i = 0; i < fields.length; i++) {
    var v = record[fields[i]];
    if (typeof v === 'string') record[fields[i]] = v.trim();
}
record;
```

### Principle 4: Use the right mode for the job

| If you need to... | Use mode | Not |
|-------------------|----------|-----|
| Transform each record independently | **1:1** | N:N with single-record logic |
| Split one record into many | **1:N** | N:N returning larger array |
| Aggregate a group into one summary | **N:1** | N:N returning single-element array |
| Compare/rank/validate across a group | **N:N** | Multiple 1:1 passes with shared state |

**Wrong mode = wrong throughput.** 1:1 at 300K/s processes 10M records in 33s. N:N at 100K/s on the same data (grouped into 10K groups of 1K records each) takes 100s. Don't use N:N when 1:1 suffices.

### Principle 5: Keep group sizes bounded

N:1 and N:N load the **entire group into memory** as a JS array. If your `group_by` key has skewed distribution (e.g., one customer has 5M records), that single group will:

- Allocate 5M × ~200 bytes = ~1GB of JS objects
- Block one worker goroutine for the entire processing time
- Risk goja VM memory limits

**Mitigations**:
- Choose `group_by` keys with bounded cardinality (1K-10K records per group)
- Use `partition_by` on the upstream query step to split large groups
- Set `memory_threshold_mb` in pipeline settings

### Principle 6: Pre-compute expensive values outside the hot loop

For N:N mode, build indexes and aggregates **once** before iterating:

```javascript
// GOOD: O(N) — build index once, lookup O(1) per record
var index = {};
for (var i = 0; i < records.length; i++) {
    index[records[i].code] = records[i];
}
for (var i = 0; i < records.length; i++) {
    var ref = index[records[i].ref_code];
    if (ref) records[i].ref_value = ref.value;
}
records;

// BAD: O(N²) — nested loop searching for each record
for (var i = 0; i < records.length; i++) {
    for (var j = 0; j < records.length; j++) {
        if (records[j].code === records[i].ref_code) {
            records[i].ref_value = records[j].value;
            break;
        }
    }
}
records;
```

**Or use the built-in helpers** which are implemented in Go (faster than JS loops):

```javascript
// BEST: Go-native lookup — O(N) with hash map, faster than JS loop
var enriched = leftJoinRecords(records, records, 'ref_code', 'code');
enriched;
```

---

## 3. Mode-Specific Patterns

### 1:1 — Per-Record Transform

**Pipeline YAML**:
```yaml
mode: one_to_one
threads: 8
```

**Pattern: Field enrichment**
```javascript
record.name_upper = upper(record.name);
record.email_domain = split(record.email, '@')[1];
record.age_group = record.age < 30 ? 'young' : record.age < 60 ? 'middle' : 'senior';
record.balance_fmt = '$' + roundTo(record.balance, 2);
record.record_hash = hash(toString(record.id) + record.name);
record;
```

**Pattern: Conditional field setting**
```javascript
if (record.country === 'VN') {
    record.tax_rate = 0.10;
    record.currency = 'VND';
} else if (record.country === 'US') {
    record.tax_rate = 0.07;
    record.currency = 'USD';
} else {
    record.tax_rate = 0.20;
    record.currency = 'EUR';
}
record.tax_amount = record.amount * record.tax_rate;
record;
```

**Pattern: Data masking**
```javascript
record.email = maskEmail(record.email);
record.phone = maskPhone(record.phone);
record.ssn = maskSSN(record.ssn);
record.card = maskCard(record.card_number);
record;
```

**Throughput**: 300K-500K records/sec with 4-8 threads.

### 1:N — Record Explosion

**Pipeline YAML**:
```yaml
mode: one_to_many
threads: 4
```

**Pattern: Explode array field**
```javascript
var items = record.items;
if (typeof items === 'string') items = jsonParse(items);
var results = [];
for (var i = 0; i < items.length; i++) {
    results.push({
        order_id: record.order_id,
        customer: record.customer,
        item_id: items[i].id,
        item_name: items[i].name,
        quantity: items[i].qty,
        price: items[i].price
    });
}
results;
```

**Pattern: Split delimited field**
```javascript
var tags = split(record.tags, ';');
var results = [];
for (var i = 0; i < tags.length; i++) {
    results.push({
        id: record.id,
        name: record.name,
        tag: trim(tags[i]),
        tag_index: i
    });
}
results;
```

**Pattern: Wide → EAV (unpivot)**
```javascript
var attrs = ['height', 'weight', 'color', 'size'];
var results = [];
for (var i = 0; i < attrs.length; i++) {
    if (record[attrs[i]] !== null && record[attrs[i]] !== undefined) {
        results.push({
            product_id: record.id,
            attribute_name: attrs[i],
            attribute_value: toString(record[attrs[i]])
        });
    }
}
results;
```

**Throughput**: 200K-300K input records/sec (output records multiply).

### N:1 — Group Aggregation

**Pipeline YAML**:
```yaml
mode: many_to_one
group_by: [customer_id]
threads: 4
```

**Pattern: Custom aggregation**
```javascript
var first = records[0];
var totalAmount = 0;
var maxDate = '';
var orderCount = records.length;

for (var i = 0; i < records.length; i++) {
    totalAmount += records[i].amount;
    if (records[i].order_date > maxDate) maxDate = records[i].order_date;
}

({
    customer_id: first.customer_id,
    customer_name: first.customer_name,
    total_amount: roundTo(totalAmount, 2),
    order_count: orderCount,
    avg_order: roundTo(totalAmount / orderCount, 2),
    last_order_date: maxDate
});
```

**Pattern: EAV → Wide (pivot)**
```javascript
// Using built-in pivotWithSchema (Go-native, faster than JS loop)
pivotWithSchema(records, 'entity_id', 'attr_name', 'attr_value',
    {age: 'int', price: 'float', active: 'bool'},
    {age: 0, price: 0.0, active: false}
);
```

**Pattern: Summarize with built-in helper**
```javascript
summarize(records, {
    amount: 'sum',
    name: 'count',
    price: 'avg',
    created_at: 'min',
    updated_at: 'max',
    status: 'first'
}, null);
```

**Throughput**: 100K-200K input records/sec (depends on group size).

### N:N — Cross-Record Processing

**Pipeline YAML**:
```yaml
mode: many_to_many
group_by: [header_id]
threads: 4
```

**Pattern: Running total**
```javascript
var sorted = sortRecords(records, 'date ASC', null);
var cumSum = 0;
for (var i = 0; i < sorted.length; i++) {
    cumSum += sorted[i].amount;
    sorted[i].running_total = cumSum;
    sorted[i].row_num = i + 1;
}
sorted;
```

**Pattern: Cross-record validation (RulesCheck)**
```javascript
// Using the 2-phase rule engine
var singleRules = buildRuleMap([
    {formcode: 'FORM_A', code: 'VALUE', gc: 'cau_1_%', type: 'GTE_ZERO'},
    {formcode: 'FORM_A', code: 'CL_UNIT', gc: 'cau_1_%', type: 'IN', value: 'KG'}
], 'formcode', 'code');

var crossRules = [
    {type: 'EQUALS', formcode: 'FORM_A', code: 'TOTAL',
     filter1: "Code='TOTAL'", filter2: "Code='SUM'", field: 'Value'}
];

evaluateRuleSet(records, singleRules, crossRules, {
    formCodeField: 'FormCode', codeField: 'Code',
    groupCodeField: 'GroupCode', valueField: 'Value'
});
```

**Pattern: Dedup with ranking**
```javascript
// Keep the latest record per (customer_id, product_id) within the group
var index = {};
for (var i = 0; i < records.length; i++) {
    var key = records[i].customer_id + ':' + records[i].product_id;
    if (!index[key] || records[i].updated_at > index[key].updated_at) {
        index[key] = records[i];
    }
}
var results = [];
for (var key in index) results.push(index[key]);
results;
```

**Pattern: Fill forward (time series gap filling)**
```javascript
var sorted = sortRecords(records, 'timestamp ASC', null);
var lastPrice = null;
for (var i = 0; i < sorted.length; i++) {
    if (sorted[i].price !== null && sorted[i].price !== undefined) {
        lastPrice = sorted[i].price;
    } else if (lastPrice !== null) {
        sorted[i].price = lastPrice;
        sorted[i]._filled = true;
    }
}
sorted;
```

**Throughput**: 50K-150K input records/sec (depends on group size and operation complexity).

---

## 4. Performance Guidelines

### Thread Scaling

| Dataset Size | Recommended Threads | Why |
|-------------|-------------------|-----|
| < 10K records | 1-2 | Overhead of goroutine management > benefit |
| 10K-100K | 4 | Good balance for most transforms |
| 100K-1M | 4-8 | Scales linearly with cores |
| > 1M | 8-16 | Diminishing returns above core count |

### Memory Budget Per Record

| Operation | Approx Memory | Notes |
|-----------|--------------|-------|
| `record.ToMap()` | ~200 bytes + field sizes | Created per record for Go→JS |
| `record.FromMapPooled()` | ~100 bytes (reused) | Returned from JS→Go |
| Each JS object property | ~64 bytes | goja internal overhead |
| Built-in helper call | ~0 bytes (stateless) | Go functions, no JS allocation |
| `sortRecords` (N:N) | N × ~64 bytes | Creates sorted copy |
| `buildRuleMap` (N:N) | Rule count × ~200 bytes | Built once per group |

For 300K records/sec with 4 threads: each thread processes ~75K records/sec = ~13μs per record. Budget: ~2.6KB of memory per record in flight (200 bytes × 4 threads × pipeline depth).

### What Costs More Than You Think

| Operation | Cost | Alternative |
|-----------|------|-------------|
| `jsonParse()` on every record | ~5μs/call | Parse once, store as object |
| `hash()` (SHA-256) | ~2μs/call | Only hash when needed |
| `regexTest()` with complex pattern | ~1-5μs/call | Pre-filter with `contains()` first |
| Creating new objects in 1:1 mode | ~1μs/alloc | Mutate `record` in place |
| `fmt.Sprintf("%v")` in hot path | ~500ns/call | Use `toString()` helper |
| Accessing deep nested property | ~200ns/level | Flatten to top-level before transform |

### What's Cheaper Than You Think

| Operation | Cost | Notes |
|-----------|------|-------|
| `upper()` / `lower()` / `trim()` | ~50ns | Go-native string ops |
| `record.field` property access | ~30ns | Direct map lookup |
| Numeric comparison (`> < == !=`) | ~10ns | Native JS |
| String concatenation (`+`) | ~50ns | goja optimized |
| `toFloat()` / `toInt()` | ~100ns | Type switch, no parsing for native types |

---

## 5. Anti-Patterns

### Don't: Use N:N when 1:1 suffices
```javascript
// BAD: N:N mode for per-record logic (10x slower due to group overhead)
for (var i = 0; i < records.length; i++) {
    records[i].name = upper(records[i].name);
}
records;

// GOOD: 1:1 mode (300K/s vs 30K/s)
record.name = upper(record.name);
record;
```

### Don't: Build arrays for single values in N:1
```javascript
// BAD: returns array with one element
var result = summarize(records, {amount: 'sum'}, null);
[result];  // Wrong! N:1 expects a single record, not an array

// GOOD: return the record directly
summarize(records, {amount: 'sum'}, null);
```

### Don't: Re-parse static data per record
```javascript
// BAD: parses JSON config on every record
var config = jsonParse('{"tax_rates":{"US":0.07,"EU":0.21}}');
record.tax = record.amount * config.tax_rates[record.region];
record;

// GOOD: use require() for static data (loaded once, cached)
var config = require('./config.js');
record.tax = record.amount * config.tax_rates[record.region];
record;
```

### Don't: Use O(N²) algorithms in N:N
```javascript
// BAD: O(N²) — nested loop for lookup
for (var i = 0; i < records.length; i++) {
    for (var j = 0; j < records.length; j++) {
        if (records[j].id === records[i].parent_id) {
            records[i].parent_name = records[j].name;
        }
    }
}

// GOOD: O(N) — build index first
var idx = {};
for (var i = 0; i < records.length; i++) idx[records[i].id] = records[i];
for (var i = 0; i < records.length; i++) {
    var p = idx[records[i].parent_id];
    if (p) records[i].parent_name = p.name;
}

// BEST: use Go-native helper (even faster)
var enriched = leftJoinRecords(records, records, 'parent_id', 'id');
```

---

## 6. Quick Reference — Available Helpers by Category

| Category | Count | Key Functions |
|----------|-------|---------------|
| String | 20+ | upper, lower, trim, split, join, replace, padLeft, contains, startsWith |
| Type | 11 | toInt, toFloat, toString, toBool, isNull, isBlank, autoType |
| DateTime | 18+ | parseDate, formatDate, addDays, dateDiff, year, month, quarter |
| Math | 11 | round, roundTo, floor, ceil, abs, min, max, pow, sqrt, random |
| Hash/Crypto | 4 | hash (SHA256), md5, sha256, uuid |
| Array | 14 | arrayContains, unique, filter, map, flatMap, sort, in |
| JSON/XML | 25+ | jsonParse, jsonStringify, jsonExtract, XMLParse, XMLToJSON |
| Regex | 5 | regexTest, regexMatch, regexReplace, regexCapture |
| Masking | 6 | maskSSN, maskEmail, maskPhone, maskCard, redact, tokenize |
| Validation | 7+ | isEmail, isPhone, isURL, isIP, isUUID, isNumeric, inRange |
| **Set Ops** | 10 | outerJoinRecords, antiJoinRecords, semiJoinRecords, diffRecords, minusRecords |
| **Aggregation** | 10 | summarize, rollup, runningTotal, rankRecords, topN, bottomN |
| **Window** | 10 | sortRecords, lagValue, leadValue, movingAvg, ntile, rowNumber |
| **Reshape** | 10 | explodeField, fillForward, fillBackward, interpolateRecords, pick, omit |
| **Validation** | 10 | crossBalance, crossSequential, detectDuplicates, validateSchema |
| **EAV** | 28 | pivotWithSchema, buildEntityRecord, compareEntities, filterEntitiesByAttributes |
| **Rule Engine** | 8 | evaluateRuleSet, buildRuleMap, matchPattern, checkLookup, checkDivision |
| **Total** | **230+** | |

All helpers are optional — write pure JS when it's simpler or faster.
