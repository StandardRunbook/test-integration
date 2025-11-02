# Integration Testing Scripts

This directory contains scripts for setting up and testing the Hypothecary log analysis system with Docker Compose.

## Quick Start

```bash
# 1. Start all services
docker-compose up -d

# 2. Wait for services to be ready (about 30 seconds)
docker-compose ps

# 3. Add log templates
./add_mappings.sh

# 4. Add metric-log mappings
./add_metric_mappings.sh

# 5. Send test logs
./send_logs.sh -n 100 -r 20
```

## Scripts Overview

### 1. `add_mappings.sh` - Add Log Templates

Populates the ClickHouse templates table that the log-ingest-service uses for pattern matching.

**Usage:**
```bash
./add_mappings.sh
```

**Environment Variables:**
- `CLICKHOUSE_URL` - ClickHouse URL (default: `http://localhost:8123`)
- `TEMPLATES_FILE` - Path to templates JSON (default: `../log_analysis/cache/comprehensive_templates.json`)

**Features:**
- Loads templates from comprehensive_templates.json
- Validates ClickHouse connection
- Shows template count and examples
- Displays sample templates

**Prerequisites:**
- ClickHouse must be running
- Templates file must exist (generate with: `cd ../log_analysis && cargo run --release --example generate_comprehensive_templates`)

### 2. `add_metric_mappings.sh` - Add Metric-Log Mappings

Creates relationships between Grafana metrics and log streams in the admin dashboard.

**Usage:**
```bash
# Auto-generate 10 mappings
./add_metric_mappings.sh

# Custom number of mappings
./add_metric_mappings.sh -n 20 -o acme -d production

# Load from JSON file
./add_metric_mappings.sh -f sample_mappings.json
```

**Options:**
- `-n NUM` - Number of mappings to create (default: 10)
- `-o ORG` - Organization name (default: test-org)
- `-d DASHBOARD` - Dashboard name (default: test-dashboard)
- `-u URL` - Admin dashboard URL (default: http://localhost:3001)
- `-f FILE` - JSON file with mapping definitions
- `-h` - Show help

**JSON File Format:**
See [sample_mappings.json](sample_mappings.json) for an example. Each mapping requires:
```json
{
  "org": "acme",
  "dashboardName": "production",
  "panelTitle": "CPU Usage",
  "metricName": "cpu_percent",
  "service": "api",
  "region": "us-east-1",
  "logStreamName": "api-us-east-1-production"
}
```

**Database Tables:**
- `organizations` - Organizations
- `metrics` - Grafana metrics
- `log_streams` - Log stream configurations
- `metric_log_mappings` - Many-to-many mappings
- `metric_log_hover_mv` - Materialized view for fast lookups

### 3. `send_logs.sh` - Send Test Logs

Sends test logs to the log-ingest-service API.

**Usage:**
```bash
# Send 100 logs at 10 logs/second
./send_logs.sh

# Custom configuration
./send_logs.sh -n 500 -r 50 -o acme -d production

# Batch mode (100 logs per request)
./send_logs.sh -b 100 -n 1000 -r 100

# Custom service URL
./send_logs.sh -u http://localhost:8080
```

**Options:**
- `-n NUM` - Number of logs to send (default: 100)
- `-r RATE` - Logs per second (default: 10)
- `-o ORG` - Organization name (default: test-org)
- `-d DASHBOARD` - Dashboard name (default: test-dashboard)
- `-s SERVICE` - Service name (default: test-service)
- `-b BATCH` - Batch size for sending (default: 1)
- `-u URL` - Service URL (default: http://localhost:3002)
- `-h` - Show help

**Log Patterns:**
The script generates logs with realistic patterns including:
- Connection timeouts
- Retry attempts
- Request completion times
- Database connection events
- Queue metrics
- Rate limits
- Cache statistics
- Resource usage
- Authentication failures
- File errors

## Docker Compose Services

### Services

1. **clickhouse** (port 8123, 9000)
   - Database for logs, templates, and mappings
   - Initialized with schemas on startup

2. **log-analysis** (port 3002)
   - Log ingestion service
   - Pattern matching and template generation
   - Buffered writes to ClickHouse

3. **admin-dashboard** (port 3001)
   - Admin interface for managing mappings
   - API for creating metric-log relationships

4. **grafana** (port 3000)
   - Visualization platform
   - Hover plugin for log exploration

### Service Dependencies

```
clickhouse
  ├─> log-analysis (depends on clickhouse healthy)
  ├─> admin-dashboard (depends on clickhouse healthy)
  └─> grafana (depends on clickhouse healthy + log-analysis started)
```

## Complete Integration Test Workflow

```bash
# Step 1: Start services
docker-compose up -d

# Step 2: Wait for services to be healthy
echo "Waiting for services to be ready..."
sleep 30

# Step 3: Check service health
curl http://localhost:8123/ping                    # ClickHouse
curl http://localhost:3002/health | jq .           # Log-analysis
curl http://localhost:3001/api/mappings | jq .    # Admin-dashboard

# Step 4: Generate templates (if not already done)
cd ../log_analysis
cargo run --release --example generate_comprehensive_templates
cd -

# Step 5: Add templates to ClickHouse
./add_mappings.sh

# Step 6: Add metric-log mappings
./add_metric_mappings.sh -n 20

# Step 7: Send test logs
./send_logs.sh -n 1000 -r 50

# Step 8: Verify data in ClickHouse
curl 'http://localhost:8123/?query=SELECT COUNT(*) FROM logs'
curl 'http://localhost:8123/?query=SELECT COUNT(*) FROM templates'
curl 'http://localhost:8123/?query=SELECT COUNT(*) FROM metric_log_mappings WHERE is_active=1'

# Step 9: View logs in Grafana
open http://localhost:3000
```

## Useful ClickHouse Queries

```bash
# Count logs
curl 'http://localhost:8123/?query=SELECT COUNT(*) FROM logs'

# Recent logs
curl 'http://localhost:8123/?query=SELECT * FROM logs ORDER BY timestamp DESC LIMIT 10 FORMAT Vertical'

# Logs by level
curl 'http://localhost:8123/?query=SELECT level, COUNT(*) as count FROM logs GROUP BY level FORMAT Vertical'

# Count templates
curl 'http://localhost:8123/?query=SELECT COUNT(*) FROM templates'

# View templates
curl 'http://localhost:8123/?query=SELECT template_id, pattern, example FROM templates LIMIT 5 FORMAT Vertical'

# Count mappings
curl 'http://localhost:8123/?query=SELECT COUNT(*) FROM metric_log_mappings WHERE is_active=1'

# View mappings
curl 'http://localhost:8123/?query=SELECT * FROM metric_log_hover_mv LIMIT 5 FORMAT Vertical'

# Mappings by org
curl 'http://localhost:8123/?query=SELECT org_id, COUNT(*) FROM metric_log_hover_mv WHERE is_active=1 GROUP BY org_id FORMAT Vertical'
```

## Troubleshooting

### Services Not Starting

```bash
# Check service status
docker-compose ps

# View logs
docker-compose logs clickhouse
docker-compose logs log-analysis
docker-compose logs admin-dashboard

# Restart specific service
docker-compose restart log-analysis
```

### ClickHouse Connection Issues

```bash
# Test connection
curl http://localhost:8123/ping

# Check if port is available
lsof -i :8123

# View ClickHouse logs
docker-compose logs clickhouse
```

### Log-Ingest Service Issues

```bash
# Check health
curl http://localhost:3002/health | jq .

# Check stats
curl http://localhost:3002/stats | jq .

# View logs
docker-compose logs log-analysis

# Check if templates are loaded
curl 'http://localhost:8123/?query=SELECT COUNT(*) FROM templates'
```

### Admin Dashboard Issues

```bash
# Check if API is accessible
curl http://localhost:3001/api/mappings | jq .

# View logs
docker-compose logs admin-dashboard

# Check if ClickHouse tables exist
curl 'http://localhost:8123/?query=SHOW TABLES'
```

### Template File Not Found

```bash
# Generate templates
cd ../log_analysis
cargo run --release --example generate_comprehensive_templates

# Verify file exists
ls -lh cache/comprehensive_templates.json

# Return to test directory
cd ../test-integration
```

## Cleanup

```bash
# Stop all services
docker-compose down

# Stop and remove volumes (deletes all data)
docker-compose down -v

# Remove specific volume
docker volume rm test-integration_clickhouse_data
```

## Performance Testing

### High Volume Log Ingestion

```bash
# Send 10,000 logs at 100 logs/second
./send_logs.sh -n 10000 -r 100

# Batch mode for better performance
./send_logs.sh -b 100 -n 10000 -r 1000
```

### Load Testing with Multiple Processes

```bash
# Run 5 concurrent senders
for i in {1..5}; do
  ./send_logs.sh -n 1000 -r 50 &
done
wait
echo "All senders completed"
```

### Monitor Resource Usage

```bash
# Watch service stats
watch -n 1 'docker stats --no-stream'

# Monitor ClickHouse
watch -n 1 "curl -s 'http://localhost:8123/?query=SELECT COUNT(*) FROM logs'"

# Monitor log-ingest service
watch -n 1 "curl -s http://localhost:3002/health | jq ."
```

## Environment Variables

Create a `.env` file to customize service URLs:

```bash
# ClickHouse
CLICKHOUSE_URL=http://localhost:8123

# Log-ingest service
SERVICE_URL=http://localhost:3002

# Admin dashboard
ADMIN_URL=http://localhost:3001

# Templates
TEMPLATES_FILE=../log_analysis/cache/comprehensive_templates.json
```

Source the file before running scripts:
```bash
source .env
./add_mappings.sh
```

## API Endpoints

### Log-Ingest Service (port 3002)

- `GET /health` - Health check
- `GET /stats` - Service statistics
- `POST /logs/ingest` - Ingest single log or batch

### Admin Dashboard (port 3001)

- `GET /api/mappings` - List all mappings
- `POST /api/mappings` - Create new mapping
- `GET /api/mappings/:id` - Get mapping by ID
- `PUT /api/mappings/:id` - Update mapping
- `DELETE /api/mappings/:id` - Delete mapping

## Next Steps

1. **Explore Grafana**: Open http://localhost:3000 to visualize logs
2. **Create Custom Mappings**: Edit `sample_mappings.json` and load with `-f` flag
3. **Test Hover Plugin**: Configure Grafana panels to use the hover plugin
4. **Monitor Performance**: Use the performance testing commands above
5. **Integrate with CI/CD**: Add these scripts to your test pipeline

## Support

For issues or questions:
- Check service logs: `docker-compose logs <service>`
- Verify services are healthy: `docker-compose ps`
- Review API documentation in `../log_analysis/INGEST_SERVICE_API.md`
