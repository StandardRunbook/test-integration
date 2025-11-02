#!/bin/bash
# Add metric-log mappings to the admin dashboard for integration testing
# This creates relationships between Grafana metrics and log streams
#
# Usage: ./add_metric_mappings.sh [options]
#
# Options:
#   -n NUM        Number of mappings to create (default: 10)
#   -o ORG        Organization name (default: test-org)
#   -d DASHBOARD  Dashboard name (default: test-dashboard)
#   -u URL        Admin dashboard URL (default: http://localhost:3001)
#   -f FILE       JSON file with mapping definitions (optional)
#
# Examples:
#   ./add_metric_mappings.sh -n 20 -o acme -d production
#   ./add_metric_mappings.sh -f custom_mappings.json

set -e

# Defaults
ADMIN_URL="${ADMIN_URL:-http://localhost:3001}"
NUM_MAPPINGS=10
ORG="test-org"
DASHBOARD="test-dashboard"
MAPPINGS_FILE=""

# Parse command line arguments
while getopts "n:o:d:u:f:h" opt; do
    case $opt in
        n) NUM_MAPPINGS="$OPTARG" ;;
        o) ORG="$OPTARG" ;;
        d) DASHBOARD="$OPTARG" ;;
        u) ADMIN_URL="$OPTARG" ;;
        f) MAPPINGS_FILE="$OPTARG" ;;
        h)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  -n NUM        Number of mappings to create (default: 10)"
            echo "  -o ORG        Organization name (default: test-org)"
            echo "  -d DASHBOARD  Dashboard name (default: test-dashboard)"
            echo "  -u URL        Admin dashboard URL (default: http://localhost:3001)"
            echo "  -f FILE       JSON file with mapping definitions"
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

echo -e "${BLUE}🔗 Adding Metric-Log Mappings to Admin Dashboard${NC}"
echo ""
echo "Configuration:"
echo "   Admin URL:   $ADMIN_URL"
echo "   Organization: $ORG"
echo "   Dashboard:   $DASHBOARD"
if [ -n "$MAPPINGS_FILE" ]; then
    echo "   Input file:  $MAPPINGS_FILE"
else
    echo "   Mappings:    $NUM_MAPPINGS (auto-generated)"
fi
echo ""

# Check if admin dashboard is running
if ! curl -s "$ADMIN_URL/api/mappings" > /dev/null 2>&1; then
    echo -e "${RED}❌ Admin dashboard not accessible at $ADMIN_URL${NC}"
    echo ""
    echo "Start with:"
    echo "  docker-compose up -d admin-dashboard"
    echo "Or if running locally:"
    echo "  cd ../admin_dashboard && npm run dev"
    exit 1
fi

echo -e "${GREEN}✓${NC} Admin dashboard is accessible"
echo ""

# Sample panel configurations
PANELS=(
    "CPU Usage|cpu_percent"
    "Memory Usage|memory_used_mb"
    "Disk I/O|disk_io_bytes"
    "Network Traffic|network_bytes"
    "Request Rate|request_count"
    "Error Rate|error_count"
    "Response Time|response_time_ms"
    "Active Connections|active_connections"
    "Queue Depth|queue_depth"
    "Cache Hit Rate|cache_hit_ratio"
)

# Sample services
SERVICES=("api" "database" "worker" "cache" "auth" "queue" "web" "backend")

# Sample regions
REGIONS=("us-east-1" "us-west-2" "eu-west-1" "ap-south-1" "local")

# Function to create a mapping
create_mapping() {
    local org=$1
    local dashboard=$2
    local panel_title=$3
    local metric_name=$4
    local service=$5
    local region=$6
    local log_stream=$7

    PAYLOAD=$(cat <<EOF
{
  "org": "$org",
  "dashboardName": "$dashboard",
  "panelTitle": "$panel_title",
  "metricName": "$metric_name",
  "service": "$service",
  "region": "$region",
  "logStreamName": "$log_stream"
}
EOF
)

    RESPONSE=$(curl -s -X POST "$ADMIN_URL/api/mappings" \
        -H 'Content-Type: application/json' \
        -d "$PAYLOAD")

    echo "$RESPONSE"
}

# Function to create mappings from file
create_from_file() {
    local file=$1

    if [ ! -f "$file" ]; then
        echo -e "${RED}❌ Error: File not found: $file${NC}"
        exit 1
    fi

    echo -e "${YELLOW}⟳${NC} Creating mappings from file..."
    echo ""

    # Read and process each mapping
    local count=0
    while IFS= read -r line; do
        RESPONSE=$(curl -s -X POST "$ADMIN_URL/api/mappings" \
            -H 'Content-Type: application/json' \
            -d "$line")

        ERROR=$(echo "$RESPONSE" | jq -r '.error // empty')
        if [ -n "$ERROR" ]; then
            echo -e "${RED}✗${NC} Failed: $ERROR"
        else
            count=$((count + 1))
            ID=$(echo "$RESPONSE" | jq -r '.id')
            PANEL=$(echo "$RESPONSE" | jq -r '.panelTitle')
            METRIC=$(echo "$RESPONSE" | jq -r '.metricName')
            SERVICE=$(echo "$RESPONSE" | jq -r '.service')
            echo -e "${GREEN}✓${NC} Created mapping #$count: $PANEL -> $METRIC -> $SERVICE ($ID)"
        fi
    done < <(jq -c '.[]' "$file")

    return $count
}

# Create mappings
if [ -n "$MAPPINGS_FILE" ]; then
    # Create from file
    create_from_file "$MAPPINGS_FILE"
    CREATED=$?
else
    # Auto-generate mappings
    echo -e "${GREEN}✓${NC} Creating auto-generated mappings..."
    echo ""

    CREATED=0
    FAILED=0

    for i in $(seq 1 $NUM_MAPPINGS); do
        # Select random panel configuration
        PANEL_CONFIG="${PANELS[$((RANDOM % ${#PANELS[@]}))]}"
        PANEL_TITLE=$(echo "$PANEL_CONFIG" | cut -d'|' -f1)
        METRIC_NAME=$(echo "$PANEL_CONFIG" | cut -d'|' -f2)

        # Select random service and region
        SERVICE="${SERVICES[$((RANDOM % ${#SERVICES[@]}))]}"
        REGION="${REGIONS[$((RANDOM % ${#REGIONS[@]}))]}"

        # Generate log stream name
        LOG_STREAM="$SERVICE-$REGION-stream-$i"

        # Create mapping
        RESPONSE=$(create_mapping "$ORG" "$DASHBOARD" "$PANEL_TITLE" "$METRIC_NAME" "$SERVICE" "$REGION" "$LOG_STREAM")

        # Check for errors
        ERROR=$(echo "$RESPONSE" | jq -r '.error // empty')
        if [ -n "$ERROR" ]; then
            FAILED=$((FAILED + 1))
            echo -e "${RED}✗${NC} Failed #$i: $ERROR"
        else
            CREATED=$((CREATED + 1))
            ID=$(echo "$RESPONSE" | jq -r '.id')
            echo -e "${GREEN}✓${NC} Created mapping #$i: $PANEL_TITLE -> $METRIC_NAME -> $SERVICE ($ID)"
        fi

        # Progress indicator
        if [ $((i % 5)) -eq 0 ]; then
            echo -e "${YELLOW}⟳${NC} Progress: $i/$NUM_MAPPINGS (Created: $CREATED, Failed: $FAILED)"
        fi

        # Small delay to avoid overwhelming the API
        sleep 0.1
    done
fi

echo ""
echo "================================"
echo -e "${GREEN}✅ Mapping creation complete${NC}"
echo ""
echo "📊 Summary:"
echo "   Created: $CREATED"
if [ "$FAILED" -gt 0 ]; then
    echo "   Failed:  $FAILED"
fi
echo ""

# Fetch and display current mappings
echo -e "${BLUE}🔍 Current mappings in database:${NC}"
MAPPINGS=$(curl -s "$ADMIN_URL/api/mappings")
MAPPING_COUNT=$(echo "$MAPPINGS" | jq '. | length')
echo "   Total mappings: $MAPPING_COUNT"
echo ""

# Show sample mappings
echo "Sample mappings:"
echo "$MAPPINGS" | jq -r '.[:3] | .[] | "   • \(.panelTitle) (\(.metricName)) -> \(.service)/\(.region)/\(.logStreamName)"'
echo ""

echo "🔍 View all mappings:"
echo "   curl $ADMIN_URL/api/mappings | jq ."
echo ""

echo "🔍 Query in ClickHouse:"
echo "   curl 'http://localhost:8123/?query=SELECT COUNT(*) FROM metric_log_mappings WHERE is_active=1'"
echo "   curl 'http://localhost:8123/?query=SELECT * FROM metric_log_hover_mv LIMIT 5 FORMAT Vertical'"
echo ""
