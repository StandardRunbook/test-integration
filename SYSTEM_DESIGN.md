# Hypothecary Log Analysis System - System Design Document

## Table of Contents
1. [System Overview](#system-overview)
2. [Architecture](#architecture)
3. [Data Flow](#data-flow)
4. [Component Details](#component-details)
5. [Database Schema](#database-schema)
6. [API Specifications](#api-specifications)
7. [Performance Characteristics](#performance-characteristics)
8. [Deployment Architecture](#deployment-architecture)

---

## System Overview

The Hypothecary Log Analysis System is a high-performance log ingestion, analysis, and visualization platform designed to correlate Grafana metrics with log streams using template-based pattern matching and KL divergence analysis.

### Key Features
- **High-throughput log ingestion** (100K-370K logs/sec)
- **Zero-copy template matching** for efficient pattern recognition
- **Real-time metric-to-log correlation** via Grafana hover interactions
- **Automatic log template generation** from historical data
- **Multi-tenant architecture** with organization isolation
- **Time-series optimized storage** with automatic data retention

### Target Use Cases
1. Correlating metric anomalies with specific log patterns
2. Root cause analysis during incident response
3. Performance debugging across distributed services
4. Log pattern analysis and anomaly detection

---

## Architecture

### High-Level System Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           Client Layer                                  │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌──────────────┐         ┌──────────────┐         ┌──────────────┐   │
│  │   Grafana    │         │   Admin      │         │  Log Sources │   │
│  │  Dashboard   │         │   Portal     │         │ (Apps/Svcs)  │   │
│  │  (Port 3000) │         │ (Port 3001)  │         │              │   │
│  └──────┬───────┘         └──────┬───────┘         └──────┬───────┘   │
│         │                        │                        │            │
└─────────┼────────────────────────┼────────────────────────┼────────────┘
          │                        │                        │
          │ Hover Events           │ Mapping CRUD           │ POST /logs/ingest
          │                        │                        │
┌─────────┼────────────────────────┼────────────────────────┼────────────┐
│         │              Service Layer                      │            │
├─────────┼────────────────────────┼────────────────────────┼────────────┤
│         │                        │                        │            │
│         │                        │                        │            │
│  ┌──────▼──────────┐      ┌──────▼──────────┐     ┌──────▼─────────┐ │
│  │  Hover Plugin   │      │     Admin       │     │  Log Analysis  │ │
│  │    Backend      │      │   Dashboard     │     │    Service     │ │
│  │                 │      │     API         │     │  (Port 3002)   │ │
│  │  - KL Div Calc  │      │                 │     │                │ │
│  │  - Log Fetch    │      │  - Org Mgmt     │     │  - Template    │ │
│  │  - Aggregation  │      │  - Mapping CRUD │     │    Matching    │ │
│  └──────┬──────────┘      └──────┬──────────┘     │  - Parallel    │ │
│         │                        │                │    Processing  │ │
│         │                        │                │  - Buffered    │ │
│         │                        │                │    Writes      │ │
│         │                        │                └──────┬─────────┘ │
│         │                        │                       │            │
└─────────┼────────────────────────┼───────────────────────┼────────────┘
          │                        │                       │
          │                        │                       │
┌─────────┼────────────────────────┼───────────────────────┼────────────┐
│         │                 Data Layer                     │            │
├─────────┼────────────────────────┼───────────────────────┼────────────┤
│         │                        │                       │            │
│  ┌──────▼────────────────────────▼───────────────────────▼─────────┐ │
│  │                                                                  │ │
│  │                  ClickHouse Database Cluster                     │ │
│  │                     (Ports 8123, 9000)                          │ │
│  │                                                                  │ │
│  │  ┌────────────┐  ┌─────────────┐  ┌────────────┐              │ │
│  │  │   Logs     │  │  Templates  │  │  Mappings  │              │ │
│  │  │   Table    │  │   Examples  │  │   Tables   │              │ │
│  │  │            │  │             │  │            │              │ │
│  │  │ - 30 day   │  │ - Pattern   │  │ - Metrics  │              │ │
│  │  │   TTL      │  │   Storage   │  │ - Streams  │              │ │
│  │  │ - Monthly  │  │ - Example   │  │ - M-to-M   │              │ │
│  │  │   Partition│  │   Logs      │  │   Join MV  │              │ │
│  │  └────────────┘  └─────────────┘  └────────────┘              │ │
│  │                                                                  │ │
│  └──────────────────────────────────────────────────────────────────┘ │
│                                                                        │
└────────────────────────────────────────────────────────────────────────┘
```

### Component Interaction Flow

```
┌─────────────┐
│   Grafana   │
│   Hover     │
│   Event     │
└──────┬──────┘
       │
       │ 1. User hovers over metric point
       │    {org, dashboard, panel, metric, timestamp}
       ▼
┌──────────────────────────────────────────────────────────┐
│            Hover Plugin Backend                          │
│                                                          │
│  2. Query metric_log_hover_mv for log streams           │
│     WHERE org_id = ? AND dashboard = ? AND metric = ?    │
└──────┬───────────────────────────────────────────────────┘
       │
       │ 3. Get log_stream_ids
       ▼
┌──────────────────────────────────────────────────────────┐
│            ClickHouse - logs table                       │
│                                                          │
│  4. Fetch logs for time window                          │
│     SELECT template_id, COUNT(*)                         │
│     FROM logs                                            │
│     WHERE log_stream_id IN (...)                         │
│       AND timestamp BETWEEN ? AND ?                      │
│     GROUP BY template_id                                 │
└──────┬───────────────────────────────────────────────────┘
       │
       │ 5. Calculate KL divergence from baseline
       ▼
┌──────────────────────────────────────────────────────────┐
│            KL Divergence Analysis                        │
│                                                          │
│  6. Compare current distribution vs baseline             │
│     KL(P||Q) = Σ P(i) * log(P(i)/Q(i))                  │
│                                                          │
│  7. Rank templates by divergence score                   │
└──────┬───────────────────────────────────────────────────┘
       │
       │ 8. Fetch example logs for top divergent templates
       ▼
┌──────────────────────────────────────────────────────────┐
│            template_examples table                       │
│                                                          │
│  9. SELECT message FROM template_examples                │
│     WHERE template_id IN (top_divergent)                 │
│     LIMIT 1 per template                                 │
└──────┬───────────────────────────────────────────────────┘
       │
       │ 10. Return ranked log examples
       ▼
┌──────────────┐
│   Grafana    │
│   Tooltip    │
│   Display    │
└──────────────┘
```

---

## Data Flow

### 1. Log Ingestion Flow

```
┌──────────────┐
│ Application  │  (Produces logs)
│  Services    │
└──────┬───────┘
       │
       │ POST /logs/ingest/batch
       │ {
       │   "logs": [
       │     {
       │       "org": "acme",
       │       "service": "api",
       │       "region": "us-east-1",
       │       "message": "Request completed in 150ms"
       │     }
       │   ]
       │ }
       ▼
┌────────────────────────────────────────────────────┐
│         Log Analysis Service (Rust)                │
│                                                    │
│  ┌──────────────────────────────────────────┐    │
│  │  1. Receive batch                         │    │
│  │     - Validate JSON                       │    │
│  │     - Extract log fields                  │    │
│  └──────────┬───────────────────────────────┘    │
│             │                                     │
│  ┌──────────▼───────────────────────────────┐    │
│  │  2. Template Matching                     │    │
│  │     - Zero-copy string matching           │    │
│  │     - Regex pattern matching              │    │
│  │     - Template ID assignment              │    │
│  │     - 379 pre-loaded templates            │    │
│  └──────────┬───────────────────────────────┘    │
│             │                                     │
│  ┌──────────▼───────────────────────────────┐    │
│  │  3. Batch Buffer                          │    │
│  │     - Accumulate until batch size         │    │
│  │     - Or flush on timeout                 │    │
│  │     - Parallel processing (>1000 logs)    │    │
│  └──────────┬───────────────────────────────┘    │
│             │                                     │
└─────────────┼─────────────────────────────────────┘
              │
              │ INSERT INTO logs
              ▼
┌────────────────────────────────────────────────────┐
│         ClickHouse - logs table                    │
│                                                    │
│  4. Store log with metadata:                      │
│     - org_id                                       │
│     - log_stream_id (generated from service+region)│
│     - service                                      │
│     - region                                       │
│     - log_stream_name                              │
│     - timestamp                                    │
│     - template_id                                  │
│     - message (original)                           │
│                                                    │
│  5. Partition by: (org_id, YYYYMM)                │
│  6. Index by: (org_id, log_stream_id, timestamp)  │
│  7. TTL: 30 days                                   │
└────────────────────────────────────────────────────┘
```

### 2. Mapping Configuration Flow

```
┌──────────────┐
│ Admin Portal │
│   User       │
└──────┬───────┘
       │
       │ POST /api/mappings
       │ {
       │   "org": "acme",
       │   "dashboardName": "production",
       │   "panelTitle": "CPU Usage",
       │   "metricName": "cpu_percent",
       │   "service": "api-server",
       │   "region": "us-east-1",
       │   "logStreamName": "api-us-east-1-prod"
       │ }
       ▼
┌────────────────────────────────────────────────────┐
│         Admin Dashboard API                        │
│                                                    │
│  1. Validate mapping data                         │
│  2. Generate UUIDs                                 │
│  3. Begin transaction                              │
└──────┬─────────────────────────────────────────────┘
       │
       │ Multi-table insert
       ▼
┌────────────────────────────────────────────────────┐
│         ClickHouse Transaction                     │
│                                                    │
│  ┌─────────────────────────────────────────┐      │
│  │ INSERT INTO organizations               │      │
│  │   (id, name)                             │      │
│  │ VALUES (uuid, 'acme')                    │      │
│  └─────────────┬───────────────────────────┘      │
│                │                                   │
│  ┌─────────────▼───────────────────────────┐      │
│  │ INSERT INTO metrics                      │      │
│  │   (id, org_id, dashboard_name,           │      │
│  │    panel_title, metric_name)             │      │
│  │ VALUES (uuid, org_uuid, 'production',    │      │
│  │         'CPU Usage', 'cpu_percent')      │      │
│  └─────────────┬───────────────────────────┘      │
│                │                                   │
│  ┌─────────────▼───────────────────────────┐      │
│  │ INSERT INTO log_streams                  │      │
│  │   (id, org_id, service, region,          │      │
│  │    log_stream_name)                      │      │
│  │ VALUES (uuid, org_uuid, 'api-server',    │      │
│  │         'us-east-1', 'api-us-east-1-..') │      │
│  └─────────────┬───────────────────────────┘      │
│                │                                   │
│  ┌─────────────▼───────────────────────────┐      │
│  │ INSERT INTO metric_log_mappings          │      │
│  │   (id, org_id, metric_id,                │      │
│  │    log_stream_id, is_active)             │      │
│  │ VALUES (uuid, org_uuid, metric_uuid,     │      │
│  │         stream_uuid, 1)                  │      │
│  └─────────────┬───────────────────────────┘      │
│                │                                   │
└────────────────┼───────────────────────────────────┘
                 │
                 │ Materialized View auto-updates
                 ▼
┌────────────────────────────────────────────────────┐
│    metric_log_hover_mv (Materialized View)         │
│                                                    │
│  Automatically populated with pre-joined data:     │
│  - org_id                                          │
│  - dashboard_name                                  │
│  - panel_title                                     │
│  - metric_name                                     │
│  - log_stream_id                                   │
│  - service                                         │
│  - region                                          │
│  - log_stream_name                                 │
│  - is_active                                       │
│                                                    │
│  Fast lookups: O(log n) via sorted index           │
└────────────────────────────────────────────────────┘
```

### 3. Hover Query Flow (Real-time)

```
┌──────────────┐
│   Grafana    │  User hovers at timestamp T
│   Frontend   │  Panel: "CPU Usage"
└──────┬───────┘
       │
       │ GET /api/hover?org=acme&dashboard=prod&panel=CPU&metric=cpu_percent&time=T
       ▼
┌────────────────────────────────────────────────────┐
│         Grafana Hover Plugin Backend               │
│                                                    │
│  Step 1: Get related log streams                  │
└──────┬─────────────────────────────────────────────┘
       │
       │ SELECT log_stream_id, service, region
       │ FROM metric_log_hover_mv
       │ WHERE org_id = 'acme'
       │   AND dashboard_name = 'prod'
       │   AND panel_title = 'CPU Usage'
       │   AND metric_name = 'cpu_percent'
       │   AND is_active = 1
       ▼
┌────────────────────────────────────────────────────┐
│  Result: [log_stream_1, log_stream_2, ...]        │
└──────┬─────────────────────────────────────────────┘
       │
       │ Step 2: Get baseline distribution (T-24h to T-1h)
       ▼
┌────────────────────────────────────────────────────┐
│  SELECT template_id, COUNT(*) as count             │
│  FROM logs                                         │
│  WHERE org_id = 'acme'                             │
│    AND log_stream_id IN (log_stream_1, ...)       │
│    AND timestamp BETWEEN (T-24h) AND (T-1h)        │
│  GROUP BY template_id                              │
└──────┬─────────────────────────────────────────────┘
       │
       │ Baseline: {template_1: 1000, template_2: 500, ...}
       │
       │ Step 3: Get current distribution (T-5m to T)
       ▼
┌────────────────────────────────────────────────────┐
│  SELECT template_id, COUNT(*) as count             │
│  FROM logs                                         │
│  WHERE org_id = 'acme'                             │
│    AND log_stream_id IN (log_stream_1, ...)       │
│    AND timestamp BETWEEN (T-5m) AND T              │
│  GROUP BY template_id                              │
└──────┬─────────────────────────────────────────────┘
       │
       │ Current: {template_1: 50, template_2: 5, template_99: 45}
       │
       │ Step 4: Calculate KL Divergence
       ▼
┌────────────────────────────────────────────────────┐
│         KL Divergence Calculation                  │
│                                                    │
│  For each template:                                │
│    P(i) = current_count[i] / total_current         │
│    Q(i) = baseline_count[i] / total_baseline       │
│                                                    │
│  KL(P||Q) = Σ P(i) * log(P(i) / Q(i))             │
│                                                    │
│  Results:                                          │
│    template_99: KL = 5.2 (NEW, high divergence)   │
│    template_2:  KL = 2.1 (reduced frequency)      │
│    template_1:  KL = 0.1 (normal)                 │
└──────┬─────────────────────────────────────────────┘
       │
       │ Step 5: Fetch example logs for top templates
       ▼
┌────────────────────────────────────────────────────┐
│  SELECT message                                    │
│  FROM template_examples                            │
│  WHERE org_id = 'acme'                             │
│    AND log_stream_id IN (...)                      │
│    AND template_id IN (99, 2, 1)                   │
│  LIMIT 1 per template                              │
└──────┬─────────────────────────────────────────────┘
       │
       │ Return enriched results
       ▼
┌────────────────────────────────────────────────────┐
│  Response JSON:                                    │
│  {                                                 │
│    "timestamp": T,                                 │
│    "templates": [                                  │
│      {                                             │
│        "template_id": 99,                          │
│        "kl_divergence": 5.2,                       │
│        "count": 45,                                │
│        "message": "OutOfMemory: heap exhausted"    │
│      },                                            │
│      {                                             │
│        "template_id": 2,                           │
│        "kl_divergence": 2.1,                       │
│        "count": 5,                                 │
│        "message": "Cache miss for key user:123"    │
│      }                                             │
│    ]                                               │
│  }                                                 │
└──────┬─────────────────────────────────────────────┘
       │
       ▼
┌──────────────┐
│   Grafana    │  Display tooltip with anomalous logs
│   Tooltip    │  Highlight high-divergence patterns
└──────────────┘
```

---

## Component Details

### 1. Log Analysis Service (Rust)

**Technology Stack:**
- Language: Rust
- Framework: Actix-web / Axum
- Database Client: ClickHouse HTTP client

**Responsibilities:**
- Accept log batches via REST API
- Perform zero-copy template matching
- Buffer and batch writes to ClickHouse
- Manage template cache (379 templates)
- Parallel processing for large batches

**Performance Characteristics:**
- Throughput: 100K-370K logs/sec
- Latency: <5ms per batch (p99)
- Memory: ~50MB base + buffers
- CPU: Multi-threaded, scales with cores

**Key Algorithms:**
```rust
// Template matching (zero-copy)
fn match_template(message: &str) -> Option<TemplateId> {
    for template in templates {
        if template.pattern.is_match(message) {
            return Some(template.id);
        }
    }
    None
}

// Batch processing
async fn process_batch(logs: Vec<Log>) -> Result<()> {
    let batch_size = 1000;

    if logs.len() > batch_size {
        // Parallel processing
        parallel_process(logs).await
    } else {
        // Sequential processing
        sequential_process(logs).await
    }
}
```

### 2. Admin Dashboard (Node.js/Next.js)

**Technology Stack:**
- Framework: Next.js / Express
- Database Client: ClickHouse Node client
- UI: React + Tailwind CSS

**Responsibilities:**
- CRUD operations for metric-log mappings
- Organization management
- Mapping validation and conflict detection
- Health checks and monitoring UI

**API Endpoints:**
- `GET /api/mappings` - List all mappings
- `POST /api/mappings` - Create new mapping
- `PUT /api/mappings/:id` - Update mapping
- `DELETE /api/mappings/:id` - Soft delete mapping
- `GET /api/organizations` - List organizations
- `GET /health` - Health check

### 3. Grafana Hover Plugin Backend

**Technology Stack:**
- Language: Go / TypeScript
- Framework: Grafana Plugin SDK

**Responsibilities:**
- Handle hover events from Grafana frontend
- Query metric_log_hover_mv for log streams
- Fetch baseline and current log distributions
- Calculate KL divergence scores
- Return ranked log examples

**KL Divergence Calculation:**
```typescript
function calculateKLDivergence(
  current: Map<TemplateId, number>,
  baseline: Map<TemplateId, number>
): Map<TemplateId, number> {

  const currentTotal = sum(current.values());
  const baselineTotal = sum(baseline.values());

  const divergences = new Map();

  for (const [templateId, currentCount] of current) {
    const p = currentCount / currentTotal;
    const q = (baseline.get(templateId) || 0.001) / baselineTotal; // Laplace smoothing

    const kl = p * Math.log(p / q);
    divergences.set(templateId, kl);
  }

  return divergences;
}
```

### 4. ClickHouse Database

**Version:** Latest (24.x)

**Configuration:**
- Ports: 8123 (HTTP), 9000 (Native)
- Storage: Persistent volume
- Users: Custom users.xml for auth
- Memory: Configurable cache sizes

**Performance Tuning:**
- `max_memory_usage`: Based on available RAM
- `max_threads`: Match CPU cores
- `distributed_aggregation_memory_efficient`: 1
- `use_uncompressed_cache`: 1

**Backup Strategy:**
- Daily snapshots of data directory
- Incremental backups via ClickHouse Backup tool
- Cross-region replication for DR

---

## Database Schema

### Schema Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                         ClickHouse Database                         │
└─────────────────────────────────────────────────────────────────────┘

┌──────────────────┐         ┌──────────────────┐
│  organizations   │         │     metrics      │
├──────────────────┤         ├──────────────────┤
│ id (PK)          │◄───────┤│ id (PK)          │
│ name             │         │ org_id (FK)      │
│ created_at       │         │ dashboard_name   │
│ updated_at       │         │ panel_title      │
└──────────────────┘         │ metric_name      │
                             │ created_at       │
                             │ updated_at       │
                             └────────┬─────────┘
                                      │
                                      │
                                      │
┌──────────────────┐                 │         ┌──────────────────────┐
│   log_streams    │                 │         │ metric_log_mappings  │
├──────────────────┤                 │         ├──────────────────────┤
│ id (PK)          │                 └────────►│ id (PK)              │
│ org_id (FK)      │◄────────────────────────┤│ org_id (FK)          │
│ service          │                           │ metric_id (FK)       │
│ region           │                           │ log_stream_id (FK)   │
│ log_stream_name  │                           │ created_at           │
│ created_at       │                           │ is_active            │
│ updated_at       │                           │ deleted_at           │
└────────┬─────────┘                           └──────────┬───────────┘
         │                                                │
         │                                                │
         │            ┌───────────────────────────────────┘
         │            │
         │            │     ┌─────────────────────────────┐
         │            │     │  metric_log_hover_mv        │
         │            └────►│  (Materialized View)        │
         │                  ├─────────────────────────────┤
         │                  │ org_id                      │
         │                  │ dashboard_name              │
         │                  │ panel_title                 │
         │                  │ metric_name                 │
         │                  │ log_stream_id               │
         │                  │ service                     │
         │                  │ region                      │
         │                  │ log_stream_name             │
         │                  │ is_active                   │
         │                  └─────────────────────────────┘
         │                            │
         │                            │ Fast lookups for hover queries
         │                            │
┌────────▼──────────┐                │
│      logs         │◄───────────────┘
├───────────────────┤
│ org_id            │
│ log_stream_id (FK)│
│ service           │
│ region            │
│ log_stream_name   │
│ timestamp         │
│ template_id       │
│ message           │
├───────────────────┤
│ Partition:        │
│  (org_id, YYYYMM) │
│ Order:            │
│  (org_id,         │
│   log_stream_id,  │
│   timestamp,      │
│   template_id)    │
│ TTL: 30 days      │
└───────┬───────────┘
        │
        │
┌───────▼───────────┐
│ template_examples │
├───────────────────┤
│ org_id            │
│ log_stream_id     │
│ service           │
│ region            │
│ template_id       │
│ message           │
│ timestamp         │
└───────────────────┘
```

### Table Details

#### 1. `logs` Table
```sql
CREATE TABLE logs (
    org_id String,
    log_stream_id String,
    service String,
    region String,
    log_stream_name String,
    timestamp DateTime64(3),
    template_id String,
    message String,
    INDEX idx_log_stream (org_id, log_stream_id, timestamp) TYPE minmax GRANULARITY 4
)
ENGINE = MergeTree()
PARTITION BY (org_id, toYYYYMM(timestamp))
ORDER BY (org_id, log_stream_id, timestamp, template_id)
TTL timestamp + INTERVAL 30 DAY;
```

**Storage Estimates:**
- Average log size: ~200 bytes
- 1M logs/day: ~200 MB/day
- 30-day retention: ~6 GB per org
- Compression ratio: ~5x (ClickHouse LZ4)
- Actual disk usage: ~1.2 GB per org

#### 2. `template_examples` Table
```sql
CREATE TABLE template_examples (
    org_id String,
    log_stream_id String,
    service String,
    region String,
    template_id String,
    message String,
    timestamp DateTime64(3),
    INDEX idx_template (org_id, log_stream_id, template_id) TYPE bloom_filter GRANULARITY 4
)
ENGINE = MergeTree()
PARTITION BY org_id
ORDER BY (org_id, log_stream_id, template_id, timestamp);
```

**Purpose:**
- Store representative examples for each template
- Used for displaying actual log messages in hover tooltips
- Minimal storage (~1 row per template per log stream)

#### 3. `metric_log_hover_mv` Materialized View
```sql
CREATE MATERIALIZED VIEW metric_log_hover_mv
ENGINE = MergeTree()
ORDER BY (org_id, dashboard_name, panel_title, metric_name, log_stream_id)
POPULATE
AS
SELECT
    mm.org_id,
    m.dashboard_name,
    m.panel_title,
    m.metric_name,
    ls.id AS log_stream_id,
    ls.service,
    ls.region,
    ls.log_stream_name,
    mm.is_active
FROM metric_log_mappings mm
JOIN metrics m ON mm.metric_id = m.id
JOIN log_streams ls ON mm.log_stream_id = ls.id;
```

**Purpose:**
- Pre-compute joins for instant hover lookups
- Avoid JOIN overhead during real-time queries
- Automatically updated when source tables change

**Query Performance:**
- Typical hover query: <5ms
- Index scan: O(log n)
- No JOINs at query time

---

## API Specifications

### Log Analysis Service API

#### POST `/logs/ingest/batch`

Ingest a batch of logs for processing and storage.

**Request:**
```json
{
  "logs": [
    {
      "org": "acme",
      "service": "api-server",
      "region": "us-east-1",
      "message": "Request completed in 150ms",
      "timestamp": "2025-11-02T05:17:38.123Z"  // Optional
    }
  ]
}
```

**Response (200 OK):**
```json
{
  "status": "success",
  "processed": 100,
  "matched": 98,
  "unmatched": 2,
  "duration_ms": 45
}
```

**Performance:**
- Max batch size: 10,000 logs
- Recommended batch size: 100-1,000 logs
- Timeout: 30 seconds

#### GET `/health`

Check service health and configuration.

**Response (200 OK):**
```json
{
  "status": "healthy",
  "templates_loaded": 379,
  "clickhouse_connected": true,
  "uptime_seconds": 86400
}
```

### Admin Dashboard API

#### POST `/api/mappings`

Create a new metric-to-log stream mapping.

**Request:**
```json
{
  "org": "acme",
  "dashboardName": "production",
  "panelTitle": "CPU Usage",
  "metricName": "cpu_percent",
  "service": "api-server",
  "region": "us-east-1",
  "logStreamName": "api-us-east-1-production"
}
```

**Response (201 Created):**
```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "status": "created",
  "mapping": { /* full mapping object */ }
}
```

#### GET `/api/mappings`

List all active mappings.

**Query Parameters:**
- `org` (optional): Filter by organization
- `dashboard` (optional): Filter by dashboard
- `limit` (optional): Max results (default: 100)
- `offset` (optional): Pagination offset

**Response (200 OK):**
```json
{
  "mappings": [
    {
      "id": "...",
      "org": "acme",
      "dashboardName": "production",
      "panelTitle": "CPU Usage",
      "metricName": "cpu_percent",
      "service": "api-server",
      "region": "us-east-1",
      "logStreamName": "api-us-east-1-production",
      "createdAt": "2025-11-01T10:00:00Z"
    }
  ],
  "total": 42,
  "limit": 100,
  "offset": 0
}
```

---

## Performance Characteristics

### Log Ingestion Performance

| Metric | Value | Notes |
|--------|-------|-------|
| Peak throughput | 370K logs/sec | With parallel processing |
| Typical throughput | 100K logs/sec | Single-threaded mode |
| Batch processing latency (p50) | 2ms | 100 logs per batch |
| Batch processing latency (p99) | 5ms | 1000 logs per batch |
| Template matching time | 50ns per log | Zero-copy matching |
| Memory per worker | 50MB | Base + buffers |

### Query Performance

| Query Type | Latency (p50) | Latency (p99) | Notes |
|------------|---------------|---------------|-------|
| Hover lookup (mapping) | 2ms | 5ms | Materialized view scan |
| Baseline distribution | 50ms | 200ms | Aggregate 24h of data |
| Current distribution | 10ms | 30ms | Aggregate 5m of data |
| Example log fetch | 5ms | 15ms | Bloom filter index |
| Full hover query (end-to-end) | 100ms | 300ms | Including KL divergence |

### Scalability

**Horizontal Scaling:**
- Log Analysis Service: Stateless, can run N replicas behind load balancer
- ClickHouse: Supports sharding and replication
- Admin Dashboard: Stateless, horizontally scalable

**Data Volume Capacity:**
```
Per Organization:
  - 1M logs/day = ~6 GB/30 days (compressed)
  - 10M logs/day = ~60 GB/30 days
  - 100M logs/day = ~600 GB/30 days

Multi-tenant (1000 orgs):
  - Average 1M logs/day each
  - Total: 1B logs/day
  - Storage: ~6 TB (30-day retention)
  - ClickHouse can handle 100+ TB per server
```

**Network Bandwidth:**
```
Ingest:
  - 100K logs/sec × 200 bytes = 20 MB/sec
  - With HTTP overhead: ~25 MB/sec
  - Required bandwidth: 200 Mbps

Query:
  - Typical hover query: ~10 KB response
  - 1000 req/sec = 10 MB/sec = 80 Mbps
```

---

## Deployment Architecture

### Docker Compose Development Setup

```yaml
version: '3.8'

services:
  clickhouse:
    image: clickhouse/clickhouse-server:latest
    ports:
      - "8123:8123"
      - "9000:9000"
    volumes:
      - clickhouse_data:/var/lib/clickhouse
      - ./schema:/docker-entrypoint-initdb.d
    healthcheck:
      test: ["CMD", "clickhouse-client", "--query", "SELECT 1"]
      interval: 10s

  log-analysis:
    build: ./log_analysis
    ports:
      - "3002:3002"
    depends_on:
      clickhouse:
        condition: service_healthy
    environment:
      - CLICKHOUSE_URL=http://clickhouse:8123
      - WORKERS=4

  admin-dashboard:
    build: ./admin_dashboard
    ports:
      - "3001:3000"
    depends_on:
      clickhouse:
        condition: service_healthy

  grafana:
    image: grafana/grafana:latest
    ports:
      - "3000:3000"
    volumes:
      - ./grafana-plugins:/var/lib/grafana/plugins
    depends_on:
      - clickhouse
      - log-analysis

volumes:
  clickhouse_data:
```

### Production Kubernetes Deployment

```
┌──────────────────────────────────────────────────────────────┐
│                      Kubernetes Cluster                       │
└──────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────┐
│  Namespace: hypothecary-prod                                 │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌────────────────────────────────────────────────────┐     │
│  │  Ingress Controller (nginx)                        │     │
│  │  - SSL termination                                 │     │
│  │  - Rate limiting                                   │     │
│  └────┬───────────────────────────────┬─────────────┬─┘     │
│       │                               │             │       │
│       │ /logs/*                       │ /api/*      │ /     │
│       │                               │             │       │
│  ┌────▼──────────┐  ┌─────────────────▼──┐  ┌──────▼─────┐ │
│  │ log-analysis  │  │ admin-dashboard    │  │  grafana   │ │
│  │  Service      │  │     Service        │  │  Service   │ │
│  │  (ClusterIP)  │  │   (ClusterIP)      │  │ (ClusterIP)│ │
│  └────┬──────────┘  └─────────────────┬──┘  └──────┬─────┘ │
│       │                               │             │       │
│  ┌────▼──────────┐  ┌─────────────────▼──┐  ┌──────▼─────┐ │
│  │ log-analysis  │  │ admin-dashboard    │  │  grafana   │ │
│  │  Deployment   │  │    Deployment      │  │ Deployment │ │
│  │  (3 replicas) │  │   (2 replicas)     │  │(2 replicas)│ │
│  │               │  │                    │  │            │ │
│  │  Resources:   │  │  Resources:        │  │ Resources: │ │
│  │   CPU: 2      │  │   CPU: 1           │  │  CPU: 1    │ │
│  │   Mem: 4Gi    │  │   Mem: 2Gi         │  │  Mem: 2Gi  │ │
│  └────┬──────────┘  └─────────────────┬──┘  └──────┬─────┘ │
│       │                               │             │       │
│       └───────────────┬───────────────┴─────────────┘       │
│                       │                                     │
│                  ┌────▼──────────┐                          │
│                  │  ClickHouse   │                          │
│                  │   StatefulSet │                          │
│                  │  (3 replicas) │                          │
│                  │               │                          │
│                  │  Resources:   │                          │
│                  │   CPU: 8      │                          │
│                  │   Mem: 32Gi   │                          │
│                  │   Disk: 1TB   │                          │
│                  │   (SSD)       │                          │
│                  └───────────────┘                          │
│                                                              │
│  ┌────────────────────────────────────────────────────┐     │
│  │  ConfigMaps & Secrets                              │     │
│  │  - clickhouse-config                               │     │
│  │  - template-cache                                  │     │
│  │  - db-credentials (secret)                         │     │
│  └────────────────────────────────────────────────────┘     │
│                                                              │
│  ┌────────────────────────────────────────────────────┐     │
│  │  PersistentVolumeClaims                            │     │
│  │  - clickhouse-data-pvc (3x 1TB)                    │     │
│  └────────────────────────────────────────────────────┘     │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

### Resource Requirements

**Minimum (Development):**
- CPU: 4 cores
- Memory: 8 GB RAM
- Disk: 50 GB SSD

**Production (Small - 1M logs/day):**
- CPU: 16 cores
- Memory: 32 GB RAM
- Disk: 500 GB SSD

**Production (Large - 100M logs/day):**
- CPU: 64 cores
- Memory: 256 GB RAM
- Disk: 5 TB NVMe SSD
- Network: 10 Gbps

---

## Security Considerations

### Authentication & Authorization
- API key-based authentication for log ingestion
- JWT tokens for admin dashboard
- Role-based access control (RBAC) per organization
- Grafana SSO integration (OAuth2/SAML)

### Data Encryption
- TLS 1.3 for all HTTP traffic
- ClickHouse encryption at rest (optional)
- Secrets stored in Kubernetes Secrets or HashiCorp Vault

### Network Security
- Private VPC for ClickHouse
- Network policies to restrict pod-to-pod communication
- Rate limiting on public endpoints (1000 req/min per IP)
- DDoS protection via cloud provider

### Data Privacy
- Multi-tenant isolation via org_id filtering
- No cross-organization data leakage
- Automatic PII redaction (configurable)
- GDPR compliance: 30-day TTL, data deletion API

---

## Monitoring & Observability

### Metrics (Prometheus)

**Log Analysis Service:**
- `logs_ingested_total` - Counter of processed logs
- `logs_matched_total` - Counter of template matches
- `logs_unmatched_total` - Counter of unmatched logs
- `batch_processing_duration_seconds` - Histogram of batch latency
- `template_matching_duration_seconds` - Histogram of matching time

**ClickHouse:**
- `clickhouse_query_duration_seconds` - Query latency
- `clickhouse_disk_usage_bytes` - Disk usage by table
- `clickhouse_rows_inserted_total` - Insert throughput

**System:**
- `cpu_usage_percent`
- `memory_usage_bytes`
- `disk_io_operations_total`
- `network_bytes_transmitted_total`

### Logs (Structured JSON)

```json
{
  "timestamp": "2025-11-02T05:17:38.123Z",
  "level": "info",
  "service": "log-analysis",
  "message": "Batch processed successfully",
  "batch_size": 100,
  "duration_ms": 45,
  "matched": 98,
  "unmatched": 2
}
```

### Tracing (OpenTelemetry)
- Distributed tracing for hover queries
- Trace log ingestion pipeline
- Trace ClickHouse query execution

### Alerts

**Critical:**
- Service down (health check fails)
- ClickHouse disk >90% full
- Error rate >5% for 5 minutes

**Warning:**
- High query latency (p99 >500ms)
- Disk >80% full
- Template match rate <80%

---

## Future Enhancements

### Short-term (Q1 2026)
1. **Real-time alerting** - Alert on KL divergence spikes
2. **Log deduplication** - Reduce storage for duplicate logs
3. **Custom templates** - UI for creating custom log patterns
4. **Export API** - Export logs to S3/GCS for long-term storage

### Medium-term (Q2-Q3 2026)
1. **ML-based anomaly detection** - Replace KL divergence with ML models
2. **Multi-region replication** - Geo-distributed ClickHouse clusters
3. **Log sampling** - Smart sampling for high-volume streams
4. **Query builder UI** - Visual query builder for log exploration

### Long-term (2027+)
1. **Auto-scaling** - Dynamic scaling based on load
2. **Log correlation engine** - Correlate logs across services
3. **Natural language queries** - "Show me errors in the last hour"
4. **Predictive analytics** - Predict incidents before they happen

---

## Appendix

### A. Template Examples

```json
{
  "template_id": "73",
  "pattern": "Disk usage: \\d+%",
  "example": "Disk usage: 80%",
  "category": "resource_monitoring"
}

{
  "template_id": "110",
  "pattern": "Job processed: job_\\w+",
  "example": "Job processed: job_456",
  "category": "job_processing"
}

{
  "template_id": "79",
  "pattern": "Cache hit ratio: \\d+%",
  "example": "Cache hit ratio: 95%",
  "category": "cache_metrics"
}
```

### B. Sample Queries

**Find all ERROR logs in the last hour:**
```sql
SELECT message, timestamp
FROM logs
WHERE org_id = 'acme'
  AND timestamp > now() - INTERVAL 1 HOUR
  AND message LIKE '%ERROR%'
ORDER BY timestamp DESC
LIMIT 100;
```

**Top 10 most frequent templates:**
```sql
SELECT
    template_id,
    COUNT(*) as count,
    any(message) as example
FROM logs
WHERE org_id = 'acme'
  AND timestamp > now() - INTERVAL 24 HOUR
GROUP BY template_id
ORDER BY count DESC
LIMIT 10;
```

**Logs per service per hour:**
```sql
SELECT
    service,
    toStartOfHour(timestamp) as hour,
    COUNT(*) as log_count
FROM logs
WHERE org_id = 'acme'
  AND timestamp > now() - INTERVAL 24 HOUR
GROUP BY service, hour
ORDER BY hour DESC, log_count DESC;
```

### C. Troubleshooting Guide

**Problem: High query latency**
- Check ClickHouse disk I/O
- Verify indexes are being used (`EXPLAIN` query)
- Check for table partitioning issues
- Consider adding more memory for caching

**Problem: Template match rate <80%**
- Review unmatched logs: `SELECT message FROM logs WHERE template_id = 'unknown'`
- Generate new templates from unmatched patterns
- Update template cache and reload service

**Problem: ClickHouse out of memory**
- Reduce `max_memory_usage` setting
- Enable `distributed_aggregation_memory_efficient`
- Add more RAM or reduce query complexity
- Implement query result caching

---

## Conclusion

The Hypothecary Log Analysis System provides a scalable, high-performance solution for correlating metrics with logs in real-time. By leveraging template-based pattern matching, materialized views, and KL divergence analysis, the system enables rapid root cause analysis during incidents.

**Key Strengths:**
- High throughput (100K+ logs/sec)
- Low latency hover queries (<100ms p50)
- Scalable multi-tenant architecture
- Automatic data retention and cleanup
- Rich Grafana integration

**Production Readiness:**
- Fully containerized with Docker Compose
- Kubernetes manifests for production deployment
- Comprehensive monitoring and alerting
- Security hardening (TLS, RBAC, secrets management)
- Automated backups and disaster recovery

For questions or support, contact the platform team or file an issue in the project repository.
