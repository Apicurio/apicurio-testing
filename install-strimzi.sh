#!/bin/bash

# Get the directory where this script is located
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$BASE_DIR/shared.sh"

# ##################################################
# Function to display usage information
# ##################################################
show_usage() {
    echo "Usage: $0 [--cluster <cluster_name>] --namespace <namespace> --version <version> [OPTIONS]"
    echo ""
    echo "REQUIRED PARAMETERS:"
    echo "  --namespace <namespace>   Kubernetes namespace to deploy Strimzi into"
    echo "  --version <ver>           Version of Strimzi Kafka operator to install"
    echo ""
    echo "OPTIONAL PARAMETERS:"
    echo "  --cluster <name>          Name of the OpenShift cluster where Strimzi will be installed (default: \$USER)"
    echo ""
    echo "OPTIONAL PARAMETERS:"
    echo "  -h, --help                Display this help message and exit"
    echo ""
    echo "EXAMPLES:"
    echo "  # Install Strimzi version 0.43.0:"
    echo "  $0 --cluster okd419 --namespace kafkans1 --version 0.43.0"
    echo ""
    echo ""
    echo "NOTES:"
    echo "  - The cluster must already exist and be properly configured"
    echo "  - Kubeconfig file must be present at clusters/<cluster_name>/auth/kubeconfig"
    echo "  - This script should be run before installing Apicurio Registry with Kafka-based profiles"
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
# Function to wait for the Strimzi operator pod to
# become ready.
# ##################################################
wait_for_strimzi_ready() {
    local namespace="$1"
    local timeout=300  # 5 minutes
    local interval=10  # 10 seconds
    local elapsed=0
    
    echo "Waiting for Strimzi operator pod to become ready..."
    echo "Looking for pod with label 'name=strimzi-cluster-operator' in namespace $namespace..."
    echo "Timeout: ${timeout}s, Polling interval: ${interval}s"
    
    while [ $elapsed -lt $timeout ]; do
        # Check if pods with the label exist
        local pod_names=$(kubectl get pods -l name=strimzi-cluster-operator -n "$namespace" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
        
        if [ -z "$pod_names" ]; then
            echo "No Strimzi operator pods found yet, waiting for creation... (${elapsed}s/${timeout}s)"
        else
            echo "Found Strimzi operator pods: $pod_names"
            local all_pods_ready=true
            local pod_status_info=""
            
            # Check each pod's readiness
            for pod_name in $pod_names; do
                local ready_status=$(kubectl get pod "$pod_name" -n "$namespace" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
                local phase=$(kubectl get pod "$pod_name" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
                
                if [ "$ready_status" = "True" ]; then
                    pod_status_info="${pod_status_info}  ✓ Pod $pod_name: Ready (Phase: $phase)\n"
                else
                    pod_status_info="${pod_status_info}  ✗ Pod $pod_name: Ready=$ready_status, Phase=$phase\n"
                    all_pods_ready=false
                fi
            done
            
            if [ "$all_pods_ready" = "true" ]; then
                echo "All Strimzi operator pods are ready!"
                echo -e "$pod_status_info"
                return 0
            else
                echo "Some Strimzi operator pods are not ready yet (${elapsed}s/${timeout}s):"
                echo -e "$pod_status_info"
            fi
        fi
        
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    
    echo "ERROR: Strimzi operator pod did not become ready within ${timeout} seconds"
    
    # Output debug information for troubleshooting
    echo "Final pod status check:"
    kubectl get pods -l name=strimzi-cluster-operator -n "$namespace" -o wide 2>/dev/null || echo "Failed to get pod information"
    echo ""
    echo "This could indicate installation issues. Please check the pod status:"
    echo "  kubectl get pods -l name=strimzi-cluster-operator -n $namespace"
    echo "  kubectl logs -l name=strimzi-cluster-operator -n $namespace"
    
    return 1
}


# Parse command line arguments
CLUSTER_NAME="$USER"
NAMESPACE=""
STRIMZI_VERSION=""

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
        --version)
            STRIMZI_VERSION="$2"
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

# Validate cluster name (should not be empty after defaulting to $USER)
if [ -z "$CLUSTER_NAME" ]; then
    echo "Error: cluster name is empty (default: \$USER)"
    show_usage
    exit 1
fi

if [ -z "$NAMESPACE" ]; then
    echo "Error: --namespace argument is required"
    show_usage
    exit 1
fi

if [ -z "$STRIMZI_VERSION" ]; then
    echo "Error: --version argument is required"
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

export CLUSTER_NAME
export NAMESPACE
export STRIMZI_VERSION
export APPS_DIR="$CLUSTER_DIR/namespaces/$NAMESPACE/apps"
export APP_DIR="$APPS_DIR/strimzi"

mkdir -p $APP_DIR

ensure_namespace "$NAMESPACE"

# Deploy Strimzi operator
echo "Installing Strimzi Operator version: $STRIMZI_VERSION"
STRIMZI_OPERATOR_URL="https://github.com/strimzi/strimzi-kafka-operator/releases/download/$STRIMZI_VERSION/strimzi-$STRIMZI_VERSION.zip"
echo "Downloading Strimzi Operator ZIP from: $STRIMZI_OPERATOR_URL"
curl -sSL -o $APP_DIR/strimzi-$STRIMZI_VERSION.zip $STRIMZI_OPERATOR_URL
echo "Unpacking Strimzi operator ZIP"
unzip $APP_DIR/strimzi-$STRIMZI_VERSION.zip -d $APP_DIR
echo "Installing Strimzi Operator into namespace $NAMESPACE"
apply_all_yaml_files $APP_DIR/strimzi-$STRIMZI_VERSION/install/strimzi-admin $NAMESPACE
apply_all_yaml_files $APP_DIR/strimzi-$STRIMZI_VERSION/install/cluster-operator $NAMESPACE
#apply_all_yaml_files $APP_DIR/strimzi-$STRIMZI_VERSION/install/topic-operator $NAMESPACE
#apply_all_yaml_files $APP_DIR/strimzi-$STRIMZI_VERSION/install/user-operator $NAMESPACE

# Wait for the Strimzi operator pod to become ready
if ! wait_for_strimzi_ready $NAMESPACE; then
    echo "ERROR: Strimzi operator failed to become ready"
    exit 1
fi

# Wait for Strimzi CRDs to be established
echo "Waiting for Strimzi CRDs to be established..."
CRDS_TO_WAIT_FOR="kafkas.kafka.strimzi.io kafkanodepools.kafka.strimzi.io"
for crd in $CRDS_TO_WAIT_FOR; do
    echo "Waiting for CRD: $crd"
    timeout=60
    elapsed=0
    interval=2

    while [ $elapsed -lt $timeout ]; do
        if kubectl get crd $crd >/dev/null 2>&1; then
            # CRD exists, check if it's established
            established=$(kubectl get crd $crd -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' 2>/dev/null)
            if [ "$established" = "True" ]; then
                echo "✓ CRD $crd is established"
                break
            else
                echo "CRD $crd exists but not established yet... (${elapsed}s/${timeout}s)"
            fi
        else
            echo "CRD $crd not found yet... (${elapsed}s/${timeout}s)"
        fi

        sleep $interval
        elapsed=$((elapsed + interval))
    done

    if [ $elapsed -ge $timeout ]; then
        echo "ERROR: CRD $crd did not become established within ${timeout} seconds"
        exit 1
    fi
done

echo "All required Strimzi CRDs are established!"
echo "Strimzi Operator installation completed successfully!"
echo "You can now install Kafka clusters in namespace $NAMESPACE."