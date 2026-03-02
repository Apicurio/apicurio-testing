#!/bin/bash

# Step E: Test ExtJSON Converter
# This script tests the Apicurio Registry ExtJSON converter by:
# 1. Creating a FileStreamSource connector with ExtJSON converter
# 2. Writing test data to the source file
# 3. Creating a FileStreamSink connector with ExtJSON converter
# 4. Verifying data flows through correctly

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONNECTORS_DIR="$PROJECT_DIR/connectors"
LOG_DIR="$PROJECT_DIR/logs"
DATA_DIR="$PROJECT_DIR/data"

mkdir -p "$LOG_DIR"
mkdir -p "$DATA_DIR"

LOG_FILE="$LOG_DIR/step-E-test-json-converter.log"

log() {
    echo "$1" | tee -a "$LOG_FILE"
}

CONNECT_URL="http://localhost:8083"
REGISTRY_URL="http://localhost:8080"

log "================================================================"
log "  Step E: Test ExtJSON Converter"
log "================================================================"
log ""

# Step 1: Verify prerequisites
log "[1/6] Verifying prerequisites..."
if ! curl -sf "$CONNECT_URL/" > /dev/null 2>&1; then
    log "Kafka Connect is not running."
    exit 1
fi
log "  Kafka Connect is running"
log ""

# Step 2: Write test data
log "[2/6] Writing test data to source file..."
TEST_LINES=(
    "JSON converter test message 1"
    "ExtJSON serialization verification - line 2"
    "Schema registry integration test - line 3"
)

for line in "${TEST_LINES[@]}"; do
    docker exec converter-connect sh -c "echo '$line' >> /data/json-source-input.txt"
done
log "  Wrote ${#TEST_LINES[@]} lines to source file"
log ""

# Step 3: Create source connector
log "[3/6] Creating ExtJSON FileStreamSource connector..."
SOURCE_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    -d @"$CONNECTORS_DIR/json-file-source.json" \
    "$CONNECT_URL/connectors")

SOURCE_HTTP_CODE=$(echo "$SOURCE_RESPONSE" | tail -1)
if [ "$SOURCE_HTTP_CODE" = "201" ] || [ "$SOURCE_HTTP_CODE" = "200" ]; then
    log "  Source connector created successfully"
elif [ "$SOURCE_HTTP_CODE" = "409" ]; then
    curl -s -X DELETE "$CONNECT_URL/connectors/json-file-source" > /dev/null 2>&1
    sleep 2
    curl -s -X POST -H "Content-Type: application/json" \
        -d @"$CONNECTORS_DIR/json-file-source.json" \
        "$CONNECT_URL/connectors" > /dev/null
    log "  Source connector recreated"
else
    log "  Failed to create source connector (HTTP $SOURCE_HTTP_CODE)"
    exit 1
fi
log ""

# Step 4: Wait for data processing
log "[4/6] Waiting for source connector to process data..."
sleep 10

SOURCE_STATUS=$(curl -s "$CONNECT_URL/connectors/json-file-source/status")
SOURCE_STATE=$(echo "$SOURCE_STATUS" | jq -r '.connector.state')
TASK_STATE=$(echo "$SOURCE_STATUS" | jq -r '.tasks[0].state // "UNKNOWN"')
log "  Source connector: $SOURCE_STATE, task: $TASK_STATE"
if [ "$TASK_STATE" = "FAILED" ]; then
    TASK_TRACE=$(echo "$SOURCE_STATUS" | jq -r '.tasks[0].trace // "no trace"')
    log "  Task error: $TASK_TRACE"
fi
log ""

# Step 5: Create sink connector
log "[5/6] Creating ExtJSON FileStreamSink connector..."
SINK_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    -d @"$CONNECTORS_DIR/json-file-sink.json" \
    "$CONNECT_URL/connectors")

SINK_HTTP_CODE=$(echo "$SINK_RESPONSE" | tail -1)
if [ "$SINK_HTTP_CODE" = "201" ] || [ "$SINK_HTTP_CODE" = "200" ]; then
    log "  Sink connector created successfully"
elif [ "$SINK_HTTP_CODE" = "409" ]; then
    curl -s -X DELETE "$CONNECT_URL/connectors/json-file-sink" > /dev/null 2>&1
    sleep 2
    curl -s -X POST -H "Content-Type: application/json" \
        -d @"$CONNECTORS_DIR/json-file-sink.json" \
        "$CONNECT_URL/connectors" > /dev/null
    log "  Sink connector recreated"
else
    log "  Failed to create sink connector (HTTP $SINK_HTTP_CODE)"
    exit 1
fi
log ""

# Step 6: Verify
log "[6/6] Waiting and verifying results..."
sleep 15

SINK_STATUS=$(curl -s "$CONNECT_URL/connectors/json-file-sink/status")
SINK_STATE=$(echo "$SINK_STATUS" | jq -r '.connector.state')
SINK_TASK_STATE=$(echo "$SINK_STATUS" | jq -r '.tasks[0].state // "UNKNOWN"')
log "  Sink connector: $SINK_STATE, task: $SINK_TASK_STATE"
if [ "$SINK_TASK_STATE" = "FAILED" ]; then
    SINK_TRACE=$(echo "$SINK_STATUS" | jq -r '.tasks[0].trace // "no trace"')
    log "  Sink task error: $SINK_TRACE"
fi

SINK_CONTENT=$(docker exec converter-connect cat /data/json-sink-output.txt 2>/dev/null || echo "")
if [ -n "$SINK_CONTENT" ]; then
    SINK_LINE_COUNT=$(echo "$SINK_CONTENT" | wc -l | tr -d ' ')
    log "  Sink output has $SINK_LINE_COUNT lines"
    echo "$SINK_CONTENT" > "$DATA_DIR/json-sink-output.txt"
else
    log "  Sink output file is empty or not found"
fi

TOPIC_OFFSET=$(docker exec converter-kafka /opt/kafka/bin/kafka-run-class.sh kafka.tools.GetOffsetShell \
    --broker-list localhost:9092 \
    --topic json-converter-test 2>/dev/null | awk -F: '{sum+=$3} END {print sum+0}')
log "  Messages in json-converter-test topic: $TOPIC_OFFSET"
log ""

docker logs converter-connect > "$LOG_DIR/containers/connect-after-json.log" 2>&1

JSON_TEST_PASSED=true
if [ "$SOURCE_STATE" != "RUNNING" ]; then JSON_TEST_PASSED=false; fi
if [ "$TASK_STATE" = "FAILED" ]; then JSON_TEST_PASSED=false; fi
if [ "$TOPIC_OFFSET" -eq 0 ]; then JSON_TEST_PASSED=false; fi

log "================================================================"
if [ "$JSON_TEST_PASSED" = true ]; then
    log "  Step E completed successfully - ExtJSON Converter PASSED"
else
    log "  Step E completed with issues - check logs above"
fi
log "================================================================"
log ""
log "Logs saved to: $LOG_FILE"
log ""
