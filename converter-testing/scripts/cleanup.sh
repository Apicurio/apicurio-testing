#!/bin/bash

# Cleanup: Remove all converter test containers, networks, and volumes

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"

log() {
    echo "$1"
}

log "================================================================"
log "  Cleanup: Kafka Connect Converter Test"
log "================================================================"
log ""

# Parse arguments
REMOVE_VOLUMES=false
REMOVE_DATA=false
for arg in "$@"; do
    case $arg in
        --remove-volumes) REMOVE_VOLUMES=true ;;
        --remove-data) REMOVE_DATA=true ;;
    esac
done

# Delete connectors first (graceful shutdown)
log "Deleting connectors..."
for connector in avro-file-source avro-file-sink json-file-source json-file-sink; do
    if curl -sf "http://localhost:8083/connectors/$connector" > /dev/null 2>&1; then
        curl -s -X DELETE "http://localhost:8083/connectors/$connector" > /dev/null 2>&1
        log "  Deleted connector: $connector"
    fi
done
log ""

# Stop and remove containers
log "Stopping containers..."
for compose_file in docker-compose-connect.yml docker-compose-registry.yml docker-compose-kafka.yml; do
    if [ -f "$PROJECT_DIR/$compose_file" ]; then
        log "  Stopping services in $compose_file..."
        docker compose --env-file "$ENV_FILE" -f "$PROJECT_DIR/$compose_file" down 2>/dev/null || true
    fi
done
log ""

# Remove volumes
if [ "$REMOVE_VOLUMES" = true ]; then
    log "Removing volumes..."
    docker volume rm converter-connect-data 2>/dev/null || true
    log ""
fi

# Remove network
log "Removing network..."
docker network rm converter-test-network 2>/dev/null || true
log ""

# Remove data and logs
if [ "$REMOVE_DATA" = true ]; then
    log "Removing data and logs..."
    rm -rf "$PROJECT_DIR/data/"*
    rm -rf "$PROJECT_DIR/logs/"*
    log ""
fi

# Remove custom Docker image
log "Removing custom Docker image..."
docker rmi converter-testing-connect 2>/dev/null || true
log ""

log "================================================================"
log "  Cleanup completed"
log "================================================================"
log ""
log "To also remove volumes and data:"
log "  $0 --remove-volumes --remove-data"
log ""
