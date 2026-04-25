#!/bin/bash

# Get the directory where this script is located
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$BASE_DIR/shared.sh"

# ##################################################
# Function to display usage information
# ##################################################
show_usage() {
    echo "Usage: $0 [--cluster <cluster_name>] --namespace <namespace> [--keycloakVersion <version>] [OPTIONS]"
    echo ""
    echo "REQUIRED PARAMETERS:"
    echo "  --namespace <namespace>         Kubernetes namespace to deploy Keycloak operator into"
    echo ""
    echo "OPTIONAL PARAMETERS:"
    echo "  --cluster <name>                Name of the OpenShift cluster where Keycloak will be installed (default: \$USER)"
    echo "  --keycloakVersion <version>     (Deprecated) Operator version - now uses latest from fast channel"
    echo "  -h, --help                      Display this help message and exit"
    echo ""
    echo "EXAMPLES:"
    echo "  # Install latest Keycloak operator from fast channel:"
    echo "  $0 --cluster okd419 --namespace keycloak-ns"
    echo ""
    echo "NOTES:"
    echo "  - The operator is installed from the 'fast' channel which contains the latest stable version"
    echo "  - The cluster must already exist and be properly configured"
    echo "  - Kubeconfig file must be present at clusters/<cluster_name>/auth/kubeconfig"
}


# Parse command line arguments
CLUSTER_NAME="$USER"
NAMESPACE=""
KEYCLOAK_OPERATOR_VERSION=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --cluster)
            CLUSTER_NAME="$2"
            shift 2
            ;;
        --namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        --keycloakVersion)
            KEYCLOAK_OPERATOR_VERSION="$2"
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

if [ -z "$NAMESPACE" ]; then
    echo "Error: --namespace argument is required"
    show_usage
    exit 1
fi

# keycloakVersion is now optional (deprecated) - we use latest from fast channel
if [ -n "$KEYCLOAK_OPERATOR_VERSION" ]; then
    echo "Warning: --keycloakVersion is deprecated and will be ignored. Using latest from fast channel."
fi

# Validate namespace contains only letters and numbers
if [[ ! "$NAMESPACE" =~ ^[a-zA-Z0-9]+$ ]]; then
    echo "Error: Namespace '$NAMESPACE' is invalid. It must contain only letters and numbers."
    show_usage
    exit 1
fi

load_cluster_config "$CLUSTER_NAME"

# Export environment variables
export CLUSTER_NAME
export CLUSTER_DIR="$BASE_DIR/clusters/$CLUSTER_NAME"
export NAMESPACE
export KEYCLOAK_OPERATOR_VERSION
export BASE_DOMAIN="apicurio-testing.org"
export APPS_DIR="$CLUSTER_DIR/namespaces/$NAMESPACE/apps"
export APP_DIR="$APPS_DIR/keycloak-operator"
export OPERATOR_NAME="keycloak-operator"
export OPERATOR_CHANNEL="fast"
export CATALOG_SOURCE="community-operators"
export CATALOG_SOURCE_NAMESPACE="openshift-marketplace"
export SUBSCRIPTION_NAME="$OPERATOR_NAME-$NAMESPACE"
export WAIT_TIMEOUT_SECONDS=300  # Max time to wait for the operator to be ready

mkdir -p $APP_DIR

ensure_namespace "$NAMESPACE"

# Install all YAML files from the Keycloak Operator template directory
KEYCLOAK_TEMPLATE_DIR="$BASE_DIR/templates/keycloak-operator"
echo "Installing all Keycloak YAML files from template directory..."
for template_file in "$KEYCLOAK_TEMPLATE_DIR"/*.yaml; do
    if [ -f "$template_file" ]; then
        # Get the filename without the path
        filename=$(basename "$template_file")
        echo "Processing template: $filename"
        
        # Create the processed file in the app directory
        processed_file="$APP_DIR/$filename"
        envsubst < "$template_file" > "$processed_file"
        kubectl apply -f "$processed_file" -n $NAMESPACE
    fi
done

# Wait for the Keycloak Operator to be ready
echo "Waiting for ClusterServiceVersion to be created..."
SECONDS_WAITED=0
CSV_NAME=""
while [ $SECONDS_WAITED -lt $WAIT_TIMEOUT_SECONDS ]; do
  CSV_NAME=$(kubectl get subscription ${SUBSCRIPTION_NAME} -n ${NAMESPACE} -o jsonpath='{.status.installedCSV}' 2>/dev/null || echo "")
  if [[ -n "$CSV_NAME" ]]; then
    echo "Found ClusterServiceVersion: $CSV_NAME"
    break
  fi
  sleep 5
  SECONDS_WAITED=$((SECONDS_WAITED + 5))
done

if [[ -z "$CSV_NAME" ]]; then
  echo "ERROR: Timed out waiting for ClusterServiceVersion to be created."
  exit 1
fi

echo "Waiting for CSV '${CSV_NAME}' to reach 'Succeeded' phase..."
SECONDS_WAITED=0
while [ $SECONDS_WAITED -lt $WAIT_TIMEOUT_SECONDS ]; do
  PHASE=$(kubectl get csv "$CSV_NAME" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  if [[ "$PHASE" == "Succeeded" ]]; then
    echo "--"
    echo "Keycloak Operator is ready (CSV phase: Succeeded)."
    exit 0
  fi
  echo "Current CSV phase: $PHASE (waiting...)"
  sleep 5
  SECONDS_WAITED=$((SECONDS_WAITED + 5))
done

echo "ERROR: Timed out waiting for CSV '${CSV_NAME}' to reach 'Succeeded' phase."
exit 1
