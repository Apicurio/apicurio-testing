#!/bin/bash

# Test script for Apicurio Registry Operator TLS feature (issue #3472).
# Validates that the operator correctly configures TLS on Ingresses/Routes
# when tlsTermination and tlsSecretName are set in the ApicurioRegistry3 CR.
#
# Supported TLS modes:
#   - edge-tls:           Edge-terminated TLS with a user-provided TLS secret
#   - openshift-edge-tls: Edge-terminated TLS using the default OpenShift router certificate
#
# Usage:
#   ./test-operator-tls.sh --cluster <cluster> --namespace <namespace> --mode <edge-tls|openshift-edge-tls>

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$BASE_DIR/shared.sh"

show_usage() {
    echo "Usage: $0 --namespace <namespace> [OPTIONS]"
    echo ""
    echo "REQUIRED PARAMETERS:"
    echo "  --namespace <namespace>   Kubernetes namespace to deploy into"
    echo ""
    echo "OPTIONAL PARAMETERS:"
    echo "  --cluster <name>          OpenShift cluster name (default: \$USER)"
    echo "  --mode <mode>             TLS mode to test (default: edge-tls)"
    echo "                            Modes: edge-tls, openshift-edge-tls"
    echo "  --tlsSecretName <name>    Name of TLS secret (default: apicurio-tls-cert)"
    echo "                            Only used for edge-tls mode"
    echo "  --appName <name>          Application name (default: registry)"
    echo "  -h, --help                Display this help message"
    echo ""
    echo "EXAMPLES:"
    echo "  # Test edge-terminated TLS with a user-provided certificate:"
    echo "  $0 --cluster rosa1 --namespace tlstest --mode edge-tls --tlsSecretName my-cert"
    echo ""
    echo "  # Test OpenShift edge TLS with default router certificate:"
    echo "  $0 --cluster rosa1 --namespace tlstest --mode openshift-edge-tls"
}

# Parse arguments
APPLICATION_NAME=""
CLUSTER_NAME="$USER"
NAMESPACE=""
TLS_MODE="edge-tls"
TLS_SECRET_NAME="apicurio-tls-cert"

while [[ $# -gt 0 ]]; do
    case $1 in
        --appName)
            APPLICATION_NAME="$2"
            shift 2
            ;;
        --cluster)
            CLUSTER_NAME="$2"
            shift 2
            ;;
        --namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        --mode)
            TLS_MODE="$2"
            shift 2
            ;;
        --tlsSecretName)
            TLS_SECRET_NAME="$2"
            shift 2
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

if [ -z "$APPLICATION_NAME" ]; then
    APPLICATION_NAME="registry"
fi

if [ -z "$NAMESPACE" ]; then
    echo "Error: --namespace is required"
    show_usage
    exit 1
fi

if [[ ! "$NAMESPACE" =~ ^[a-zA-Z0-9]+$ ]]; then
    echo "Error: Namespace '$NAMESPACE' is invalid. It must contain only letters and numbers."
    exit 1
fi

# Validate TLS mode
case "$TLS_MODE" in
    edge-tls|openshift-edge-tls)
        ;;
    *)
        echo "Error: Invalid TLS mode '$TLS_MODE'. Must be one of: edge-tls, openshift-edge-tls"
        exit 1
        ;;
esac

load_cluster_config "$CLUSTER_NAME"

export APPLICATION_NAME
export CLUSTER_NAME
export NAMESPACE
export TLS_SECRET_NAME
export BASE_DOMAIN="apicurio-testing.org"
export APPS_URL="apps.$CLUSTER_NAME.$BASE_DOMAIN"
export APP_INGRESS_URL="registry-app-$NAMESPACE.$APPS_URL"
export UI_INGRESS_URL="registry-ui-$NAMESPACE.$APPS_URL"
export APPS_DIR="$CLUSTER_DIR/namespaces/$NAMESPACE/apps"
export APP_DIR="$APPS_DIR/$APPLICATION_NAME"

mkdir -p "$APP_DIR"

PROFILE_DIR="$BASE_DIR/templates/profiles/$TLS_MODE"
if [ ! -d "$PROFILE_DIR" ]; then
    error_exit "Profile directory not found: $PROFILE_DIR"
fi

# ##################################################
# Create namespace if needed
# ##################################################
echo "Checking if namespace '$NAMESPACE' exists..."
if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    echo "Namespace '$NAMESPACE' already exists"
else
    echo "Creating namespace: $NAMESPACE"
    kubectl create namespace "$NAMESPACE"
fi

# ##################################################
# Deploy the ApicurioRegistry3 CR
# ##################################################
important "Deploying Apicurio Registry with TLS mode: $TLS_MODE"

YAML_FILES=$(find "$PROFILE_DIR" -name "*.yaml" -o -name "*.yml" | sort)
if [ -n "$YAML_FILES" ]; then
    echo "$YAML_FILES" | while read -r YAML_FILE; do
        YAML_FILE_NAME=$(basename "$YAML_FILE")
        FROM_TEMPLATE="$YAML_FILE"
        TO_CLUSTER="$APP_DIR/$YAML_FILE_NAME"
        echo "Applying configuration from: $FROM_TEMPLATE"
        envsubst < "$FROM_TEMPLATE" > "$TO_CLUSTER"
        kubectl apply -f "$TO_CLUSTER" -n "$NAMESPACE"
    done
else
    error_exit "No YAML files found in profile directory: $PROFILE_DIR"
fi

# ##################################################
# Wait for deployments to be ready
# ##################################################
important "Waiting for deployments to become ready..."

wait_for "app deployment ready" 600 kubectl rollout status deployment "${APPLICATION_NAME}-app-deployment" -n "$NAMESPACE" --timeout=10s
if [[ $? -ne 0 ]]; then
    error "App deployment did not become ready"
    kubectl get deployments -n "$NAMESPACE" -o wide
    kubectl get pods -n "$NAMESPACE" -o wide
    error_exit "App deployment failed"
fi
success "App deployment is ready"

wait_for "UI deployment ready" 600 kubectl rollout status deployment "${APPLICATION_NAME}-ui-deployment" -n "$NAMESPACE" --timeout=10s
if [[ $? -ne 0 ]]; then
    error "UI deployment did not become ready"
    kubectl get deployments -n "$NAMESPACE" -o wide
    kubectl get pods -n "$NAMESPACE" -o wide
    error_exit "UI deployment failed"
fi
success "UI deployment is ready"

# ##################################################
# Validate Ingress TLS configuration
# ##################################################
ERRORS=0

validate_ingress_tls() {
    local component="$1"      # app or ui
    local ingress_name="${APPLICATION_NAME}-${component}-ingress"

    important "Validating Ingress TLS for: $ingress_name"

    local ingress_json
    ingress_json=$(kubectl get ingress "$ingress_name" -n "$NAMESPACE" -o json 2>/dev/null)
    if [[ $? -ne 0 || -z "$ingress_json" ]]; then
        error "Ingress $ingress_name not found"
        ERRORS=$((ERRORS + 1))
        return
    fi

    # Check TLS section exists
    local tls_count
    tls_count=$(echo "$ingress_json" | jq '.spec.tls | length')
    if [[ "$tls_count" -lt 1 ]]; then
        error "Ingress $ingress_name has no TLS section (expected at least 1)"
        ERRORS=$((ERRORS + 1))
    else
        success "Ingress $ingress_name has TLS section ($tls_count entries)"
    fi

    # Check TLS host
    local tls_host
    tls_host=$(echo "$ingress_json" | jq -r '.spec.tls[0].hosts[0] // empty')
    if [[ -z "$tls_host" ]]; then
        error "Ingress $ingress_name TLS section has no host"
        ERRORS=$((ERRORS + 1))
    else
        success "Ingress $ingress_name TLS host: $tls_host"
    fi

    # Check TLS secret name (only for edge-tls mode, not for openshift-edge-tls)
    if [[ "$TLS_MODE" == "edge-tls" ]]; then
        local tls_secret
        tls_secret=$(echo "$ingress_json" | jq -r '.spec.tls[0].secretName // empty')
        if [[ -z "$tls_secret" ]]; then
            error "Ingress $ingress_name TLS section has no secretName (expected for edge-tls mode)"
            ERRORS=$((ERRORS + 1))
        elif [[ "$tls_secret" == "$TLS_SECRET_NAME" ]]; then
            success "Ingress $ingress_name TLS secretName matches: $tls_secret"
        else
            error "Ingress $ingress_name TLS secretName mismatch: expected=$TLS_SECRET_NAME, actual=$tls_secret"
            ERRORS=$((ERRORS + 1))
        fi
    else
        # openshift-edge-tls: no secret name expected
        local tls_secret
        tls_secret=$(echo "$ingress_json" | jq -r '.spec.tls[0].secretName // empty')
        if [[ -z "$tls_secret" || "$tls_secret" == "null" ]]; then
            success "Ingress $ingress_name correctly has no TLS secretName (OpenShift default cert)"
        else
            error "Ingress $ingress_name has unexpected TLS secretName: $tls_secret"
            ERRORS=$((ERRORS + 1))
        fi
    fi

    # Check route.openshift.io/termination annotation
    local termination_annotation
    termination_annotation=$(echo "$ingress_json" | jq -r '.metadata.annotations["route.openshift.io/termination"] // empty')
    if [[ "$termination_annotation" == "edge" ]]; then
        success "Ingress $ingress_name has correct annotation: route.openshift.io/termination=edge"
    else
        error "Ingress $ingress_name missing or wrong annotation: route.openshift.io/termination (expected=edge, actual=$termination_annotation)"
        ERRORS=$((ERRORS + 1))
    fi

    # Check backend port is "http" (edge termination means TLS is terminated at the router, not the app)
    local backend_port
    backend_port=$(echo "$ingress_json" | jq -r '.spec.rules[0].http.paths[0].backend.service.port.name // empty')
    if [[ "$backend_port" == "http" ]]; then
        success "Ingress $ingress_name backend port is correctly 'http' (edge termination)"
    else
        error "Ingress $ingress_name backend port mismatch: expected=http, actual=$backend_port"
        ERRORS=$((ERRORS + 1))
    fi
}

# Validate both app and ui ingresses
validate_ingress_tls "app"
validate_ingress_tls "ui"

# ##################################################
# Validate OpenShift Routes (if running on OpenShift)
# ##################################################
validate_route_tls() {
    local component="$1"
    local route_name="${APPLICATION_NAME}-${component}-ingress"

    important "Validating OpenShift Route for: $route_name"

    local route_json
    route_json=$(kubectl get route "$route_name" -n "$NAMESPACE" -o json 2>/dev/null)
    if [[ $? -ne 0 || -z "$route_json" ]]; then
        warning "Route $route_name not found (may not be running on OpenShift)"
        return
    fi

    # Check TLS termination on the Route
    local route_termination
    route_termination=$(echo "$route_json" | jq -r '.spec.tls.termination // empty')
    if [[ "$route_termination" == "edge" ]]; then
        success "Route $route_name has correct TLS termination: edge"
    else
        error "Route $route_name TLS termination mismatch: expected=edge, actual=$route_termination"
        ERRORS=$((ERRORS + 1))
    fi
}

# Check if we're on OpenShift (routes are available)
if kubectl api-resources | grep -q "routes.*route.openshift.io" 2>/dev/null; then
    important "OpenShift detected, validating Routes..."
    validate_route_tls "app"
    validate_route_tls "ui"
else
    warning "Not running on OpenShift, skipping Route validation"
fi

# ##################################################
# Test HTTPS connectivity
# ##################################################
important "Testing HTTPS connectivity..."

HEALTH_URL="https://$APP_INGRESS_URL/health/ready"
echo "Polling health endpoint: $HEALTH_URL"

# Wait for HTTPS health endpoint to respond
TIMEOUT=300
INTERVAL=5
START_TIME=$(date +%s)
END_TIME=$((START_TIME + TIMEOUT))

# Initial wait
echo "Waiting 30 seconds before starting HTTPS health check..."
sleep 30

HTTPS_OK=false
while [ $(date +%s) -lt $END_TIME ]; do
    response=$(curl -sk --max-time 10 "$HEALTH_URL" 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$response" ]; then
        status=$(echo "$response" | jq -r '.status // empty' 2>/dev/null)
        if [ "$status" = "UP" ]; then
            HTTPS_OK=true
            break
        fi
    fi
    echo "HTTPS health endpoint not ready yet, waiting ${INTERVAL}s..."
    sleep $INTERVAL
done

if $HTTPS_OK; then
    success "HTTPS health endpoint is UP at $HEALTH_URL"
else
    error "HTTPS health endpoint did not become ready at $HEALTH_URL"
    ERRORS=$((ERRORS + 1))
fi

# ##################################################
# Verify HTTP-to-HTTPS redirect (for edge termination)
# ##################################################
important "Verifying HTTP-to-HTTPS redirect..."

HTTP_URL="http://$APP_INGRESS_URL/health/ready"
http_status=$(curl -sk -o /dev/null -w "%{http_code}" -L --max-time 10 "$HTTP_URL" 2>/dev/null)
if [[ "$http_status" == "200" ]]; then
    success "HTTP request to $HTTP_URL was redirected and returned 200"
elif [[ "$http_status" == "301" || "$http_status" == "302" ]]; then
    success "HTTP request to $HTTP_URL returned redirect ($http_status)"
else
    warning "HTTP request to $HTTP_URL returned status $http_status (redirect may not be configured)"
fi

# ##################################################
# Summary
# ##################################################
echo ""
echo "=========================================="
echo "TLS TEST SUMMARY"
echo "=========================================="
echo "  TLS Mode:     $TLS_MODE"
echo "  Cluster:      $CLUSTER_NAME"
echo "  Namespace:    $NAMESPACE"
echo "  App Ingress:  $APP_INGRESS_URL"
echo "  UI Ingress:   $UI_INGRESS_URL"
echo "  Errors:       $ERRORS"
echo "=========================================="

if [[ $ERRORS -gt 0 ]]; then
    error_exit "TLS tests failed with $ERRORS error(s)"
else
    success_exit "All TLS tests passed!"
fi
