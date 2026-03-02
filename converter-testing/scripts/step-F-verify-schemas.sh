#!/bin/bash

# Step F: Verify Schemas in Apicurio Registry
# This script verifies that the Kafka Connect converters correctly
# registered schemas in the Apicurio Registry.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LOG_DIR="$PROJECT_DIR/logs"
DATA_DIR="$PROJECT_DIR/data"

mkdir -p "$LOG_DIR"
mkdir -p "$DATA_DIR"

LOG_FILE="$LOG_DIR/step-F-verify-schemas.log"

log() {
    echo "$1" | tee -a "$LOG_FILE"
}

REGISTRY_URL="http://localhost:8080"
REGISTRY_API="$REGISTRY_URL/apis/registry/v3"

log "================================================================"
log "  Step F: Verify Schemas in Apicurio Registry"
log "================================================================"
log ""

# Step 1: List all groups
log "[1/4] Listing groups..."
GROUPS=$(curl -s "$REGISTRY_API/groups" | jq -r '.groups[].groupId' 2>/dev/null || echo "")
if [ -n "$GROUPS" ]; then
    echo "$GROUPS" | while IFS= read -r group; do
        log "  Group: $group"
    done
else
    log "  No groups found (artifacts may be in the default group)"
fi
log ""

# Step 2: Search for all artifacts
log "[2/4] Searching for registered artifacts..."
SEARCH_RESULT=$(curl -s "$REGISTRY_API/search/artifacts")
ARTIFACT_COUNT=$(echo "$SEARCH_RESULT" | jq -r '.count // 0' 2>/dev/null)
log "  Total artifacts registered: $ARTIFACT_COUNT"
log ""

if [ "$ARTIFACT_COUNT" -gt 0 ]; then
    echo "$SEARCH_RESULT" | jq -r '.artifacts[] | "  - [\(.groupId // "default")] \(.artifactId) (type: \(.artifactType // "unknown"))"' 2>/dev/null | tee -a "$LOG_FILE"
    log ""
fi

# Step 3: Get details for each artifact
log "[3/4] Getting artifact details..."
if [ "$ARTIFACT_COUNT" -gt 0 ]; then
    echo "$SEARCH_RESULT" | jq -c '.artifacts[]' 2>/dev/null | while IFS= read -r artifact; do
        GROUP_ID=$(echo "$artifact" | jq -r '.groupId // "default"')
        ARTIFACT_ID=$(echo "$artifact" | jq -r '.artifactId')
        ARTIFACT_TYPE=$(echo "$artifact" | jq -r '.artifactType // "unknown"')

        log ""
        log "  Artifact: $ARTIFACT_ID"
        log "    Group: $GROUP_ID"
        log "    Type: $ARTIFACT_TYPE"

        # Get versions
        VERSIONS=$(curl -s "$REGISTRY_API/groups/$GROUP_ID/artifacts/$ARTIFACT_ID/versions")
        VERSION_COUNT=$(echo "$VERSIONS" | jq -r '.count // 0' 2>/dev/null)
        log "    Versions: $VERSION_COUNT"

        # Get latest version content
        LATEST_VERSION=$(echo "$VERSIONS" | jq -r '.versions[0].version // "1"' 2>/dev/null)
        CONTENT=$(curl -s "$REGISTRY_API/groups/$GROUP_ID/artifacts/$ARTIFACT_ID/versions/$LATEST_VERSION/content" 2>/dev/null)
        if [ -n "$CONTENT" ]; then
            log "    Latest version ($LATEST_VERSION) content:"
            echo "$CONTENT" | jq '.' 2>/dev/null | head -20 | while IFS= read -r line; do
                log "      $line"
            done
            # If jq failed (not JSON), show raw content
            if [ $? -ne 0 ]; then
                echo "$CONTENT" | head -5 | while IFS= read -r line; do
                    log "      $line"
                done
            fi
        fi
    done
else
    log "  No artifacts to inspect"
fi
log ""

# Step 4: Generate summary report
log "[4/4] Generating verification report..."
REPORT_FILE="$DATA_DIR/schema-verification-report.txt"

cat > "$REPORT_FILE" <<EOF
================================================================
  Schema Verification Report
================================================================

Date: $(date)
Registry URL: $REGISTRY_URL

Artifacts Registered: $ARTIFACT_COUNT

Groups:
$(echo "$GROUPS" | sed 's/^/  - /' 2>/dev/null || echo "  (none)")

Artifacts:
$(echo "$SEARCH_RESULT" | jq -r '.artifacts[] | "  - [\(.groupId // "default")] \(.artifactId) (type: \(.artifactType // "unknown"))"' 2>/dev/null || echo "  (none)")

Connector Status:
$(curl -s http://localhost:8083/connectors 2>/dev/null | jq -r '.[]' 2>/dev/null | while read -r name; do
    STATUS=$(curl -s "http://localhost:8083/connectors/$name/status" | jq -r '.connector.state' 2>/dev/null)
    echo "  - $name: $STATUS"
done)

================================================================
EOF

log "Report saved to: $REPORT_FILE"
log ""

log "================================================================"
if [ "$ARTIFACT_COUNT" -gt 0 ]; then
    log "  Step F completed - $ARTIFACT_COUNT schemas verified"
else
    log "  Step F completed - No schemas found in registry"
    log "  Note: This may be expected if FileStreamSource produces"
    log "  simple string data without a complex schema."
fi
log "================================================================"
log ""
log "Logs saved to: $LOG_FILE"
log ""
