#!/bin/bash

# Build and Run the Java Converter Test Client
# This script builds the converter-test Maven project and runs it
# against the deployed Apicurio Registry.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CLIENT_DIR="$PROJECT_DIR/clients/converter-test"
LOG_DIR="$PROJECT_DIR/logs"

mkdir -p "$LOG_DIR"

LOG_FILE="$LOG_DIR/build-and-run-client.log"

log() {
    echo "$1" | tee -a "$LOG_FILE"
}

log "================================================================"
log "  Build and Run Java Converter Test Client"
log "================================================================"
log ""

# Verify prerequisites
log "[1/3] Verifying prerequisites..."
if ! curl -sf http://localhost:8080/health/ready > /dev/null 2>&1; then
    log "Apicurio Registry is not running. Please deploy it first."
    exit 1
fi
log "  Apicurio Registry is accessible"

if [ ! -f "$CLIENT_DIR/pom.xml" ]; then
    log "Client project not found at: $CLIENT_DIR"
    exit 1
fi
log "  Client project found"
log ""

# Build the client
log "[2/3] Building converter test client..."
cd "$CLIENT_DIR"
if mvn clean package -DskipTests 2>&1 | tee -a "$LOG_FILE"; then
    log ""
    log "  Build successful"
else
    log ""
    log "  Build failed"
    exit 1
fi
log ""

# Run the client
JAR_PATH="$CLIENT_DIR/target/converter-test-1.0.0-SNAPSHOT.jar"
if [ ! -f "$JAR_PATH" ]; then
    log "JAR not found: $JAR_PATH"
    exit 1
fi

log "[3/3] Running converter test client..."
log ""

export REGISTRY_URL="http://localhost:8080/apis/registry/v3"

if java -jar "$JAR_PATH" 2>&1 | tee -a "$LOG_FILE"; then
    log ""
    log "================================================================"
    log "  Java Converter Test Client completed successfully"
    log "================================================================"
else
    log ""
    log "================================================================"
    log "  Java Converter Test Client FAILED"
    log "================================================================"
    exit 1
fi
log ""
log "Logs saved to: $LOG_FILE"
log ""
