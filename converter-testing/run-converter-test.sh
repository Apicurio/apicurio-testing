#!/bin/bash

# Run All Steps - Kafka Connect Converter Test
#
# This script runs all test steps in sequence to validate the
# Apicurio Registry Kafka Connect converter package.
#
# Usage:
#   ./run-converter-test.sh                              # Run with defaults
#   ./run-converter-test.sh --interactive                # Pause between steps
#   ./run-converter-test.sh --kafka-version 3.8.1        # Test specific Kafka version
#   ./run-converter-test.sh --apicurio-version 3.0.7.Final  # Test specific Registry version

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$SCRIPT_DIR/scripts"
LOG_DIR="$SCRIPT_DIR/logs"

mkdir -p "$LOG_DIR"

MASTER_LOG="$LOG_DIR/run-converter-test.log"

log() {
    echo "$1" | tee -a "$MASTER_LOG"
}

# Parse arguments
PAUSE_BETWEEN_STEPS=false
KAFKA_VERSION=""
APICURIO_VERSION=""
REGISTRY_IMAGE=""
SKIP_JAVA_TEST=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --interactive)
            PAUSE_BETWEEN_STEPS=true
            shift
            ;;
        --kafka-version)
            KAFKA_VERSION="$2"
            shift 2
            ;;
        --apicurio-version)
            APICURIO_VERSION="$2"
            shift 2
            ;;
        --registry-image)
            REGISTRY_IMAGE="$2"
            shift 2
            ;;
        --skip-java-test)
            SKIP_JAVA_TEST=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--interactive] [--kafka-version VERSION] [--apicurio-version VERSION] [--registry-image IMAGE] [--skip-java-test]"
            exit 1
            ;;
    esac
done

# Update .env file if custom versions are specified
ENV_FILE="$SCRIPT_DIR/.env"
if [ -n "$KAFKA_VERSION" ]; then
    sed -i.bak "s/^KAFKA_VERSION=.*/KAFKA_VERSION=$KAFKA_VERSION/" "$ENV_FILE"
    rm -f "$ENV_FILE.bak"
    log "Using Kafka version: $KAFKA_VERSION"
fi
if [ -n "$APICURIO_VERSION" ]; then
    sed -i.bak "s/^APICURIO_VERSION=.*/APICURIO_VERSION=$APICURIO_VERSION/" "$ENV_FILE"
    rm -f "$ENV_FILE.bak"
    log "Using Apicurio version: $APICURIO_VERSION"
fi
if [ -n "$REGISTRY_IMAGE" ]; then
    sed -i.bak "s|^REGISTRY_IMAGE=.*|REGISTRY_IMAGE=$REGISTRY_IMAGE|" "$ENV_FILE"
    rm -f "$ENV_FILE.bak"
    log "Using Registry image: $REGISTRY_IMAGE"
fi

# Read current versions from .env
source "$ENV_FILE"

pause_step() {
    if [ "$PAUSE_BETWEEN_STEPS" = true ]; then
        log ""
        log "Press Enter to continue to next step..."
        read -r
    else
        sleep 2
    fi
}

log "================================================================"
log "  Kafka Connect Converter Test"
log "  Apicurio Registry Converter Package Validation"
log "================================================================"
log ""
log "Configuration:"
log "  Kafka Version: ${KAFKA_VERSION:-default}"
log "  Apicurio Version: ${APICURIO_VERSION:-default}"
log "  Registry Image: ${REGISTRY_IMAGE:-default}"
log ""
log "Test Steps:"
log "  A. Deploy Kafka"
log "  B. Deploy Apicurio Registry"
log "  C. Deploy Kafka Connect (with Apicurio converter)"
log "  D. Test Avro Converter"
log "  E. Test ExtJSON Converter"
log "  F. Verify Schemas in Registry"
if [ "$SKIP_JAVA_TEST" = false ]; then
    log "  G. Run Java Converter Test Client"
fi
log ""
log "Master log: $MASTER_LOG"
log ""

if [ "$PAUSE_BETWEEN_STEPS" = true ]; then
    log "Press Enter to start..."
    read -r
else
    log "Running in automatic mode"
    sleep 2
fi

# Track test results
STEP_RESULTS=()
record_result() {
    STEP_RESULTS+=("$1")
}

# Step A: Deploy Kafka
log ""
log "================================================================"
log "  STEP A: Deploy Kafka"
log "================================================================"
if "$SCRIPTS_DIR/step-A-deploy-kafka.sh" 2>&1 | tee -a "$MASTER_LOG"; then
    record_result "A-Deploy-Kafka: PASSED"
else
    record_result "A-Deploy-Kafka: FAILED"
    log "FATAL: Kafka deployment failed. Aborting."
    exit 1
fi
pause_step

# Step B: Deploy Registry
log ""
log "================================================================"
log "  STEP B: Deploy Apicurio Registry"
log "================================================================"
if "$SCRIPTS_DIR/step-B-deploy-registry.sh" 2>&1 | tee -a "$MASTER_LOG"; then
    record_result "B-Deploy-Registry: PASSED"
else
    record_result "B-Deploy-Registry: FAILED"
    log "FATAL: Registry deployment failed. Aborting."
    exit 1
fi
pause_step

# Step C: Deploy Kafka Connect
log ""
log "================================================================"
log "  STEP C: Deploy Kafka Connect"
log "================================================================"
if "$SCRIPTS_DIR/step-C-deploy-connect.sh" 2>&1 | tee -a "$MASTER_LOG"; then
    record_result "C-Deploy-Connect: PASSED"
else
    record_result "C-Deploy-Connect: FAILED"
    log "FATAL: Kafka Connect deployment failed. Aborting."
    exit 1
fi
pause_step

# Step D: Test Avro Converter
log ""
log "================================================================"
log "  STEP D: Test Avro Converter"
log "================================================================"
if "$SCRIPTS_DIR/step-D-test-avro-converter.sh" 2>&1 | tee -a "$MASTER_LOG"; then
    record_result "D-Avro-Converter: PASSED"
else
    record_result "D-Avro-Converter: FAILED"
fi
pause_step

# Step E: Test ExtJSON Converter
log ""
log "================================================================"
log "  STEP E: Test ExtJSON Converter"
log "================================================================"
if "$SCRIPTS_DIR/step-E-test-json-converter.sh" 2>&1 | tee -a "$MASTER_LOG"; then
    record_result "E-ExtJSON-Converter: PASSED"
else
    record_result "E-ExtJSON-Converter: FAILED"
fi
pause_step

# Step F: Verify Schemas
log ""
log "================================================================"
log "  STEP F: Verify Schemas in Registry"
log "================================================================"
if "$SCRIPTS_DIR/step-F-verify-schemas.sh" 2>&1 | tee -a "$MASTER_LOG"; then
    record_result "F-Verify-Schemas: PASSED"
else
    record_result "F-Verify-Schemas: FAILED"
fi
pause_step

# Step G: Java Converter Test (optional)
if [ "$SKIP_JAVA_TEST" = false ] && [ -d "$SCRIPT_DIR/clients/converter-test" ]; then
    log ""
    log "================================================================"
    log "  STEP G: Java Converter Test Client"
    log "================================================================"
    if "$SCRIPTS_DIR/build-and-run-client.sh" 2>&1 | tee -a "$MASTER_LOG"; then
        record_result "G-Java-Converter-Test: PASSED"
    else
        record_result "G-Java-Converter-Test: FAILED"
    fi
fi

# Final summary
log ""
log "================================================================"
log "  TEST RESULTS SUMMARY"
log "================================================================"
log ""
log "Configuration:"
log "  Kafka Version: ${KAFKA_VERSION}"
log "  Apicurio Version: ${APICURIO_VERSION}"
log "  Registry Image: ${REGISTRY_IMAGE}"
log ""

TOTAL_PASSED=0
TOTAL_FAILED=0
for result in "${STEP_RESULTS[@]}"; do
    if [[ "$result" == *"PASSED"* ]]; then
        log "  PASS: $result"
        TOTAL_PASSED=$((TOTAL_PASSED + 1))
    else
        log "  FAIL: $result"
        TOTAL_FAILED=$((TOTAL_FAILED + 1))
    fi
done

log ""
log "Total: $((TOTAL_PASSED + TOTAL_FAILED)) tests"
log "  Passed: $TOTAL_PASSED"
log "  Failed: $TOTAL_FAILED"
log ""

if [ "$TOTAL_FAILED" -gt 0 ]; then
    log "OVERALL: FAILED"
    log ""
    log "Check individual step logs in: $LOG_DIR/"
else
    log "OVERALL: PASSED"
fi

log ""
log "All logs saved to: $LOG_DIR"
log "Master log: $MASTER_LOG"
log ""
log "To clean up:"
log "  ./scripts/cleanup.sh"
log "  ./scripts/cleanup.sh --remove-volumes --remove-data"
log ""

# Exit with failure if any test failed
if [ "$TOTAL_FAILED" -gt 0 ]; then
    exit 1
fi
