# Window Functions Guide

This guide explains how to use window functions in Mass Migrator v3 for advanced analytics.

## Table of Contents

1. [Introduction](#introduction)
2. [Frame Specifications](#frame-specifications)
3. [Window Function Types](#window-function-types)
4. [Common Patterns](#common-patterns)
5. [Performance Considerations](#performance-considerations)

---

## Introduction

### What are Window Functions?

Window functions perform calculations across rows related to the current row, without collapsing rows like aggregate functions.

**Key Differences:**

| Feature | Aggregate Functions | Window Functions |
|---------|-------------------|------------------|
| Rows collapse | Yes (1 row per group) | No (all rows preserved) |
| Use case | Totals, counts per group | Rankings, running totals, comparisons |
| Example | `SUM(amount) BY category` | `SUM(amount) OVER (PARTITION BY category)` |

### Basic Syntax

```yaml
steps:
  - name: add_window_column
    type: window
    dataset: input_data
    output: with_window
    function: rowNumber  # rank, denseRank, lag, lead
    partition_by: [category_column]
    order_by:
      - column: sort_column
        ascending: true
    offset: 1  # For LEAD/LAG only
    default: null  # For LEAD/LAG only
```

### Output Columns

Window functions add a new column to the dataset:

| Function | Output Column Name | Description |
|----------|-------------------|-------------|
| rowNumber | `_row_number` | Sequential 1, 2, 3, ... |
| rank | `_rank` | Rank with ties (1, 2, 2, 4, ...) |
| denseRank | `_dense_rank` | Rank without gaps (1, 2, 2, 3, ...) |
| lag | `<column>_lag` or custom | Value from previous row |
| lead | `<column>_lead` or custom | Value from next row |

---

## Frame Specifications

### Current Implementation

Currently, Mass Migrator v3 supports:

- **Partitioning:** Group rows into windows
- **Ordering:** Sort rows within partitions
- **Offset:** For LEAD/LAG functions

### ROWS vs RANGE

**Current Status:** Full frame specification (ROWS BETWEEN, RANGE BETWEEN) is planned for a future release.

**Workaround:** Use transform step for frame-based calculations:

```yaml
steps:
  - name: sort_data
    type: sort
    input: sales
    output: sorted_sales
    order_by:
      - column: sale_date
        ascending: true

  - name: calculate_moving_avg
    type: transform
    input: sorted_sales
    output: with_moving_avg
    script: |
      // Manual moving average calculation
      // (Future version will use frame specification)
      var window = [];
      var windowSize = 7;

      // This is a simplified example
      // Real implementation would need state management
      row.moving_avg = calculateMovingAverage(row, window, windowSize);
```

### Window Frame Boundaries

**Planned Syntax (Future Release):**

```yaml
steps:
  - name: window_with_frame
    type: window
    dataset: sales
    output: with_running_total
    function: SUM
    partition_by: [region]
    order_by:
      - column: sale_date
        ascending: true
    frame:
      mode: ROWS  # or RANGE
      start: UNBOUNDED_PRECEDING  # or N_PRECEDING, CURRENT_ROW
      end: CURRENT_ROW  # or N_FOLLOWING, UNBOUNDED_FOLLOWING
```

---

## Window Function Types

### 1. ROW_NUMBER

Assigns a unique sequential number to each row.

```yaml
pipeline:
  name: row_number_example
  steps:
    - name: read_sales
      type: query
      database: warehouse
      sql: "SELECT * FROM sales ORDER BY sale_date DESC"
      output: sales

    - name: add_row_number
      type: window
      dataset: sales
      output: numbered_sales
      function: rowNumber
      partition_by: [customer_id]
      order_by:
        - column: sale_date
          ascending: false
```

**Use Cases:**
- Deduplication (keep first/last row)
- Pagination
- Finding Nth row per group
- Identifying specific rows

**Example: Keep Only Latest Record**

```yaml
steps:
  - name: number_records
    type: window
    dataset: duplicates
    output: numbered
    function: rowNumber
    partition_by: [customer_id, product_id]
    order_by:
      - column: updated_at
        ascending: false

  - name: keep_latest
    type: filter
    input: numbered
    output: unique_records
    expression: "_row_number == 1"
```

### 2. RANK

Assigns rank with ties (gaps in numbering).

```yaml
steps:
  - name: rank_sales
    type: window
    dataset: customer_spend
    output: ranked_customers
    function: rank
    partition_by: [region]
    order_by:
      - column: total_spent
        ascending: false
```

**Output Example:**

```
customer_id | total_spent | region | _rank
------------|-------------|--------|-------
C001        | 10000       | WEST   | 1
C002        | 9500        | WEST   | 2
C003        | 9500        | WEST   | 2  # Tie
C004        | 8000        | WEST   | 4  # Gap after tie
C005        | 7500        | WEST   | 5
```

**Use Cases:**
- Competition rankings
- Top N with ties
- Sales leaderboards
- Performance rankings

### 3. DENSE_RANK

Assigns rank without gaps (no gaps in numbering).

```yaml
steps:
  - name: dense_rank_sales
    type: window
    dataset: customer_spend
    output: dense_ranked
    function: denseRank
    partition_by: [region]
    order_by:
      - column: total_spent
        ascending: false
```

**Output Example:**

```
customer_id | total_spent | region | _dense_rank
------------|-------------|--------|-------------
C001        | 10000       | WEST   | 1
C002        | 9500        | WEST   | 2
C003        | 9500        | WEST   | 2  # Tie
C004        | 8000        | WEST   | 3  # No gap
C005        | 7500        | WEST   | 4
```

**Use Cases:**
- Dense rankings
- Percentile calculations
- Tier assignments
- Grade assignments

**Example: Assign Customer Tiers**

```yaml
steps:
  - name: rank_by_spend
    type: window
    dataset: customer_totals
    output: ranked
    function: denseRank
    order_by:
      - column: total_spent
        ascending: true

  - name: assign_tiers
    type: transform
    input: ranked
    output: with_tiers
    script: |
      if (row._dense_rank <= 10) {
        row.tier = 'PLATINUM';
      } else if (row._dense_rank <= 50) {
        row.tier = 'GOLD';
      } else if (row._dense_rank <= 200) {
        row.tier = 'SILVER';
      } else {
        row.tier = 'BRONZE';
      }
```

### 4. LAG

Access value from previous row.

```yaml
steps:
  - name: add_lag
    type: window
    dataset: monthly_sales
    output: with_lag
    function: lag
    partition_by: [product_id]
    order_by:
      - column: month
        ascending: true
    offset: 1  # Look back 1 row
    default: 0  # Default for first row
```

**Use Cases:**
- Period-over-period comparison
- Growth rate calculation
- Anomaly detection
- Trend analysis

**Example: Month-Over-Month Growth**

```yaml
pipeline:
  name: mom_analysis
  steps:
    - name: monthly_sales
      type: aggregate
      input: sales
      output: monthly_totals
      group_by: [product_id, year, month]
      aggregations:
        - column: amount
          function: SUM
          alias: monthly_sales

    - name: add_previous_month
      type: window
      dataset: monthly_totals
      output: with_prev
      function: lag
      partition_by: [product_id]
      order_by:
        - column: year
          ascending: true
        - column: month
          ascending: true
      offset: 1
      default: 0

    - name: calculate_growth
      type: transform
      input: with_prev
      output: growth_rates
      script: |
        var current = row.monthly_sales;
        var previous = row.monthly_sales_lag || 0;
        var growth = 0;

        if (previous > 0) {
          growth = ((current - previous) / previous) * 100;
        }

        row.mom_growth_pct = growth;
        row.abs_change = current - previous;
```

**Example: Compare with Same Period Last Year**

```yaml
steps:
  - name: add_year_lag
    type: window
    dataset: monthly_data
    output: with_yoy
    function: lag
    partition_by: [product_id, month]  # Same month
    order_by:
      - column: year
        ascending: true
    offset: 1  # Previous year
    default: null

  - name: calculate_yoy
    type: transform
    input: with_yoy
    output: yoy_growth
    script: |
      var current = row.sales;
      var last_year = row.sales_lag || 0;
      var yoy = 0;

      if (last_year > 0) {
        yoy = ((current - last_year) / last_year) * 100;
      }

      row.yoy_growth_pct = yoy;
```

### 5. LEAD

Access value from next row.

```yaml
steps:
  - name: add_lead
    type: window
    dataset: events
    output: with_lead
    function: lead
    partition_by: [session_id]
    order_by:
      - column: event_time
        ascending: true
    offset: 1  # Look ahead 1 row
    default: null  # Default for last row
```

**Use Cases:**
- Time between events
- Next event prediction
- Session analysis
- Gap detection

**Example: Time to Next Event**

```yaml
pipeline:
  name: event_analysis
  steps:
    - name: read_events
      type: query
      database: analytics
      sql: |
        SELECT
          session_id,
          event_time,
          event_type
        FROM events
        ORDER BY session_id, event_time
      output: events

    - name: add_next_event
      type: window
      dataset: events
      output: with_next
      function: lead
      partition_by: [session_id]
      order_by:
        - column: event_time
          ascending: true
      offset: 1
      default: null

    - name: calculate_gap
      type: transform
      input: with_next
      output: event_gaps
      script: |
        if (row.event_time_lag != null) {
          var gap = row.event_time_lag - row.event_time;
          row.time_to_next_ms = gap;
        } else {
          row.time_to_next_ms = null;  // Last event in session
        }

        // Flag long gaps (>5 minutes)
        if (row.time_to_next_ms > 300000) {
          row.is_session_end = true;
        }
```

**Example: Identify Missing Values**

```yaml
steps:
  - name: detect_gaps
    type: transform
    input: with_lead
    output: gaps
    script: |
      var current = row.sequence_number;
      var next = row.sequence_number_lead;

      if (next != null && next != current + 1) {
        row.is_missing = true;
        row.missing_count = next - current - 1;
      } else {
        row.is_missing = false;
        row.missing_count = 0;
      }
```

---

## Common Patterns

### Running Total

```yaml
pipeline:
  name: running_total
  steps:
    - name: daily_sales
      type: aggregate
      input: sales
      output: daily
      group_by: [sale_date]
      aggregations:
        - column: amount
          function: SUM
          alias: daily_amount

    - name: sort_by_date
      type: sort
      input: daily
      output: sorted
      order_by:
        - column: sale_date
          ascending: true

    - name: calculate_running_total
      type: transform
      input: sorted
      output: with_running_total
      script: |
        // Manual running total (future version will use frame)
        if (!variables.running_total) {
          variables.running_total = 0;
        }
        variables.running_total += row.daily_amount;
        row.running_total = variables.running_total;
```

### Moving Average

```yaml
pipeline:
  name: moving_average
  steps:
    - name: prepare_data
      type: sort
      input: sales
      output: sorted_sales
      order_by:
        - column: sale_date
          ascending: true

    - name: calculate_ma
      type: transform
      input: sorted_sales
      output: with_ma
      script: |
        // 7-day moving average
        // (Simplified - real implementation needs sliding window)
        var windowSize = 7;
        // ... implementation ...
        row.moving_avg_7d = calculateMA(row, windowSize);
```

### Percentile Rank

```yaml
steps:
  - name: calculate_percentile
    type: window
    dataset: scores
    output: with_rank
    function: percent_rank  # Planned feature
    partition_by: [exam_id]
    order_by:
      - column: score
        ascending: true

  - name: assign_percentile
    type: transform
    input: with_rank
    output: final
    script: |
      row.percentile = row._percent_rank * 100;
```

### First/Last Value per Group

```yaml
steps:
  - name: first_value
    type: window
    dataset: events
    output: with_first
    function: first_value  # Planned feature
    partition_by: [user_id]
    order_by:
      - column: event_time
        ascending: true

  - name: last_value
    type: window
    dataset: events
    output: with_last
    function: last_value  # Planned feature
    partition_by: [user_id]
    order_by:
      - column: event_time
        ascending: false
```

---

## Performance Considerations

### Memory Usage

Window functions require loading entire partitions into memory:

```yaml
# Low memory - small partitions
steps:
  - name: rank_by_customer
    type: window
    dataset: orders
    output: ranked
    function: rank
    partition_by: [customer_id]  # Many small partitions
    order_by:
      - column: order_date
        ascending: false

# High memory - large partitions
steps:
  - name: rank_all
    type: window
    dataset: orders
    output: ranked
    function: rank
    # No partition - entire dataset in memory
    order_by:
      - column: order_date
        ascending: false
```

**Memory Guidelines:**
- Use partitions to limit memory
- Monitor partition sizes
- Consider spill-to-disk for large partitions
- Use sort step before window function for efficiency

### Optimization Tips

**1. Sort Before Window Function:**

```yaml
# Good: Pre-sorted data
steps:
  - name: sort_first
    type: sort
    input: data
    output: sorted
    order_by:
      - column: category
        ascending: true
      - column: value
        ascending: false

  - name: then_window
    type: window
    dataset: sorted
    output: with_window
    function: rank
    partition_by: [category]
    order_by:
      - column: value
        ascending: false
```

**2. Use Smaller Partitions:**

```yaml
# Bad: One giant partition
steps:
  - name: global_ranking
    type: window
    dataset: all_data
    function: rank
    order_by:
      - column: score
        ascending: false

# Good: Partitioned by region
steps:
  - name: regional_ranking
    type: window
    dataset: all_data
    function: rank
    partition_by: [region]  # Smaller partitions
    order_by:
      - column: score
        ascending: false
```

**3. Filter Unnecessary Rows:**

```yaml
steps:
  - name: filter_first
    type: filter
    input: all_sales
    output: recent_sales
    expression: "sale_date >= '2024-01-01'"

  - name: then_rank
    type: window
    dataset: recent_sales
    output: ranked
    function: rank
    partition_by: [product_id]
    order_by:
      - column: amount
        ascending: false
```

### Partition Size Estimation

```yaml
steps:
  - name: check_partition_size
    type: check
    database: warehouse
    sql: |
      SELECT
        partition_column,
        COUNT(*) as row_count
      FROM table_name
      GROUP BY partition_column
      ORDER BY row_count DESC
      LIMIT 10
    condition: "row_count < 1000000"  # <1M per partition
    message: "Partition too large for window function"
```

---

## Complete Example: Customer Analytics Dashboard

```yaml
pipeline:
  name: customer_analytics
  databases:
    warehouse:
      url: "postgresql://warehouse:5432/analytics"
      username: "user"
      password: "pass"
      type: postgresql

  steps:
    # 1. Calculate customer spend
    - name: customer_totals
      type: aggregate
      input: sales
      output: customer_spend
      group_by: [customer_id, customer_name, region]
      aggregations:
        - column: amount
          function: SUM
          alias: total_spent
        - column: order_id
          function: COUNT
          alias: order_count

    # 2. Rank customers within regions
    - name: rank_customers
      type: window
      dataset: customer_spend
      output: ranked_customers
      function: rank
      partition_by: [region]
      order_by:
        - column: total_spent
          ascending: false

    # 3. Add percentiles
    - name: calculate_percentiles
      type: transform
      input: ranked_customers
      output: with_percentiles
      script: |
        // Estimate percentile based on rank
        var totalCustomers = 1000; // Would need to be computed
        row.percentile_rank = (totalCustomers - row._rank + 1) / totalCustomers * 100;

    # 4. Assign segments
    - name: assign_segments
      type: transform
      input: with_percentiles
      output: segmented_customers
      script: |
        if (row.percentile_rank >= 95) {
          row.segment = 'VIP';
          row.benefits = ['priority_support', 'free_shipping', 'exclusive_deals'];
        } else if (row.percentile_rank >= 75) {
          row.segment = 'GOLD';
          row.benefits = ['priority_support', 'free_shipping'];
        } else if (row.percentile_rank >= 50) {
          row.segment = 'SILVER';
          row.benefits = ['free_shipping'];
        } else {
          row.segment = 'STANDARD';
          row.benefits = [];
        }

    # 5. Calculate customer lifetime value
    - name: monthly_history
      type: aggregate
      input: sales
      output: monthly_sales
      group_by: [customer_id, year, month]
      aggregations:
        - column: amount
          function: SUM
          alias: monthly_spend

    - name: add_prev_month
      type: window
      dataset: monthly_sales
      output: with_lag
      function: lag
      partition_by: [customer_id]
      order_by:
        - column: year
          ascending: true
        - column: month
          ascending: true
      offset: 1
      default: 0

    - name: calculate_trend
      type: transform
      input: with_lag
      output: customer_trends
      script: |
        var current = row.monthly_spend;
        var previous = row.monthly_spend_lag || 0;
        var trend = 'stable';

        if (previous > 0) {
          var change = ((current - previous) / previous) * 100;
          if (change > 20) {
            trend = 'growing';
          } else if (change < -20) {
            trend = 'declining';
          }
        }
        row.spend_trend = trend;

    # 6. Combine analytics
    - name: merge_analytics
      type: setop
      operation: LOOKUP
      left:
        dataset: segmented_customers
        key: customer_id
      right:
        dataset: customer_trends
        key: customer_id
      lookup_columns: [spend_trend, monthly_spend]
      output: final_analytics

    # 7. Write results
    - name: write_dashboard_data
      type: write
      source: final_analytics
      path: ./output/customer_analytics.parquet
      format: parquet
```

---

## Future Enhancements

Planned features for future releases:

1. **Window Frames:**
   ```yaml
   frame:
     mode: ROWS
     start: 6_PRECEDING
     end: CURRENT_ROW
   ```

2. **Window Aggregates:**
   - SUM OVER, AVG OVER, COUNT OVER
   - MIN OVER, MAX OVER
   - Running totals, moving averages

3. **Advanced Functions:**
   - FIRST_VALUE, LAST_VALUE
   - NTH_VALUE
   - NTILE (percentile buckets)

4. **Frame Modes:**
   - ROWS (physical offsets)
   - RANGE (logical offsets)
   - GROUPS (group-based)

For current capabilities, see [Operators Reference](../operators/new-operators.md).
