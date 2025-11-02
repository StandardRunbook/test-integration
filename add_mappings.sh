#!/bin/bash
# Add mappings/templates to the log-analysis service via ClickHouse
# This script populates the templates table which the log-ingest-service uses for matching

set -e

# Configuration
CLICKHOUSE_URL="${CLICKHOUSE_URL:-http://localhost:8123}"
TEMPLATES_FILE="${TEMPLATES_FILE:-../log_analysis/cache/comprehensive_templates.json}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}📋 Adding Templates/Mappings to ClickHouse${NC}"
echo ""

# Check if templates file exists
if [ ! -f "$TEMPLATES_FILE" ]; then
    echo -e "${RED}❌ Error: Templates file not found at $TEMPLATES_FILE${NC}"
    echo ""
    echo "To generate templates, run:"
    echo "  cd ../log_analysis"
    echo "  cargo run --release --example generate_comprehensive_templates"
    exit 1
fi

echo -e "${GREEN}✓${NC} Found templates file: $TEMPLATES_FILE"

# Check if ClickHouse is accessible
if ! curl -s "$CLICKHOUSE_URL/ping" > /dev/null 2>&1; then
    echo -e "${RED}❌ Error: ClickHouse not accessible at $CLICKHOUSE_URL${NC}"
    echo ""
    echo "Start services with:"
    echo "  docker-compose up -d clickhouse"
    exit 1
fi

echo -e "${GREEN}✓${NC} ClickHouse is accessible"
echo ""

# Count templates in file
TEMPLATE_COUNT=$(jq '.templates | length' "$TEMPLATES_FILE")
echo -e "${YELLOW}⟳${NC} Loading $TEMPLATE_COUNT templates from file..."
echo ""

# Parse JSON and insert into ClickHouse
jq -c '.templates | to_entries[] | {
    template_id: (.key + 1),
    pattern: .value.template,
    variables: (.value.parameters | map(.field)),
    example: .value.example_log
}' "$TEMPLATES_FILE" | \
curl -X POST "$CLICKHOUSE_URL/?query=INSERT%20INTO%20templates%20(template_id%2C%20pattern%2C%20variables%2C%20example)%20FORMAT%20JSONEachRow" \
    --data-binary @-

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ Templates loaded successfully${NC}"
    echo ""
else
    echo -e "${RED}❌ Failed to load templates${NC}"
    exit 1
fi

# Verify count in database
DB_TEMPLATE_COUNT=$(curl -s "$CLICKHOUSE_URL" --data "SELECT count() FROM templates")
echo "📊 Summary:"
echo "   Templates in file:     $TEMPLATE_COUNT"
echo "   Templates in database: $DB_TEMPLATE_COUNT"
echo ""

# Show some example templates
echo -e "${BLUE}🔍 Sample templates:${NC}"
curl -s "$CLICKHOUSE_URL" --data "SELECT template_id, pattern, example FROM templates LIMIT 5 FORMAT Vertical"
echo ""

echo -e "${GREEN}✅ Done!${NC}"
echo ""
echo "Next steps:"
echo "  1. Start the log-ingest-service: docker-compose up -d log-analysis"
echo "  2. Send logs: ./send_logs.sh"
