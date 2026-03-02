#!/bin/bash

# Step B: Deploy Apicurio Registry
# This script deploys Apicurio Registry in in-memory (H2) mode

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
COMPOSE_FILE="$PROJECT_DIR/docker-compose-registry.yml"
ENV_FILE="$PROJECT_DIR/.env"
LOG_DIR="$PROJECT_DIR/logs"
CONTAINER_LOG_DIR="$LOG_DIR/containers"

mkdir -p "$LOG_DIR"
mkdir -p "$CONTAINER_LOG_DIR"

LOG_FILE="$LOG_DIR/step-B-deploy-registry.log"

log() {
    echo "$1" | tee -a "$LOG_FILE"
}

wait_for_url() {
    local url=$1
    local timeout=${2:-60}
    local interval=2
    local elapsed=0

    log "Waiting for $url to be healthy (timeout: ${timeout}s)..."
    while [ $elapsed -lt $timeout ]; do
        if curl -sf "$url" > /dev/null 2>&1; then
            log "Health check passed after ${elapsed}s"
            return 0
        fi
        echo -n "."
        sleep $interval
        elapsed=$((elapsed + interval))
    done

    log ""
    log "Health check failed after ${timeout}s"
    return 1
}

log "================================================================"
log "  Step B: Deploy Apicurio Registry"
log "================================================================"
log ""

# Step 1: Start Registry
log "[1/3] Starting Apicurio Registry (in-memory mode)..."
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d
log ""

# Step 2: Wait for Registry to be ready
log "[2/3] Waiting for Registry to be ready..."
if ! wait_for_url "http://localhost:8080/health/ready" 60; then
    log ""
    log "Failed to start Registry. Check logs:"
    log "  docker logs converter-registry"
    exit 1
fi
log ""

# Step 3: Verify Registry
log "[3/3] Verifying Registry..."
SYSTEM_INFO=$(curl -s http://localhost:8080/apis/registry/v3/system/info)
log "Registry System Info:"
log "  $SYSTEM_INFO"
log ""

# Collect container logs
docker logs converter-registry > "$CONTAINER_LOG_DIR/registry-initial.log" 2>&1

log "================================================================"
log "  Step B completed successfully"
log "================================================================"
log ""
log "Apicurio Registry is running at: http://localhost:8080"
log "API v3 URL: http://localhost:8080/apis/registry/v3"
log "Logs saved to: $LOG_FILE"
log ""
