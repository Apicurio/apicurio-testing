#!/bin/bash

# Get the directory where this script is located
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$BASE_DIR/shared.sh"

# ##################################################
# Function to display usage information
# ##################################################
show_usage() {
    echo "Usage: $0 [--cluster <cluster_name>] --namespace <namespace> [OPTIONS]"
    echo ""
    echo "REQUIRED PARAMETERS:"
    echo "  --namespace <namespace>         Kubernetes namespace to deploy ECK operator into"
    echo ""
    echo "OPTIONAL PARAMETERS:"
    echo "  --cluster <name>                Name of the OpenShift cluster where ECK will be installed (default: \$USER)"
    echo "  -h, --help                      Display this help message and exit"
    echo ""
    echo "EXAMPLES:"
    echo "  # Install ECK operator:"
    echo "  $0 --cluster okd419 --namespace searchns"
    echo ""
    echo "NOTES:"
    echo "  - The operator is installed from the 'stable' channel of the community-operators catalog"
    echo "  - The cluster must already exist and be properly configured"
    echo "  - Kubeconfig file must be present at clusters/<cluster_name>/auth/kubeconfig"
}


# Parse command line arguments
CLUSTER_NAME="$USER"
NAMESPACE=""

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
export BASE_DOMAIN="apicurio-testing.org"
export APPS_DIR="$CLUSTER_DIR/namespaces/$NAMESPACE/apps"
export APP_DIR="$APPS_DIR/elasticsearch-operator"
export OPERATOR_NAME="elasticsearch-eck-operator-certified"
export OPERATOR_CHANNEL="stable"
export CATALOG_SOURCE="certified-operators"
export CATALOG_SOURCE_NAMESPACE="openshift-marketplace"
export SUBSCRIPTION_NAME="$OPERATOR_NAME-$NAMESPACE"
export WAIT_TIMEOUT_SECONDS=600  # Max time to wait for the operator to be ready

mkdir -p $APP_DIR

ensure_namespace "$NAMESPACE"

# Install all YAML files from the Elasticsearch Operator template directory
ES_TEMPLATE_DIR="$BASE_DIR/templates/elasticsearch-operator"
echo "Installing all Elasticsearch Operator YAML files from template directory..."
for template_file in "$ES_TEMPLATE_DIR"/*.yaml; do
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

# Wait for the ECK Operator to be ready
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
  echo ""
  echo "Collecting diagnostic information..."
  echo "--- Subscription status ---"
  kubectl get subscription ${SUBSCRIPTION_NAME} -n ${NAMESPACE} -o yaml 2>/dev/null || echo "(subscription not found)"
  echo "--- CatalogSource status ---"
  kubectl get catalogsource ${CATALOG_SOURCE} -n ${CATALOG_SOURCE_NAMESPACE} -o yaml 2>/dev/null || echo "(catalogsource not found)"
  echo "--- InstallPlans in namespace ---"
  kubectl get installplan -n ${NAMESPACE} 2>/dev/null || echo "(no installplans)"
  echo "--- CSVs in namespace ---"
  kubectl get csv -n ${NAMESPACE} 2>/dev/null || echo "(no CSVs)"
  echo "--- Events in namespace ---"
  kubectl get events -n ${NAMESPACE} --sort-by='.lastTimestamp' 2>/dev/null | tail -20
  exit 1
fi

echo "Waiting for CSV '${CSV_NAME}' to reach 'Succeeded' phase..."
SECONDS_WAITED=0
while [ $SECONDS_WAITED -lt $WAIT_TIMEOUT_SECONDS ]; do
  PHASE=$(kubectl get csv "$CSV_NAME" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  if [[ "$PHASE" == "Succeeded" ]]; then
    echo "--"
    echo "ECK Operator is ready (CSV phase: Succeeded)."
    exit 0
  fi
  echo "Current CSV phase: $PHASE (waiting...)"
  sleep 5
  SECONDS_WAITED=$((SECONDS_WAITED + 5))
done

echo "ERROR: Timed out waiting for CSV '${CSV_NAME}' to reach 'Succeeded' phase."
echo ""
echo "Collecting diagnostic information..."
echo "--- CSV status ---"
kubectl get csv "$CSV_NAME" -n ${NAMESPACE} -o yaml 2>/dev/null || echo "(CSV not found)"
echo "--- Operator pods ---"
kubectl get pods -n ${NAMESPACE} 2>/dev/null || echo "(no pods)"
echo "--- Events in namespace ---"
kubectl get events -n ${NAMESPACE} --sort-by='.lastTimestamp' 2>/dev/null | tail -20
exit 1
