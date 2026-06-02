# Aggregate Functions Reference

Complete reference for all aggregate functions in Mass Migrator v3.

## Table of Contents

1. [Basic Aggregates](#basic-aggregates)
2. [Statistical Aggregates](#statistical-aggregates)
3. [Array Aggregates](#array-aggregates)
4. [Advanced Grouping](#advanced-grouping)
5. [NULL Handling](#null-handling)
6. [Performance Notes](#performance-notes)

---

## Basic Aggregates

### COUNT

Counts non-NULL values in a column.

```yaml
steps:
  - name: count_records
    type: aggregate
    input: sales
    output: counts
    group_by: [product_id]
    aggregations:
      - column: transaction_id
        function: COUNT
        alias: transaction_count
```

**Return Type:** `int64`

**NULL Handling:** NULL values are not counted

**Variants:**
- `COUNT(column)` - Count non-NULL values
- `COUNT(*)` - Count all rows (use with no column specified)

**Example:**

```yaml
steps:
  - name: total_records
    type: aggregate
    input: data
    output: record_count
    group_by: []  # No grouping - count all rows
    aggregations:
      - column: "*"
        function: COUNT
        alias: total_rows
```

---

### SUM

Sums non-NULL numeric values.

```yaml
steps:
  - name: total_sales
    type: aggregate
    input: sales
    output: totals
    group_by: [region, product_category]
    aggregations:
      - column: amount
        function: SUM
        alias: total_amount
```

**Return Type:** `float64`

**NULL Handling:** NULL values are ignored

**Data Types:**
- INT, BIGINT → float64
- FLOAT, DOUBLE → float64
- NUMERIC, DECIMAL → float64

**Example: Multiple SUM Aggregates**

```yaml
steps:
  - name: financial_totals
    type: aggregate
    input: transactions
    output: financials
    group_by: [account_id]
    aggregations:
      - column: debit_amount
        function: SUM
        alias: total_debits

      - column: credit_amount
        function: SUM
        alias: total_credits

      - column: balance
        function: SUM
        alias: net_balance
```

---

### AVG

Calculates arithmetic mean of non-NULL numeric values.

```yaml
steps:
  - name: average_order_value
    type: aggregate
    input: orders
    output: averages
    group_by: [customer_id]
    aggregations:
      - column: order_amount
        function: AVG
        alias: avg_order_value
```

**Return Type:** `float64`

**NULL Handling:** NULL values are ignored

**Formula:** `SUM(values) / COUNT(values)`

**Example: Moving Averages**

```yaml
steps:
  - name: daily_averages
    type: aggregate
    input: hourly_metrics
    output: daily_avg
    group_by: [date, metric_name]
    aggregations:
      - column: value
        function: AVG
        alias: daily_average

      - column: value
        function: COUNT
        alias: observation_count
```

---

### MIN

Returns minimum non-NULL value.

```yaml
steps:
  - name: price_ranges
    type: aggregate
    input: products
    output: prices
    group_by: [category]
    aggregations:
      - column: price
        function: MIN
        alias: min_price
```

**Return Type:** Same as input column

**NULL Handling:** NULL values are ignored

**Data Types:** Works with numeric, string, date, timestamp

**Example: Date Ranges**

```yaml
steps:
  - name: activity_periods
    type: aggregate
    input: user_activity
    output: periods
    group_by: [user_id]
    aggregations:
      - column: activity_date
        function: MIN
        alias: first_activity

      - column: activity_date
        function: MAX
        alias: last_activity
```

---

### MAX

Returns maximum non-NULL value.

```yaml
steps:
  - name: high_water_marks
    type: aggregate
    input: metrics
    output: peaks
    group_by: [metric_name]
    aggregations:
      - column: value
        function: MAX
        alias: peak_value
```

**Return Type:** Same as input column

**NULL Handling:** NULL values are ignored

**Data Types:** Works with numeric, string, date, timestamp

---

## Statistical Aggregates

### STDDEV

Calculates population standard deviation of non-NULL numeric values.

```yaml
steps:
  - name: sales_volatility
    type: aggregate
    input: sales
    output: volatility
    group_by: [product_id]
    aggregations:
      - column: amount
        function: STDDEV
        alias: sales_stddev
```

**Return Type:** `float64`

**NULL Handling:** NULL values are ignored

**Formula:** `SQRT(VARIANCE(values))`

**Use Cases:**
- Measuring volatility
- Outlier detection (values > mean ± 2*stddev)
- Quality control
- Risk assessment

**Example: Outlier Detection**

```yaml
steps:
  - name: calculate_statistics
    type: aggregate
    input: measurements
    output: stats
    group_by: [sensor_id]
    aggregations:
      - column: temperature
        function: AVG
        alias: avg_temp

      - column: temperature
        function: STDDEV
        alias: temp_stddev

  - name: detect_outliers
    type: transform
    input: measurements
    output: outliers
    script: |
      var mean = row.avg_temp;
      var stddev = row.temp_stddev;
      var value = row.temperature;

      // Flag values beyond 2 standard deviations
      row.is_outlier = Math.abs(value - mean) > (2 * stddev);
```

---

### VARIANCE

Calculates population variance of non-NULL numeric values.

```yaml
steps:
  - name: price_variance
    type: aggregate
    input: prices
    output: variance_analysis
    group_by: [product_id]
    aggregations:
      - column: price
        function: VARIANCE
        alias: price_variance
```

**Return Type:** `float64`

**NULL Handling:** NULL values are ignored

**Formula:** `SUM((x - mean)²) / n`

**Use Cases:**
- Measuring spread
- Financial risk analysis
- Quality variation
- Statistical analysis

**Example: Coefficient of Variation**

```yaml
steps:
  - name: calculate_cv
    type: aggregate
    input: data
    output: cv
    group_by: [category]
    aggregations:
      - column: value
        function: AVG
        alias: mean_value

      - column: value
        function: STDDEV
        alias: std_dev

  - name: compute_cv
    type: transform
    input: cv
    output: with_cv
    script: |
      // Coefficient of variation = std / mean
      // Measures relative variability
      row.cv = row.std_dev / row.mean_value;
```

---

### MEDIAN

Calculates median (50th percentile) of non-NULL numeric values.

```yaml
steps:
  - name: median_prices
    type: aggregate
    input: products
    output: price_analysis
    group_by: [category]
    aggregations:
      - column: price
        function: MEDIAN
        alias: median_price
```

**Return Type:** Same as input column

**NULL Handling:** NULL values are ignored

**Algorithm:**
- Sort all values
- Return middle value (odd count) or average of two middle values (even count)

**Performance:** O(n log n) due to sorting

**Use Cases:**
- Robust central tendency (less sensitive to outliers than mean)
- Income analysis
- Housing prices
- Response times

**Example: Mean vs Median**

```yaml
steps:
  - name: compare_metrics
    type: aggregate
    input: salaries
    output: compensation
    group_by: [department]
    aggregations:
      - column: salary
        function: AVG
        alias: avg_salary

      - column: salary
        function: MEDIAN
        alias: median_salary

      - column: salary
        function: STDDEV
        alias: salary_stddev

  - name: analyze_skew
    type: transform
    input: compensation
    output: skew_analysis
    script: |
      // If mean >> median, distribution is right-skewed
      var mean = row.avg_salary;
      var median = row.median_salary;

      if (mean > median * 1.5) {
        row.distribution = 'right_skewed';
      } else if (mean < median * 0.5) {
        row.distribution = 'left_skewed';
      } else {
        row.distribution = 'approximately_symmetric';
      }
```

---

### PERCENTILE_CONT

Calculates continuous percentile of non-NULL numeric values.

```yaml
steps:
  - name: percentiles
    type: aggregate
    input: response_times
    output: latency_analysis
    group_by: [endpoint]
    aggregations:
      - column: duration_ms
        function: PERCENTILE_CONT
        percentile: 0.50  # Median
        alias: p50

      - column: duration_ms
        function: PERCENTILE_CONT
        percentile: 0.95
        alias: p95

      - column: duration_ms
        function: PERCENTILE_CONT
        percentile: 0.99
        alias: p99
```

**Return Type:** Same as input column

**NULL Handling:** NULL values are ignored

**Parameters:**
- `percentile`: 0.0 to 1.0 (e.g., 0.95 for 95th percentile)

**Algorithm:**
- Sort all values
- Interpolate at requested percentile

**Performance:** O(n log n) due to sorting

**Common Percentiles:**
- 0.50 (50th) - Median
- 0.90 (90th) - P90
- 0.95 (95th) - P95 (SLA common)
- 0.99 (99th) - P99 (tail latency)

**Example: SLO Analysis**

```yaml
steps:
  - name: latency_percentiles
    type: aggregate
    input: api_logs
    output: slo_analysis
    group_by: [service_name]
    aggregations:
      - column: latency_ms
        function: PERCENTILE_CONT
        percentile: 0.50
        alias: p50_ms

      - column: latency_ms
        function: PERCENTILE_CONT
        percentile: 0.95
        alias: p95_ms

      - column: latency_ms
        function: PERCENTILE_CONT
        percentile: 0.99
        alias: p99_ms

  - name: check_slo
    type: transform
    input: slo_analysis
    output: slo_compliance
    script: |
      // SLO: P95 < 500ms
      row.slo_met = row.p95_ms < 500;

      // SLO: P99 < 1000ms
      row.tail_slo_met = row.p99_ms < 1000;
```

---

## Array Aggregates

### ARRAY_AGG

Aggregates values into an array.

```yaml
steps:
  - name: collect_tags
    type: aggregate
    input: articles
    output: article_tags
    group_by: [article_id]
    aggregations:
      - column: tag
        function: ARRAY_AGG
        alias: all_tags
```

**Return Type:** `[]interface{}`

**NULL Handling:** NULL values can be included (use DISTINCT to exclude)

**Parameters:**
- `distinct`: Remove duplicate values (default: false)
- `order_by`: Sort values before aggregating

**Example: Collect IDs**

```yaml
steps:
  - name: customer_orders
    type: aggregate
    input: orders
    output: customer_order_lists
    group_by: [customer_id]
    aggregations:
      - column: order_id
        function: ARRAY_AGG
        alias: order_ids
        distinct: false

      - column: order_id
        function: COUNT
        alias: order_count
```

**Example: Ordered Array**

```yaml
steps:
  - name: recent_transactions
    type: aggregate
    input: transactions
    output: transaction_history
    group_by: [account_id]
    aggregations:
      - column: transaction_id
        function: ARRAY_AGG
        alias: recent_txn_ids
        order_by: ["transaction_date DESC"]
        distinct: true

      - column: transaction_date
        function: MAX
        alias: last_transaction_date
```

**Example: Distinct Values**

```yaml
steps:
  - name: unique_categories
    type: aggregate
    input: products
    output: category_lists
    group_by: [supplier_id]
    aggregations:
      - column: category
        function: ARRAY_AGG
        alias: unique_categories
        distinct: true  # Remove duplicates

      - column: category
        function: ARRAY_AGG
        alias: all_categories
        distinct: false  # Include duplicates
```

---

## Advanced Grouping

### ROLLUP

Generates hierarchical subtotals.

```yaml
steps:
  - name: sales_rollup
    type: aggregate
    input: sales
    output: sales_hierarchy
    group_by: [region, product, year]
    advanced_grouping:
      mode: rollup
    aggregations:
      - column: amount
        function: SUM
        alias: total_sales
```

**Output Levels:**
1. (region, product, year) - Base level
2. (region, product) - Subtotal by product
3. (region) - Subtotal by region
4. () - Grand total

---

### CUBE

Generates all combinations of subtotals.

```yaml
steps:
  - name: sales_cube
    type: aggregate
    input: sales
    output: sales_cube
    group_by: [region, channel]
    advanced_grouping:
      mode: cube
    aggregations:
      - column: amount
        function: SUM
        alias: total_sales
```

**Output Levels:**
1. (region, channel)
2. (region)
3. (channel)
4. ()

**Number of Levels:** 2^n where n = number of group_by columns

---

### GROUPING SETS

Custom grouping sets.

```yaml
steps:
  - name: custom_groups
    type: aggregate
    input: sales
    output: grouped
    group_by: [region, product, channel]
    advanced_grouping:
      mode: grouping_sets
      grouping_sets:
        - [region, product]      # Sales by region and product
        - [channel]              # Sales by channel only
        - []                     # Grand total
    aggregations:
      - column: amount
        function: SUM
        alias: total_sales
```

---

### GROUPING_ID

Bitmask indicating which columns are present in grouping.

```yaml
steps:
  - name: grouping_id_example
    type: aggregate
    input: sales
    output: with_grouping_id
    group_by: [region, product]
    advanced_grouping:
      mode: rollup
      grouping_id_col: grouping_mask
    aggregations:
      - column: amount
        function: SUM
        alias: total_sales

  - name: filter_totals_only
    type: filter
    input: with_grouping_id
    output: grand_total
    expression: "grouping_mask == 0"  # Only grand total
```

**GROUPING_ID Interpretation:**
- For columns [a, b, c]:
  - (a, b, c) → 0b111 = 7
  - (a, b) → 0b110 = 6
  - (a) → 0b100 = 4
  - () → 0b000 = 0

---

## NULL Handling

### Aggregate Functions and NULLs

**General Rules:**
1. NULL values are ignored in aggregates
2. COUNT(column) counts only non-NULL values
3. SUM/AVG of all NULLs returns NULL
4. MIN/MAX of all NULLs returns NULL
5. No warnings for NULL values

**Examples:**

```yaml
# Input: [1, 2, NULL, 4, NULL]
COUNT(value)  → 3  (non-NULL count)
SUM(value)    → 7  (1 + 2 + 4)
AVG(value)    → 2.333  (7 / 3)
MIN(value)    → 1
MAX(value)    → 4
```

### Handling All-NULL Groups

```yaml
steps:
  - name: handle_nulls
    type: aggregate
    input: data
    output: aggregated
    group_by: [category]
    aggregations:
      - column: value
        function: SUM
        alias: total

  - name: coalesce_nulls
    type: transform
    input: aggregated
    output: with_defaults
    script: |
      // Replace NULL with 0
      row.total = row.total || 0;
```

### NULL in Group By Columns

NULL values in GROUP BY columns are treated as a distinct group:

```yaml
# Input data:
# category, value
# A, 10
# A, 20
# NULL, 30
# NULL, 40

steps:
  - name: group_with_nulls
    type: aggregate
    input: data
    output: grouped
    group_by: [category]  # Creates groups: A, NULL
    aggregations:
      - column: value
        function: SUM
        alias: total

# Output:
# category | total
# A        | 30
# NULL     | 70
```

---

## Performance Notes

### Memory Usage

| Function | Memory Usage | Notes |
|----------|--------------|-------|
| COUNT, SUM, AVG | O(groups) | One accumulator per group |
| MIN, MAX | O(groups) | One value per group |
| STDDEV, VARIANCE | O(groups) | Two-pass algorithm |
| MEDIAN, PERCENTILE_CONT | O(group size) | Must sort all values |
| ARRAY_AGG | O(group size) | Stores all values |

### Time Complexity

| Function | Time Complexity | Notes |
|----------|----------------|-------|
| COUNT, SUM, AVG | O(n) | Single pass |
| MIN, MAX | O(n) | Single pass |
| STDDEV, VARIANCE | O(n) | Two pass |
| MEDIAN, PERCENTILE_CONT | O(n log n) | Requires sorting |
| ARRAY_AGG | O(n) | Single pass |

### Optimization Tips

**1. Use Approximate Aggregates for Large Groups:**

```yaml
# For cardinality estimation
steps:
  - name: approximate_count
    type: aggregate
    input: big_data
    output: counts
    group_by: [category]
    aggregations:
      - column: user_id
        function: COUNT
        alias: approx_distinct  # Use distinct for uniqueness
```

**2. Parallel Processing:**

```yaml
steps:
  - name: parallel_aggregate
    type: aggregate
    input: large_data
    output: aggregated
    group_by: [key_column]
    threads: 8  # Parallel worker threads
    aggregations:
      - column: value
        function: SUM
        alias: total
```

**3. Filter Before Aggregating:**

```yaml
# Bad: Aggregate all, then filter
steps:
  - name: aggregate_all
    type: aggregate
    input: all_sales
    output: totals
    group_by: [region]
    aggregations:
      - column: amount
        function: SUM
        alias: total

  - name: filter_regions
    type: filter
    input: totals
    expression: "region == 'WEST'"

# Good: Filter first, then aggregate
steps:
  - name: filter_first
    type: query
    database: warehouse
    sql: "SELECT * FROM sales WHERE region = 'WEST'"
    output: west_sales

  - name: aggregate_filtered
    type: aggregate
    input: west_sales
    output: west_totals
    group_by: [region]
    aggregations:
      - column: amount
        function: SUM
        alias: total
```

**4. Use Columnar Storage for Analytics:**

```yaml
steps:
  - name: read_parquet
    type: read
    path: ./analytics/large_dataset.parquet
    format: parquet
    output: data
```

---

## Complete Examples

### Sales Dashboard

```yaml
pipeline:
  name: sales_dashboard
  steps:
    - name: daily_sales
      type: aggregate
      input: transactions
      output: daily_metrics
      group_by: [sale_date]
      aggregations:
        - column: amount
          function: SUM
          alias: total_sales
        - column: transaction_id
          function: COUNT
          alias: transaction_count
        - column: amount
          function: AVG
          alias: avg_order_value
        - column: amount
          function: STDDEV
          alias: sales_volatility

    - name: product_performance
      type: aggregate
      input: transactions
      output: product_stats
      group_by: [product_id, product_name]
      aggregations:
        - column: amount
          function: SUM
          alias: total_revenue
        - column: amount
          function: MEDIAN
          alias: median_price
        - column: amount
          function: PERCENTILE_CONT
          percentile: 0.95
          alias: p95_price
        - column: transaction_id
          function: COUNT
          alias: sales_count

    - name: regional_analysis
      type: aggregate
      input: transactions
      output: regional_totals
      group_by: [region, product_category]
      advanced_grouping:
        mode: rollup
      aggregations:
        - column: amount
          function: SUM
          alias: total_sales
        - column: transaction_id
          function: COUNT
          alias: transaction_count
```

For more information, see:
- [Window Functions Guide](../guides/window-functions.md)
- [Performance Optimization Guide](../guides/performance-optimization.md)
- [Operators Reference](../operators/new-operators.md)
