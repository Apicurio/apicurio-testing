#!/bin/bash

# Get the directory where this script is located
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$BASE_DIR/shared.sh"

# ##################################################
# Function to display usage information
# ##################################################
show_usage() {
    echo "Usage: $0 [--cluster <cluster_name>] --namespace <namespace> --elasticsearchVersion <version> [OPTIONS]"
    echo ""
    echo "REQUIRED PARAMETERS:"
    echo "  --namespace <namespace>                Kubernetes namespace to deploy Elasticsearch into"
    echo "  --elasticsearchVersion <version>       Elasticsearch version to deploy (e.g., 8.17.0)"
    echo ""
    echo "OPTIONAL PARAMETERS:"
    echo "  --cluster <name>                       Name of the OpenShift cluster (default: \$USER)"
    echo "  -h, --help                             Display this help message and exit"
    echo ""
    echo "EXAMPLES:"
    echo "  # Deploy Elasticsearch 8.17.0:"
    echo "  $0 --cluster okd419 --namespace searchns --elasticsearchVersion 8.17.0"
    echo ""
    echo "NOTES:"
    echo "  - The ECK operator must already be installed (use install-elasticsearch-operator.sh)"
    echo "  - The cluster must already exist and be properly configured"
    echo "  - Kubeconfig file must be present at clusters/<cluster_name>/auth/kubeconfig"
    echo "  - ECK automatically creates a Secret 'elasticsearch-es-elastic-user' with the elastic user password"
    echo "  - ECK automatically creates a Service 'elasticsearch-es-http' on port 9200"
}


# ##################################################
# Function to output debugging information when
# Elasticsearch fails to become ready
# ##################################################
output_debug_info() {
    local namespace="$1"

    echo ""
    echo "=========================================="
    echo "DEBUGGING INFORMATION"
    echo "=========================================="
    echo ""

    echo "==================== ELASTICSEARCH CR ===================="
    kubectl get elasticsearch -n "$namespace" -o wide || echo "Failed to get Elasticsearch CR"
    echo ""
    kubectl describe elasticsearch -n "$namespace" || echo "Failed to describe Elasticsearch CR"
    echo ""

    echo "==================== PODS ===================="
    kubectl get pods -n "$namespace" -o wide || echo "Failed to get pods"
    echo ""
    kubectl describe pods -n "$namespace" || echo "Failed to describe pods"
    echo ""

    echo "==================== SERVICES ===================="
    kubectl get services -n "$namespace" -o wide || echo "Failed to get services"
    echo ""

    echo "==================== EVENTS ===================="
    kubectl get events -n "$namespace" --sort-by='.lastTimestamp' || echo "Failed to get events"
    echo ""

    echo "==================== POD LOGS ===================="
    local pods=$(kubectl get pods -n "$namespace" -l common.k8s.elastic.co/type=elasticsearch -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    if [ -n "$pods" ]; then
        for pod in $pods; do
            echo "--- Logs for pod: $pod ---"
            kubectl logs "$pod" -n "$namespace" --tail=50 2>/dev/null || echo "Failed to get logs for pod $pod"
            echo ""
        done
    else
        echo "No Elasticsearch pods found in namespace $namespace"
    fi

    echo "=========================================="
    echo "END DEBUGGING INFORMATION"
    echo "=========================================="
    echo ""
}


# ##################################################
# Function to wait for Elasticsearch to be ready
# ##################################################
wait_for_elasticsearch_ready() {
    local namespace="$1"
    local timeout=600  # 10 minutes
    local interval=10  # 10 seconds
    local elapsed=0

    echo "Waiting for Elasticsearch cluster to be ready..."
    echo "Timeout: ${timeout}s, Polling interval: ${interval}s"

    while [ $elapsed -lt $timeout ]; do
        # Get the health status of the Elasticsearch CR
        local health=$(kubectl get elasticsearch elasticsearch -n "$namespace" -o jsonpath='{.status.health}' 2>/dev/null || echo "")
        local phase=$(kubectl get elasticsearch elasticsearch -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")

        if [[ "$health" == "green" || "$health" == "yellow" ]]; then
            echo "Elasticsearch cluster is ready! Health: $health, Phase: $phase"
            return 0
        else
            echo "Elasticsearch not ready yet. Health: ${health:-unknown}, Phase: ${phase:-unknown} (${elapsed}s/${timeout}s)"
        fi

        sleep $interval
        elapsed=$((elapsed + interval))
    done

    echo "ERROR: Elasticsearch cluster did not become ready within ${timeout} seconds"
    return 1
}


# Parse command line arguments
CLUSTER_NAME="$USER"
NAMESPACE=""
ELASTICSEARCH_VERSION=""

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
        --elasticsearchVersion)
            ELASTICSEARCH_VERSION="$2"
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

if [ -z "$ELASTICSEARCH_VERSION" ]; then
    echo "Error: --elasticsearchVersion argument is required"
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
export ELASTICSEARCH_VERSION
export BASE_DOMAIN="apicurio-testing.org"
export APPS_DIR="$CLUSTER_DIR/namespaces/$NAMESPACE/apps"
export APP_DIR="$APPS_DIR/elasticsearch"

mkdir -p $APP_DIR

ensure_namespace "$NAMESPACE"

# Set the Elasticsearch template directory
ES_TEMPLATE_DIR="$BASE_DIR/templates/elasticsearch"
if [ ! -d "$ES_TEMPLATE_DIR" ]; then
    echo "Error: Elasticsearch templates not found at '$ES_TEMPLATE_DIR'"
    exit 1
fi

# Install all YAML files from the Elasticsearch template directory
echo "Installing all Elasticsearch YAML files from template directory..."
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

# Wait for Elasticsearch to be ready
if ! wait_for_elasticsearch_ready $NAMESPACE; then
    echo "ERROR: Elasticsearch failed to become ready"
    echo "Running debug information collection..."
    output_debug_info $NAMESPACE
    exit 1
fi

# Retrieve the elastic user password from the auto-generated secret
ES_PASSWORD=$(kubectl get secret elasticsearch-es-elastic-user -n $NAMESPACE -o go-template='{{.data.elastic | base64decode}}' 2>/dev/null || echo "Not available")

# Elasticsearch is up!
echo ""
echo "=========================================="
echo "Elasticsearch is up and running!"
echo "=========================================="
echo ""
echo "Cluster Details:"
echo "    Version:          $ELASTICSEARCH_VERSION"
echo "    Service:          elasticsearch-es-http.$NAMESPACE.svc:9200"
echo "    Username:         elastic"
echo "    Password:         $ES_PASSWORD"
echo ""
