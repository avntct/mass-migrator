# Performance Optimization Guide

This guide covers performance optimization techniques for Mass Migrator v3 pipelines.

## Table of Contents

1. [Memory Management](#memory-management)
2. [Parquet Optimization](#parquet-optimization)
3. [Query Optimization](#query-optimization)
4. [Parallel Processing](#parallel-processing)
5. [Best Practices](#best-practices)

---

## Memory Management

### Memory Enclaves

Mass Migrator v3 uses memory enclaves to limit memory usage per operation:

```yaml
steps:
  - name: memory_limited_sort
    type: sort
    input: large_dataset
    output: sorted_data
    memory_limit: 1GB  # Maximum memory for this step
    order_by:
      - column: timestamp
        ascending: false
```

### Configuring Memory Limits

Set memory limits at pipeline and step levels:

```yaml
pipeline:
  name: memory_optimized_pipeline
  memory_threshold_mb: 512  # Default for all steps

  steps:
    - name: step_1
      type: aggregate
      input: data
      output: result
      memory_limit: 2GB  # Override for this step
```

### Monitoring Memory Usage

Memory usage is tracked per dataset:

```yaml
steps:
  - name: check_memory
    type: check
    database: warehouse
    sql: "SELECT dataset_name, memory_bytes FROM system.datasets"
    condition: "memory_bytes < 1073741824"  # 1GB
    message: "Dataset exceeds memory limit"
```

### Spill-to-Disk Behavior

When operations exceed memory limits, data spills to disk:

**Automatic Spill Triggers:**
- Estimated output size > memory limit
- Memory guard exceeded during operation
- Partition count exceeds threshold

**Spill Configuration:**

```yaml
steps:
  - name: large_join
    type: setop
    operation: JOIN
    inputs: [left, right]
    join_keys: [id]
    output: result
    spill_threshold: 1000000  # Rows before spill
    spill_dir: /tmp/spill  # Spill location
```

### Best Practices for Memory-Intensive Operations

**1. Process in Batches:**

```yaml
# Bad: Load everything at once
steps:
  - name: load_all
    type: query
    database: warehouse
    sql: "SELECT * FROM huge_table"
    output: all_data

# Good: Process in partitions
steps:
  - name: load_partitioned
    type: query
    database: warehouse
    sql: "SELECT * FROM huge_table WHERE partition_key = :key"
    partition_by: partition_key
    partition_source_table: huge_table
    partition_source_column: partition_key
    threads: 8
    streaming: true
    output: partitioned_data
```

**2. Use Streaming Mode:**

```yaml
steps:
  - name: stream_processing
    type: query
    database: warehouse
    sql: "SELECT * FROM events WHERE event_date >= :start_date"
    partition_by: date_key
    threads: 4
    streaming: true  # Process each partition independently
    output: stream_output
```

**3. Enable Parquet Storage:**

```yaml
steps:
  - name: read_large_dataset
    type: query
    database: warehouse
    sql: "SELECT * FROM large_fact_table"
    output: large_data
    dataset_storage:
      strategy: parquet  # Use columnar storage
      compression: snappy
```

---

## Parquet Optimization

### When to Use Parquet Storage

**Use Parquet for:**
- Large datasets (>1M rows)
- Analytical queries (scan subset of columns)
- Intermediate datasets with multiple consumers
- Long-running pipelines with restarts

**Use Columnar (default) for:**
- Small datasets (<100K rows)
- Transform-heavy workloads
- Frequent row-level updates

### Predicate Pushdown

Parquet supports predicate pushdown to skip row groups:

```yaml
steps:
  - name: filtered_read
    type: read
    path: ./data/large_dataset.parquet
    format: parquet
    output: filtered_data

  - name: pushdown_filter
    type: filter
    input: filtered_data
    output: result
    expression: "year == 2024 AND month >= 6"
```

### Column Projection

Only read needed columns:

```yaml
steps:
  - name: project_columns
    type: project
    input: wide_parquet_dataset
    output: narrow_dataset
    columns: [id, name, amount]  # Only these columns loaded
```

### Row Group Sizing

Configure optimal row group size when writing:

```yaml
steps:
  - name: write_optimized_parquet
    type: write
    source: large_dataset
    path: ./output/data.parquet
    format: parquet
    row_group_size: 1000000  # 1M rows per group
    compression: snappy  # Fast compression
    threads: 4
```

**Row Group Guidelines:**
- Small (<100K): Too many groups, high metadata overhead
- Large (>10M): Poor predicate pushdown granularity
- Optimal: 500K - 2M rows per group

### Compression Options

```yaml
dataset_storage:
  strategy: parquet
  compression: snappy  # Options: snappy, gzip, zstd
```

| Compression | Speed | Ratio | Use Case |
|-------------|-------|-------|----------|
| **snappy** | Fast | Medium | Default, balanced |
| **gzip** | Slow | High | Archival, cold data |
| **zstd** | Medium | High | Good balance |

---

## Query Optimization

### Join Order Considerations

**Rule of thumb:** Join most restrictive filters first

```yaml
# Bad: Join everything then filter
steps:
  - name: join_all
    type: setop
    operation: JOIN
    inputs: [sales, customers, products, stores]
    join_keys: [customer_id, product_id, store_id]
    output: big_join

  - name: then_filter
    type: filter
    input: big_join
    expression: "region == 'WEST' AND category == 'ELECTRONICS'"
    output: result

# Good: Filter early, then join
steps:
  - name: filter_sales
    type: query
    database: warehouse
    sql: "SELECT * FROM sales WHERE region = 'WEST'"
    output: sales_filtered

  - name: filter_products
    type: query
    database: warehouse
    sql: "SELECT * FROM products WHERE category = 'ELECTRONICS'"
    output: products_filtered

  - name: join_filtered
    type: setop
    operation: JOIN
    inputs: [sales_filtered, products_filtered]
    join_keys: [product_id]
    output: result
```

### Broadcast vs Sort-Merge Joins

**Broadcast Hash Join:**
- One side fits in memory (<100M rows)
- Fast for dimension table joins
- Default behavior for small datasets

```yaml
steps:
  - name: broadcast_join
    type: setop
    operation: LOOKUP
    left:
      dataset: large_fact
      key: customer_id
    right:
      dataset: small_dimension  # <100K rows
      key: customer_id
    lookup_columns: [customer_name, segment]
    output: enriched
```

**Sort-Merge Join:**
- Both sides large
- Disk-based, slower but scalable
- Automatic fallback when memory exceeded

```yaml
steps:
  - name: large_join
    type: setop
    operation: JOIN
    inputs: [large_fact_1, large_fact_2]
    join_keys: [id]
    output: joined
    # Automatically uses sort-merge if datasets exceed memory
```

### Partitioning Strategies

**Hash Partitioning:**

```yaml
steps:
  - name: partitioned_read
    type: query
    database: warehouse
    sql: "SELECT * FROM transactions"
    partition_by_columns: [account_id, branch_id]  # Composite partition
    partition_source_table: transactions
    partition_source_columns: [account_id, branch_id]
    threads: 8
    streaming: true
    output: partitioned_data
```

**Partitioning Guidelines:**
- Use high-cardinality columns
- Uniform distribution (avoid skew)
- 2-4 threads per CPU core
- Match partition key to join keys

### Filtering Early

Push filters to data source:

```yaml
# Bad: Read all, filter in pipeline
steps:
  - name: read_all
    type: query
    database: warehouse
    sql: "SELECT * FROM sales"
    output: all_sales

  - name: filter_recent
    type: filter
    input: all_sales
    expression: "sale_date >= '2024-01-01'"
    output: recent_sales

# Good: Filter at source
steps:
  - name: read_recent
    type: query
    database: warehouse
    sql: "SELECT * FROM sales WHERE sale_date >= '2024-01-01'"
    output: recent_sales
```

### Minimizing Data Movement

Use dataset filters for cross-database joins:

```yaml
steps:
  - name: get_customer_ids
    type: query
    database: source_db
    sql: "SELECT DISTINCT customer_id FROM high_value_customers"
    output: customer_ids

  - name: filter_at_source
    type: query
    database: target_db
    sql: "SELECT * FROM orders WHERE customer_id IN (:customer_ids)"
    dataset_filter:
      source: customer_ids
      columns: [customer_id]
      chunk_size: 1000
      parallel_chunks: 4
    output: filtered_orders
```

---

## Parallel Processing

### Setting Thread Counts

```yaml
steps:
  - name: parallel_aggregate
    type: aggregate
    input: large_data
    output: aggregated
    group_by: [category]
    threads: 8  # Parallel worker threads
    aggregations:
      - column: amount
        function: SUM
        alias: total
```

**Thread Guidelines:**
- CPU-bound: 2-4 threads per core
- I/O-bound: 4-8 threads per core
- Default: 4 threads
- Maximum: Limited by GOMAXPROCS

### Worker Pool Configuration

```yaml
pipeline:
  name: high_concurrency_pipeline
  max_concurrent_jobs: 10  # Parallel step execution

  steps:
    - name: parallel_load
      type: load
      database: target
      dataset: data
      target_table: facts
      threads: 8  # Writer threads
      batch_size: 50000
```

### Backpressure Handling

Automatic backpressure prevents memory exhaustion:

```yaml
steps:
  - name: bounded_processing
    type: transform
    input: high_volume_stream
    output: processed_stream
    threads: 4
    queue_size: 10000  # Bounded queue
    script: |
      row.processed = process(row);
```

**Backpressure Tuning:**
- Small queue (1000): Low memory, high latency
- Large queue (100000): High memory, low latency
- Default: 10000

### Concurrency Limits

```yaml
pipeline:
  name: controlled_concurrency
  max_concurrent_jobs: 5  # Limit parallel steps
  job_timeout: 1h  # Per-step timeout

  steps:
    - name: step_1
      type: query
      # ...
      depends_on: []

    - name: step_2
      type: query
      # ...
      depends_on: [step_1]  # Serial dependency

    - name: step_3
      type: query
      # ...
      depends_on: [step_1]  # Runs parallel with step_2
```

---

## Best Practices

### 1. Pipeline Design Patterns

**Filter-Transform-Load Pattern:**

```yaml
pipeline:
  name: etl_pipeline
  steps:
    # Extract
    - name: extract
      type: query
      database: source
      sql: "SELECT * FROM source_table WHERE active = true"
      output: extracted

    # Transform
    - name: validate
      type: validate
      input: extracted
      rules:
        - column: id
          rule: not_null
      on_fail: filter
      output: valid_data

    - name: transform
      type: transform
      input: valid_data
      output: transformed
      script: |
        row.created_at = new Date(row.timestamp);
        row.amount = parseFloat(row.amount);

    # Load
    - name: load
      type: load
      database: target
      dataset: transformed
      target_table: target_table
      strategy: upsert
      key_columns: [id]
      threads: 8
```

**Star Schema Join Pattern:**

```yaml
pipeline:
  name: star_schema_join
  steps:
    - name: read_fact
      type: query
      database: warehouse
      sql: "SELECT * FROM sales_fact"
      output: fact

    - name: join_customer
      type: setop
      operation: LOOKUP
      left:
        dataset: fact
        key: customer_key
      right:
        dataset: customer_dim
        key: customer_key
      lookup_columns: [customer_name, segment]
      output: fact_with_customer

    - name: join_product
      type: setop
      operation: LOOKUP
      left:
        dataset: fact_with_customer
        key: product_key
      right:
        dataset: product_dim
        key: product_key
      lookup_columns: [product_name, category]
      output: fact_enriched

    - name: join_time
      type: setop
      operation: LOOKUP
      left:
        dataset: fact_enriched
        key: date_key
      right:
        dataset: time_dim
        key: date_key
      lookup_columns: [year, quarter, month]
      output: final_result
```

### 2. Anti-Patterns to Avoid

**Don't join everything then filter:**

```yaml
# Bad: Expensive join followed by filter
steps:
  - name: big_join
    type: setop
    operation: JOIN
    inputs: [fact, dim1, dim2, dim3]
    join_keys: [key1, key2, key3]
    output: joined_all

  - name: filter
    type: filter
    input: joined_all
    expression: "region == 'WEST'"
```

**Don't load all data into memory:**

```yaml
# Bad: 100M rows into memory
steps:
  - name: huge_query
    type: query
    database: warehouse
    sql: "SELECT * FROM billion_row_table"
    output: all_data

# Good: Process in partitions
steps:
  - name: partitioned_query
    type: query
    database: warehouse
    sql: "SELECT * FROM billion_row_table"
    partition_by: date_key
    threads: 8
    streaming: true
    output: stream_data
```

**Don't use cross joins carelessly:**

```yaml
# Very bad: 1M × 1M = 1 trillion rows
steps:
  - name: accidental_cartesian
    type: setop
    operation: CROSS_JOIN
    inputs: [large_1, large_2]
    output: disaster

# Good: Filter first or use INNER JOIN
steps:
  - name: filtered_join
    type: setop
    operation: JOIN
    inputs: [filtered_1, filtered_2]
    join_keys: [id]
    output: reasonable_result
```

### 3. Monitoring and Profiling

Add performance checkpoints:

```yaml
pipeline:
  name: monitored_pipeline
  steps:
    - name: start_timer
      type: vars
      variables:
        start_time: "=NOW()"

    - name: process_data
      type: transform
      # ... transformation logic ...

    - name: check_progress
      type: check
      database: warehouse
      sql: "SELECT COUNT(*) as row_count FROM processed_table"
      condition: "row_count > 0"
      message: "No rows processed"

    - name: log_duration
      type: transform
      input: dummy
      output: metrics
      script: |
        log('Pipeline duration: ' + (NOW() - variables.start_time) + 'ms');
```

### 4. Performance Testing

Use sample data for development:

```yaml
pipeline:
  name: dev_pipeline
  steps:
    - name: sample_data
      type: sample
      dataset: full_production_data
      rate: 0.01  # 1% sample
      seed: 42  # Reproducible
      output: dev_data

    - name: develop_transform
      type: transform
      input: dev_data
      output: transformed
      # ... develop and test ...
```

Then scale to production:

```yaml
pipeline:
  name: prod_pipeline
  steps:
    - name: full_data
      type: query
      database: warehouse
      sql: "SELECT * FROM production_table"
      output: all_data

    - name: production_transform
      type: transform
      input: all_data
      output: transformed
      threads: 16  # Scale up threads
      # ... same transform logic ...
```

---

## Performance Checklist

- [ ] Filter early (push predicates to source)
- [ ] Use Parquet storage for large datasets
- [ ] Set appropriate thread counts
- [ ] Configure memory limits
- [ ] Use streaming mode for large queries
- [ ] Partition by join keys
- [ ] Add performance checkpoints
- [ ] Test with sample data first
- [ ] Monitor memory usage
- [ ] Use appropriate join strategies
- [ ] Optimize row group sizes for Parquet
- [ ] Enable compression for cold data
- [ ] Avoid Cartesian products
- [ ] Use LOOKUP for dimension joins
- [ ] Set queue sizes for backpressure

For more information, see:
- [Operators Reference](../operators/new-operators.md)
- [Window Functions Guide](./window-functions.md)
- [Configuration Reference](../reference/configuration.md)
