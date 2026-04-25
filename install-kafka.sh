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
    echo "  --namespace <namespace>  Kubernetes namespace to deploy Kafka into"
    echo ""
    echo "OPTIONAL PARAMETERS:"
    echo "  --cluster <name>         Name of the OpenShift cluster where Kafka will be installed (default: \$USER)"
    echo ""
    echo ""
    echo "OPTIONAL PARAMETERS:"
    echo "  -h, --help               Display this help message and exit"
    echo ""
    echo "EXAMPLES:"
    echo "  # Basic installation:"
    echo "  $0 --cluster okd419 --namespace kafka-ns"
    echo ""
    echo "NOTES:"
    echo "  - The cluster must already exist and be properly configured"
    echo "  - Kubeconfig file must be present at clusters/<cluster_name>/auth/kubeconfig"
    echo "  - The script will deploy Strimzi Kafka resources (KafkaNodePool and Kafka)"
    echo "  - Kafka will be accessible within the cluster"
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
    
    echo "==================== KAFKA RESOURCES ===================="
    kubectl get kafka -n "$namespace" -o wide || echo "Failed to get Kafka resources"
    echo ""
    kubectl describe kafka -n "$namespace" || echo "Failed to describe Kafka resources"
    echo ""
    
    echo "==================== KAFKA NODE POOLS ===================="
    kubectl get kafkanodepool -n "$namespace" -o wide || echo "Failed to get KafkaNodePool resources"
    echo ""
    kubectl describe kafkanodepool -n "$namespace" || echo "Failed to describe KafkaNodePool resources"
    echo ""
    
    echo "==================== DEPLOYMENTS ===================="
    kubectl get deployments -n "$namespace" -o wide || echo "Failed to get deployments"
    echo ""
    kubectl describe deployments -n "$namespace" || echo "Failed to describe deployments"
    echo ""
    
    echo "==================== STATEFULSETS ===================="
    kubectl get statefulsets -n "$namespace" -o wide || echo "Failed to get statefulsets"
    echo ""
    kubectl describe statefulsets -n "$namespace" || echo "Failed to describe statefulsets"
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

wait_for_kafka_ready() {
    local namespace="$1"
    local timeout=600  # 10 minutes
    local interval=10  # 10 seconds
    local elapsed=0
    
    echo "Waiting for Kafka cluster to be ready..."
    echo "Timeout: ${timeout}s, Polling interval: ${interval}s"
    
    while [ $elapsed -lt $timeout ]; do
        # Check if Kafka CR exists
        local kafka_names=$(kubectl get kafka -n "$namespace" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
        
        if [ -z "$kafka_names" ]; then
            echo "No Kafka resources found yet, waiting for creation... (${elapsed}s/${timeout}s)"
        else
            echo "Found Kafka resources: $kafka_names"
            local all_kafka_ready=true
            local kafka_status_info=""
            
            # Check each Kafka cluster's readiness
            for kafka_name in $kafka_names; do
                local ready_status=$(kubectl get kafka "$kafka_name" -n "$namespace" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
                local ready_reason=$(kubectl get kafka "$kafka_name" -n "$namespace" -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || echo "Unknown")
                
                if [ "$ready_status" = "True" ]; then
                    kafka_status_info="${kafka_status_info}  ✓ Kafka $kafka_name: Ready\n"
                else
                    kafka_status_info="${kafka_status_info}  ✗ Kafka $kafka_name: Status=$ready_status, Reason=$ready_reason\n"
                    all_kafka_ready=false
                fi
            done
            
            if [ "$all_kafka_ready" = "true" ]; then
                echo "All Kafka clusters are ready!"
                echo -e "$kafka_status_info"
                return 0
            else
                echo "Some Kafka clusters are not ready yet (${elapsed}s/${timeout}s):"
                echo -e "$kafka_status_info"
            fi
        fi
        
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    
    echo "ERROR: Kafka cluster did not become ready within ${timeout} seconds"
    
    # Output debug information for troubleshooting
    echo "Final Kafka status check:"
    kubectl get kafka -n "$namespace" -o wide 2>/dev/null || echo "Failed to get Kafka information"
    
    return 1
}

# Parse command line arguments
APPLICATION_NAME="kafka"
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
export APPLICATION_NAME
export CLUSTER_NAME
export CERT_DIR="$BASE_DIR/certificates"
export NAMESPACE

export BASE_DOMAIN="apicurio-testing.org"
export APPS_DIR="$CLUSTER_DIR/namespaces/$NAMESPACE/apps"
export APP_DIR="$APPS_DIR/$APPLICATION_NAME"
export APPS_URL="apps.$CLUSTER_NAME.$BASE_DOMAIN"

mkdir -p $APP_DIR

ensure_namespace "$NAMESPACE"

# Search for the kafka-single-node.yaml file in the Strimzi installation
echo "Searching for kafka-single-node.yaml in Strimzi installation..."
STRIMZI_APPS_DIR="$CLUSTER_DIR/namespaces/$NAMESPACE/apps/strimzi"

if [ ! -d "$STRIMZI_APPS_DIR" ]; then
    echo "Error: Strimzi installation directory not found at '$STRIMZI_APPS_DIR'"
    echo "Make sure install-strimzi.sh has been run first"
    exit 1
fi

# Find the kafka-single-node.yaml file
KAFKA_SINGLE_NODE_FILE=$(find "$STRIMZI_APPS_DIR" -name "kafka-single-node.yaml" -type f | head -1)

if [ -z "$KAFKA_SINGLE_NODE_FILE" ]; then
    echo "Error: kafka-single-node.yaml file not found in Strimzi installation"
    echo "Searched in: $STRIMZI_APPS_DIR"
    echo "Make sure install-strimzi.sh has been run first and the Strimzi version includes this file"
    exit 1
fi

echo "Found kafka-single-node.yaml at: $KAFKA_SINGLE_NODE_FILE"

# Process and apply the kafka-single-node.yaml file
echo "Installing Kafka using kafka-single-node.yaml..."
filename=$(basename "$KAFKA_SINGLE_NODE_FILE")
processed_file="$APP_DIR/$filename"
envsubst < "$KAFKA_SINGLE_NODE_FILE" > "$processed_file"
kubectl apply -f "$processed_file" -n $NAMESPACE

# Wait for the Kafka cluster to be ready
if ! wait_for_kafka_ready $NAMESPACE; then
    echo "ERROR: Kafka cluster failed to become ready"
    echo "Running debug information collection..."
    output_debug_info $NAMESPACE
    exit 1
fi


# Kafka is up!
echo "Kafka is up and running!"
echo ""
echo "Kafka cluster deployed successfully in namespace: $NAMESPACE"
echo ""
echo "You can check the Kafka cluster status with:"
echo "    kubectl get kafka -n $NAMESPACE"
echo "    kubectl get kafkanodepool -n $NAMESPACE"
echo "    kubectl get pods -n $NAMESPACE"
echo ""