#!/bin/bash

# Get the directory where this script is located
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$BASE_DIR/shared.sh"

AVAILABLE_PROFILES=$(ls -1 "$BASE_DIR/templates/profiles" 2>/dev/null | tr '\n' ', ' | sed 's/,$//')

# ##################################################
# Function to display usage information
# ##################################################
show_usage() {
    echo "Usage: $0 [--cluster <cluster_name>] --namespace <namespace> [OPTIONS]"
    echo ""
    echo "REQUIRED PARAMETERS:"
    echo "  --namespace <namespace>   Kubernetes namespace to deploy Apicurio Registry into"
    echo ""
    echo "OPTIONAL PARAMETERS:"
    echo "  --cluster <name>          Name of the OpenShift cluster where Apicurio Registry will be installed (default: \$USER)"
    echo ""
    echo "OPTIONAL PARAMETERS:"
    echo "  --appName <name>          Name of the application deployment (default: 'registry')"
    echo "  --profile <profile>       Profile to use for Apicurio Registry (default: 'inmemory')"
    echo "                            Available profiles: $AVAILABLE_PROFILES"

    echo "  --postgresqlVersion <ver> PostgreSQL version to use (default: '16')"
    echo "                            Only used when profile is 'postgresql'"
    echo "  --mysqlVersion <ver>      MySQL version to use (default: '8.4')"
    echo "                            Only used when profile is 'mysql'"
    echo "  -h, --help                Display this help message and exit"
    echo ""
    echo "EXAMPLES:"
    echo "  # Basic installation with inmemory profile (using default cluster):"
    echo "  $0 --namespace simplens1"
    echo ""
    echo "  # Installation with custom app name and kafkasql profile:"
    echo "  $0 --appName my-registry --cluster okd419 --namespace kafkans1 --profile kafkasql"
    echo ""
    echo "  # Installation with PostgreSQL profile:"
    echo "  $0 --cluster okd419 --namespace pgns1 --profile postgresql"
    echo ""
    echo "  # Installation with PostgreSQL 12:"
    echo "  $0 --cluster okd419 --namespace pgns1 --profile postgresql --postgresqlVersion 12"
    echo ""
    echo "  # Installation with MySQL profile:"
    echo "  $0 --cluster okd419 --namespace mysqlns1 --profile mysql"
    echo ""
    echo "  # Installation with MySQL 5.7:"
    echo "  $0 --cluster okd419 --namespace mysqlns1 --profile mysql --mysqlVersion 5.7"
    echo ""
    echo "NOTES:"
    echo "  - The cluster must already exist and be properly configured"
    echo "  - Kubeconfig file must be present at clusters/<cluster_name>/auth/kubeconfig"
    echo "  - Different profiles provide different storage backends and dependencies (e.g. Keycloak)"
    echo "  - For Kafka-based profiles, install Strimzi separately using install-strimzi.sh before running this script"
}


# ##################################################
# Function to kubectl apply -f on every file in a
# particular folder.
# ##################################################
apply_all_yaml_files() {
  local yaml_dir="$1"
  local namespace="$2"

  if [[ -z "$yaml_dir" || ! -d "$yaml_dir" ]]; then
    echo "Error: '$yaml_dir' is not a valid directory"
    return 1
  fi

  if [[ -z "$namespace" ]]; then
    echo "Error: namespace parameter is required"
    return 1
  fi

  # Build a list of files sorted by filename only
  mapfile -t yaml_files < <(find "$yaml_dir" -maxdepth 1 -type f \( -name "*.yaml" -o -name "*.yml" \) \
    -exec bash -c 'for f; do echo "$(basename "$f")|$f"; done' _ {} + | \
    sort -t '|' -k1,1 | cut -d '|' -f2)

  for yaml_file in "${yaml_files[@]}"; do
    echo "Applying: $yaml_file (with namespace: $namespace)"
    kubectl apply -f <(sed "s/myproject/$namespace/g" "$yaml_file") -n $NAMESPACE
  done
}


# ##################################################
# Function to poll a Microprofile Health readiness 
# endpoint until it becomes UP.
# ##################################################
wait_for_health_endpoint() {
    local url="$1"
    local timeout="${2:-600}"  # Default timeout of 10 minutes (600 seconds)
    local interval="${3:-5}"   # Default polling interval of 5 seconds
    
    echo "Polling health endpoint: $url"
    echo "Timeout: ${timeout}s, Polling interval: ${interval}s"
    
    local start_time=$(date +%s)
    local end_time=$((start_time + timeout))
    
    # Initial wait period
    echo "Waiting 30 seconds before starting health endpoint polling..."
    sleep 30
    
    while [ $(date +%s) -lt $end_time ]; do
        # Use curl to get the JSON response from the health endpoint
        local response=$(curl -sL --max-time 10 "$url" 2>/dev/null)
        local curl_exit_code=$?

        # Check if curl succeeded and we got a response
        if [ $curl_exit_code -eq 0 ] && [ -n "$response" ]; then
            # Parse JSON to check if status is "UP" using jq
            local status=$(echo "$response" | jq -r '.status // empty' 2>/dev/null)

            if [ "$status" = "UP" ]; then
                echo "Health endpoint is ready! Status: UP"
                return 0
            else
                echo "Health endpoint responded but status is not UP (status: $status), waiting ${interval}s..."
            fi
        else
            # Get verbose curl output to determine the type of failure
            local curl_verbose=$(curl -k -s -v --max-time 10 "$url" 2>&1)

            # Detect specific connection failure types
            if echo "$curl_verbose" | grep -qi "Connection refused"; then
                echo "Health endpoint not ready - Connection refused (app not listening on port), waiting ${interval}s..."
            elif echo "$curl_verbose" | grep -qi "Connection timed out\|Operation timed out"; then
                echo "Health endpoint not ready - Connection timeout (network/routing issue), waiting ${interval}s..."
            elif echo "$curl_verbose" | grep -qi "Could not resolve host\|Name or service not known"; then
                echo "Health endpoint not ready - DNS resolution failed for $url, waiting ${interval}s..."
            elif echo "$curl_verbose" | grep -qi "SSL certificate problem\|SSL.*error\|certificate verify failed"; then
                echo "Health endpoint not ready - TLS/SSL certificate issue, waiting ${interval}s..."
            elif echo "$curl_verbose" | grep -qi "Empty reply from server"; then
                echo "Health endpoint not ready - Server closing connection immediately, waiting ${interval}s..."
            elif echo "$curl_verbose" | grep -qi "HTTP.*[45][0-9][0-9]"; then
                local http_code=$(echo "$curl_verbose" | grep -o "HTTP.*[45][0-9][0-9]" | head -n1)
                echo "Health endpoint not ready - Server returned error ($http_code), waiting ${interval}s..."
            else
                echo "Health endpoint not reachable yet (curl exit code: $curl_exit_code), waiting ${interval}s..."
            fi
        fi

        sleep $interval
    done
    
    echo "ERROR: Health endpoint did not become ready within ${timeout} seconds"
    return 1
}


# ##################################################
# Function to output debugging information when 
# application fails to become ready
# ##################################################
output_debug_info() {
    local namespace="$1"
    
    echo ""
    echo "=========================================="
    echo "DEBUGGING INFORMATION"
    echo "=========================================="
    echo ""
    
    echo "==================== DEPLOYMENTS ===================="
    kubectl get deployments -n "$namespace" -o wide || echo "Failed to get deployments"
    echo ""
    kubectl describe deployments -n "$namespace" || echo "Failed to describe deployments"
    echo ""
    
    echo "==================== PODS ===================="
    kubectl get pods -n "$namespace" -o wide || echo "Failed to get pods"
    echo ""
    kubectl describe pods -n "$namespace" || echo "Failed to describe pods"
    echo ""
    
    echo "==================== SERVICES ===================="
    kubectl get services -n "$namespace" -o wide || echo "Failed to get services"
    echo ""
    kubectl describe services -n "$namespace" || echo "Failed to describe services"
    echo ""
    
    echo "==================== ROUTES ===================="
    kubectl get routes -n "$namespace" -o wide 2>/dev/null || echo "No routes found or routes not supported"
    echo ""
    kubectl describe routes -n "$namespace" 2>/dev/null || echo "No routes found or routes not supported"
    echo ""
    
    echo "==================== INGRESSES ===================="
    kubectl get ingresses -n "$namespace" -o wide || echo "Failed to get ingresses"
    echo ""
    kubectl describe ingresses -n "$namespace" || echo "Failed to describe ingresses"
    echo ""
    
    echo "==================== EVENTS ===================="
    kubectl get events -n "$namespace" --sort-by='.lastTimestamp' || echo "Failed to get events"
    echo ""
    
    echo "==================== POD LOGS ===================="
    # Get logs from all pods in the namespace
    local pods=$(kubectl get pods -n "$namespace" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    if [ -n "$pods" ]; then
        for pod in $pods; do
            echo "--- Logs for pod: $pod ---"
            kubectl logs "$pod" -n "$namespace" --tail=50 2>/dev/null || echo "Failed to get logs for pod $pod"
            echo ""
        done
    else
        echo "No pods found in namespace $namespace"
    fi
    
    echo "=========================================="
    echo "END DEBUGGING INFORMATION"
    echo "=========================================="
    echo ""
}



# Parse command line arguments
APPLICATION_NAME=""
CLUSTER_NAME="$USER"
NAMESPACE=""
PROFILE=""

POSTGRESQL_VERSION=""
MYSQL_VERSION=""

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
        --profile)
            PROFILE="$2"
            shift 2
            ;;

        --postgresqlVersion)
            POSTGRESQL_VERSION="$2"
            shift 2
            ;;
        --mysqlVersion)
            MYSQL_VERSION="$2"
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

# Set default application name if not provided
if [ -z "$APPLICATION_NAME" ]; then
    APPLICATION_NAME="registry"
    echo "No application name specified, using default: $APPLICATION_NAME"
fi

if [ -z "$NAMESPACE" ]; then
    echo "Error: --namespace argument is required"
    show_usage
    exit 1
fi

# Validate namespace contains only letters and numbers
if [[ ! "$NAMESPACE" =~ ^[a-zA-Z0-9]+$ ]]; then
    echo "Error: Namespace '$NAMESPACE' is invalid. It must contain only letters and numbers."
    show_usage
    exit 1
fi

# Set default profile if not provided
if [ -z "$PROFILE" ]; then
    PROFILE="inmemory"
    echo "No profile specified, using default: $PROFILE"
fi

# Validate profile
if [ ! -d "$BASE_DIR/templates/profiles/$PROFILE" ]; then
    echo "Error: Invalid profile '$PROFILE'. Available profiles: $AVAILABLE_PROFILES"
    show_usage
    exit 1
fi

# Set default PostgreSQL version if not provided
if [ -z "$POSTGRESQL_VERSION" ]; then
    POSTGRESQL_VERSION="16"
    echo "No PostgreSQL version specified, using default: $POSTGRESQL_VERSION"
fi

# Set default MySQL version if not provided
if [ -z "$MYSQL_VERSION" ]; then
    MYSQL_VERSION="8.4"
    echo "No MySQL version specified, using default: $MYSQL_VERSION"
fi

load_cluster_config "$CLUSTER_NAME"

# Generate random passwords for MySQL database
# Using openssl to generate 32-character random passwords
MYSQL_USER="mysqluser"
MYSQL_DATABASE="apicuriodb"
MYSQL_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-32)
MYSQL_ROOT_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-32)

# Generate random password for PostgreSQL database
# Using openssl to generate a 32-character random password
POSTGRESQL_USER="pguser"
POSTGRESQL_DATABASE="apicuriodb"
POSTGRESQL_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-32)

export APPLICATION_NAME
export CLUSTER_NAME
export CERT_DIR="$BASE_DIR/certificates"
export APICURIO_REGISTRY_VERSION
export NAMESPACE
export PROFILE

export POSTGRESQL_VERSION
export MYSQL_VERSION
export MYSQL_USER
export MYSQL_DATABASE
export MYSQL_PASSWORD
export MYSQL_ROOT_PASSWORD
export POSTGRESQL_USER
export POSTGRESQL_DATABASE
export POSTGRESQL_PASSWORD
export BASE_DOMAIN="apicurio-testing.org"
export APPS_DIR="$CLUSTER_DIR/namespaces/$NAMESPACE/apps"
export APP_DIR="$APPS_DIR/$APPLICATION_NAME"
export APPS_URL="apps.$CLUSTER_NAME.$BASE_DOMAIN"
export APP_INGRESS_URL="registry-app-$NAMESPACE.$APPS_URL"
export UI_INGRESS_URL="registry-ui-$NAMESPACE.$APPS_URL"
export KEYCLOAK_INGRESS_URL="keycloak-$NAMESPACE.$APPS_URL"
export APICURIO_OPERATOR_URL="https://raw.githubusercontent.com/Apicurio/apicurio-registry/refs/heads/main/operator/install/apicurio-registry-operator-$APICURIO_REGISTRY_VERSION.yaml"

mkdir -p $APP_DIR

# Create the namespace if it doesn't exist
echo "Checking if namespace '$NAMESPACE' exists..."
if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    echo "Namespace '$NAMESPACE' already exists, skipping creation"
else
    echo "Creating namespace: $NAMESPACE"
    kubectl create namespace "$NAMESPACE"
fi

# Note: For Kafka-based profiles, Strimzi should be installed separately using install-strimzi.sh
echo "Assuming Strimzi Operator is already installed if using Kafka-based profiles"

# Note: Apicurio Registry Operator should be installed separately using install-apicurio-registry-operator.sh
# This script assumes the operator is already deployed cluster-wide
echo "Assuming Apicurio Registry Operator is already installed cluster-wide"

# Deploy profile-specific resources
echo "Using profile: $PROFILE"
PROFILE_DIR="$BASE_DIR/templates/profiles/$PROFILE"
YAML_FILES=$(find "$PROFILE_DIR" -name "*.yaml" -o -name "*.yml" | sort)
if [ -n "$YAML_FILES" ]; then
    echo "$YAML_FILES" | while read -r YAML_FILE; do
        YAML_FILE_NAME=$(basename "$YAML_FILE")
        FROM_TEMPLATE="$YAML_FILE"
        TO_CLUSTER=$APP_DIR/$YAML_FILE_NAME
        echo "Applying configuration from: $FROM_TEMPLATE"
        envsubst < $FROM_TEMPLATE > $TO_CLUSTER
        kubectl apply -f $TO_CLUSTER -n $NAMESPACE
    done
else
    echo "ERROR: No YAML files found in profile directory!"
    exit 1
fi

# Wait for the health endpoint to be ready
echo "Waiting for Apicurio Registry health endpoint to be ready..."
# Use HTTPS for profiles that configure TLS on routes (e.g., authn)
if [[ "$PROFILE" == "authn" ]]; then
    HEALTH_PROTOCOL="https"
else
    HEALTH_PROTOCOL="http"
fi
HEALTH_URL="$HEALTH_PROTOCOL://$APP_INGRESS_URL/health/ready"
wait_for_health_endpoint "$HEALTH_URL"
if [[ $? -ne 0 ]]; then
  echo ""
  echo "--"
  echo "ERROR: Apicurio Registry health endpoint did not become ready in time."
  echo "--"
  echo ""
  echo "Collecting debugging information..."
  output_debug_info "$NAMESPACE"
  exit 1
fi

# Apicurio Registry is up!
echo "Apicurio Registry is up!"
echo ""
echo "You can access the application here:"
echo "    User Interface: $HEALTH_PROTOCOL://$UI_INGRESS_URL"
echo "    REST API:       $HEALTH_PROTOCOL://$APP_INGRESS_URL"
echo ""
