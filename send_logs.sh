#!/bin/bash
# Send logs to the log-ingest-service API for integration testing
# Usage: ./send_logs.sh [options]
#
# Options:
#   -n NUM        Number of logs to send (default: 100)
#   -r RATE       Logs per second (default: 10)
#   -o ORG        Organization name (default: test-org)
#   -d DASHBOARD  Dashboard name (default: test-dashboard)
#   -s SERVICE    Service name (default: test-service)
#   -b BATCH      Batch size for sending (default: 1 for single, or specify for batch mode)
#   -u URL        Service URL (default: http://localhost:3002)
#
# Examples:
#   ./send_logs.sh -n 500 -r 50
#   ./send_logs.sh -o acme -d production -n 1000
#   ./send_logs.sh -b 100 -n 1000    # Send in batches of 100

set -e

# Defaults
SERVICE_URL="${SERVICE_URL:-http://localhost:3002}"
NUM_LOGS=100
RATE=10
BATCH_SIZE=1
ORG=""
DASHBOARD=""
SERVICE=""
USE_FIXED_VALUES=false

# Parse command line arguments
while getopts "n:r:o:d:s:b:u:h" opt; do
    case $opt in
        n) NUM_LOGS="$OPTARG" ;;
        r) RATE="$OPTARG" ;;
        o) ORG="$OPTARG"; USE_FIXED_VALUES=true ;;
        d) DASHBOARD="$OPTARG"; USE_FIXED_VALUES=true ;;
        s) SERVICE="$OPTARG"; USE_FIXED_VALUES=true ;;
        b) BATCH_SIZE="$OPTARG" ;;
        u) SERVICE_URL="$OPTARG" ;;
        h)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  -n NUM        Number of logs to send (default: 100)"
            echo "  -r RATE       Logs per second (default: 10)"
            echo "  -o ORG        Organization name (default: test-org)"
            echo "  -d DASHBOARD  Dashboard name (default: test-dashboard)"
            echo "  -s SERVICE    Service name (default: test-service)"
            echo "  -b BATCH      Batch size (default: 1)"
            echo "  -u URL        Service URL (default: http://localhost:3002)"
            echo "  -h            Show this help"
            exit 0
            ;;
        \?) echo "Invalid option -$OPTARG" >&2; exit 1 ;;
    esac
done

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}📤 Sending logs to $SERVICE_URL${NC}"
echo ""
echo "Configuration:"
echo "   Total logs:  $NUM_LOGS"
echo "   Rate:        $RATE logs/second"
echo "   Batch size:  $BATCH_SIZE"
if [ "$USE_FIXED_VALUES" = true ]; then
    echo "   Mode:        Fixed values"
    [ -n "$ORG" ] && echo "   Org:         $ORG"
    [ -n "$DASHBOARD" ] && echo "   Dashboard:   $DASHBOARD"
    [ -n "$SERVICE" ] && echo "   Service:     $SERVICE"
else
    echo "   Mode:        Random (from sample_mappings.json)"
fi
echo ""

# Check if service is running
if ! curl -s "$SERVICE_URL/health" > /dev/null 2>&1; then
    echo -e "${RED}❌ Service not running at $SERVICE_URL${NC}"
    echo ""
    echo "Start with:"
    echo "  docker-compose up -d log-analysis"
    exit 1
fi

echo -e "${GREEN}✓${NC} Service is healthy"
echo ""

# Sample log messages with varying patterns
MESSAGES=(
    "Connection timeout after 30s"
    "Retry attempt 1 of 3"
    "Retry attempt 2 of 3"
    "Retry attempt 3 of 3"
    "Request completed in 245ms"
    "Request completed in 123ms"
    "Request completed in 567ms"
    "Database connection lost"
    "Database connection restored"
    "Reconnected successfully"
    "Job processed: job_123"
    "Job processed: job_456"
    "Job processed: job_789"
    "Queue depth: 1000 items"
    "Queue depth: 500 items"
    "Queue depth: 2000 items"
    "Rate limit exceeded"
    "Rate limit warning: 90% of quota"
    "Cache hit ratio: 95%"
    "Cache hit ratio: 87%"
    "Slow query detected: 5.2s"
    "Slow query detected: 3.1s"
    "Memory usage: 512MB"
    "Memory usage: 1024MB"
    "Disk usage: 80%"
    "Disk usage: 90%"
    "CPU usage: 45%"
    "CPU usage: 78%"
    "Authentication failed for user admin"
    "Authentication failed for user guest"
    "Session expired for user bob"
    "Session expired for user alice"
    "API key invalid: key_abc123"
    "API key invalid: key_xyz789"
    "Permission denied: read access required"
    "Permission denied: write access required"
    "File not found: /var/log/app.log"
    "File not found: /etc/config.yaml"
    "Invalid configuration: missing required field 'host'"
    "Invalid configuration: missing required field 'port'"
)

# Predefined org/service/region/stream combinations that match sample_mappings.json
# Format: org|service|region|log_stream_name|log_stream_id
# Note: org_id is empty string to match the current database state (admin dashboard bug)
ORG_CONFIGS=(
    "|system-monitor|us-east-1|system-monitor-cpu-logs|ec3a9958-d9d5-4d33-abba-ae8b40c81696"
    "|system-monitor|us-east-1|system-monitor-memory-logs|7694c1e3-6f75-4096-85ae-3e2d408781ef"
    "|api|us-east-1|api-us-east-1-production|2bc7ee42-2bd2-43be-98d6-5975ee263f67"
    "|api|us-east-1|api-us-east-1-performance|761e2517-f6cf-40c3-a225-9b6d4736045e"
    "|api|us-east-1|api-us-east-1-errors|cc2a6d94-8e55-4517-9c4c-5e6ac42922b9"
    "|database|us-east-1|postgres-us-east-1-staging|9f542ac2-ba9a-4a3d-8d88-abe832317951"
    "|cache|us-east-1|redis-us-east-1-staging|241570d2-c2dd-4f5d-a989-267141a4a858"
    "|worker|eu-west-1|worker-eu-west-1-jobs|e6f51b25-d3db-48c5-8b28-dfad7f158603"
    "|web|eu-west-1|nginx-eu-west-1-access|0406c81e-c01c-418b-9bde-cfb6e723ae81"
)

LEVELS=("INFO" "WARN" "ERROR" "DEBUG")
HOSTS=("server-01" "server-02" "server-03" "worker-01" "worker-02")

# Calculate delay between requests
if [ "$BATCH_SIZE" -gt 1 ]; then
    # For batch mode, delay is between batches
    DELAY=$(echo "scale=3; $BATCH_SIZE / $RATE" | bc)
else
    # For single mode, delay is between individual logs
    DELAY=$(echo "scale=3; 1 / $RATE" | bc)
fi

echo -e "${GREEN}✓${NC} Starting log generation..."
echo ""

TOTAL_SENT=0
TOTAL_MATCHED=0
TOTAL_FAILED=0
BATCH_LOGS=()

# Function to send a batch
send_batch() {
    local logs_json=$(printf '%s\n' "${BATCH_LOGS[@]}" | jq -s '.')

    if [ "$BATCH_SIZE" -eq 1 ]; then
        # Single log mode
        RESPONSE=$(curl -s -X POST "$SERVICE_URL/logs/ingest" \
            -H 'Content-Type: application/json' \
            -d "${BATCH_LOGS[0]}")
    else
        # Batch mode
        PAYLOAD=$(jq -n --argjson logs "$logs_json" '{logs: $logs}')
        RESPONSE=$(curl -s -X POST "$SERVICE_URL/logs/ingest" \
            -H 'Content-Type: application/json' \
            -d "$PAYLOAD")
    fi

    # Check if response is valid JSON
    if ! echo "$RESPONSE" | jq . > /dev/null 2>&1; then
        echo -e "${RED}✗${NC} Invalid response: $RESPONSE"
        ACCEPTED=0
        MATCHED=0
        FAILED=${#BATCH_LOGS[@]}
    else
        ACCEPTED=$(echo "$RESPONSE" | jq -r '.accepted // 0')
        MATCHED=$(echo "$RESPONSE" | jq -r '.matched // 0')
        FAILED=$(echo "$RESPONSE" | jq -r '.failed // 0')
    fi

    TOTAL_SENT=$((TOTAL_SENT + ACCEPTED))
    TOTAL_MATCHED=$((TOTAL_MATCHED + MATCHED))
    TOTAL_FAILED=$((TOTAL_FAILED + FAILED))

    BATCH_LOGS=()
}

for i in $(seq 1 $NUM_LOGS); do
    # Generate random log data
    MESSAGE="${MESSAGES[$((RANDOM % ${#MESSAGES[@]}))]}"
    LEVEL="${LEVELS[$((RANDOM % ${#LEVELS[@]}))]}"
    HOST="${HOSTS[$((RANDOM % ${#HOSTS[@]}))]}"
    TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Select random org config or use provided org/service/dashboard
    if [ "$USE_FIXED_VALUES" = true ]; then
        # Use command-line provided values
        LOG_ORG="${ORG:-test-org}"
        LOG_SERVICE="${SERVICE:-test-service}"
        LOG_REGION="us-east-1"
        LOG_STREAM_NAME="$LOG_SERVICE-${DASHBOARD:-test-dashboard}-stream"
        LOG_STREAM_ID="custom-stream-id"
    else
        # Use predefined configs that match sample_mappings.json
        CONFIG="${ORG_CONFIGS[$((RANDOM % ${#ORG_CONFIGS[@]}))]}"
        LOG_ORG=$(echo "$CONFIG" | cut -d'|' -f1)
        LOG_SERVICE=$(echo "$CONFIG" | cut -d'|' -f2)
        LOG_REGION=$(echo "$CONFIG" | cut -d'|' -f3)
        LOG_STREAM_NAME=$(echo "$CONFIG" | cut -d'|' -f4)
        LOG_STREAM_ID=$(echo "$CONFIG" | cut -d'|' -f5)
    fi

    # Create JSON payload
    LOG_JSON=$(cat <<EOF
{
  "timestamp": "$TIMESTAMP",
  "org_id": "$LOG_ORG",
  "log_stream_id": "$LOG_STREAM_ID",
  "service": "$LOG_SERVICE",
  "region": "$LOG_REGION",
  "log_stream_name": "$LOG_STREAM_NAME",
  "message": "$MESSAGE"
}
EOF
)

    BATCH_LOGS+=("$LOG_JSON")

    # Send batch when full or on last log
    if [ "${#BATCH_LOGS[@]}" -eq "$BATCH_SIZE" ] || [ "$i" -eq "$NUM_LOGS" ]; then
        send_batch

        # Progress indicator
        if [ $((i % 50)) -eq 0 ] || [ "$i" -eq "$NUM_LOGS" ]; then
            MATCH_RATE=$((TOTAL_MATCHED * 100 / (TOTAL_SENT + 1)))
            echo -e "${YELLOW}⟳${NC} Sent: $TOTAL_SENT | Matched: $TOTAL_MATCHED ($MATCH_RATE%) | Failed: $TOTAL_FAILED"
        fi

        # Sleep to control rate
        sleep "$DELAY"
    fi
done

echo ""
echo "================================"
echo -e "${GREEN}✅ Log generation complete${NC}"
echo ""
echo "📊 Summary:"
echo "   Total sent:    $TOTAL_SENT"
echo "   Matched:       $TOTAL_MATCHED"
echo "   Failed:        $TOTAL_FAILED"
if [ "$TOTAL_SENT" -gt 0 ]; then
    MATCH_RATE=$((TOTAL_MATCHED * 100 / TOTAL_SENT))
    echo "   Match rate:    ${MATCH_RATE}%"
fi
echo ""
echo "🔍 Query logs in ClickHouse:"
echo "   curl 'http://localhost:8123/?query=SELECT COUNT(*) FROM logs'"
echo "   curl 'http://localhost:8123/?query=SELECT * FROM logs ORDER BY timestamp DESC LIMIT 10 FORMAT Vertical'"
echo ""
echo "🔍 Check service health:"
echo "   curl http://localhost:3002/health | jq ."
echo ""
