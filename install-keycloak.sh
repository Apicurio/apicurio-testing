#!/bin/bash

# Get the directory where this script is located
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$BASE_DIR/shared.sh"

# ##################################################
# Function to display usage information
# ##################################################
show_usage() {
    echo "Usage: $0 [--cluster <cluster_name>] --namespace <namespace> --keycloakVersion <version> [OPTIONS]"
    echo ""
    echo "REQUIRED PARAMETERS:"
    echo "  --namespace <namespace>        Kubernetes namespace to deploy Keycloak into"
    echo "  --keycloakVersion <version>    Keycloak version to deploy (e.g., 22.0, 26.3.1)"
    echo ""
    echo "OPTIONAL PARAMETERS:"
    echo "  --cluster <name>               Name of the OpenShift cluster where Keycloak will be installed (default: \$USER)"
    echo "  --realmName <realm>            Name of the realm to create (default: 'registry')"
    echo "  -h, --help                     Display this help message and exit"
    echo ""
    echo "EXAMPLES:"
    echo "  # Basic installation:"
    echo "  $0 --cluster okd419 --namespace keycloak-ns --keycloakVersion 26.3.1"
    echo ""
    echo "NOTES:"
    echo "  - The cluster must already exist and be properly configured"
    echo "  - Kubeconfig file must be present at clusters/<cluster_name>/auth/kubeconfig"
    echo "  - The script will create a ConfigMap with a pre-configured realm"
    echo "  - Keycloak will be accessible via OpenShift Route with TLS termination"
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
    
    echo "==================== CONFIGMAPS ===================="
    kubectl get configmaps -n "$namespace" -o wide || echo "Failed to get configmaps"
    echo ""
    kubectl describe configmaps -n "$namespace" || echo "Failed to describe configmaps"
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

wait_for_keycloak_pods_ready() {
    local namespace="$1"
    local timeout=300  # 5 minutes
    local interval=5   # 5 seconds
    local elapsed=0
    
    echo "Waiting for Keycloak pods to be ready..."
    echo "Timeout: ${timeout}s, Polling interval: ${interval}s"
    
    while [ $elapsed -lt $timeout ]; do
        # Find Keycloak pods using common label selectors
        local pods=$(kubectl get pods -n "$namespace" -l app=keycloak -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
        
        # If no pods found with app=keycloak, try other common selectors
        if [ -z "$pods" ]; then
            pods=$(kubectl get pods -n "$namespace" -l app.kubernetes.io/name=keycloak -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
        fi
        
        # If still no pods, try to find any pods that might be Keycloak-related
        if [ -z "$pods" ]; then
            pods=$(kubectl get pods -n "$namespace" -o jsonpath='{.items[?(@.metadata.name=~"keycloak.*")].metadata.name}' 2>/dev/null)
        fi
        
        if [ -z "$pods" ]; then
            echo "No Keycloak pods found yet, waiting for pod creation... (${elapsed}s/${timeout}s)"
        else
            echo "Found Keycloak pods: $pods"
            local all_pods_ready=true
            local pod_status_info=""
            
            # Check each pod's readiness
            for pod in $pods; do
                # Check pod phase
                local pod_phase=$(kubectl get pod "$pod" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
                
                # Check if all containers are ready
                local container_ready_statuses=$(kubectl get pod "$pod" -n "$namespace" -o jsonpath='{.status.containerStatuses[*].ready}' 2>/dev/null || echo "")
                local all_containers_ready=true
                
                if [ -n "$container_ready_statuses" ]; then
                    for ready_status in $container_ready_statuses; do
                        if [ "$ready_status" != "true" ]; then
                            all_containers_ready=false
                            break
                        fi
                    done
                else
                    all_containers_ready=false
                fi
                
                # Check pod Ready condition
                local pod_ready_condition=$(kubectl get pod "$pod" -n "$namespace" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
                
                # Determine if this pod is ready
                if [ "$pod_phase" = "Running" ] && [ "$all_containers_ready" = "true" ] && [ "$pod_ready_condition" = "True" ]; then
                    pod_status_info="${pod_status_info}  ✓ Pod $pod: Ready\n"
                else
                    pod_status_info="${pod_status_info}  ✗ Pod $pod: Phase=$pod_phase, ContainersReady=$all_containers_ready, PodReady=$pod_ready_condition\n"
                    all_pods_ready=false
                fi
            done
            
            if [ "$all_pods_ready" = "true" ]; then
                echo "All Keycloak pods are ready!"
                echo -e "$pod_status_info"
                return 0
            else
                echo "Some Keycloak pods are not ready yet (${elapsed}s/${timeout}s):"
                echo -e "$pod_status_info"
            fi
        fi
        
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    
    echo "ERROR: Keycloak pods did not become ready within ${timeout} seconds"
    
    # Output debug information for troubleshooting
    echo "Final pod status check:"
    kubectl get pods -n "$namespace" -o wide 2>/dev/null || echo "Failed to get pod information"
    
    return 1
}

wait_for_realm_import_completion() {
    local namespace="$1"
    local timeout=300  # 5 minutes
    local interval=5   # 5 seconds
    local elapsed=0
    
    echo "Waiting for KeycloakRealmImport pod to complete..."
    echo "Timeout: ${timeout}s, Polling interval: ${interval}s"
    
    while [ $elapsed -lt $timeout ]; do
        # Find realm import pods using the specified label
        local pods=$(kubectl get pods -n "$namespace" -l app=keycloak-realm-import -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
        
        if [ -z "$pods" ]; then
            echo "No realm import pods found yet, waiting for pod creation... (${elapsed}s/${timeout}s)"
        else
            echo "Found realm import pods: $pods"
            local all_pods_completed=true
            local pod_status_info=""
            
            # Check each pod's completion status
            for pod in $pods; do
                local pod_phase=$(kubectl get pod "$pod" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
                
                if [ "$pod_phase" = "Succeeded" ]; then
                    pod_status_info="${pod_status_info}  ✓ Pod $pod: Completed successfully\n"
                elif [ "$pod_phase" = "Failed" ]; then
                    pod_status_info="${pod_status_info}  ✗ Pod $pod: Failed\n"
                    echo "ERROR: Realm import pod $pod failed"
                    echo -e "$pod_status_info"
                    
                    # Show pod logs for debugging
                    echo "Pod logs for debugging:"
                    kubectl logs "$pod" -n "$namespace" --tail=20 2>/dev/null || echo "Failed to get logs for pod $pod"
                    return 1
                else
                    pod_status_info="${pod_status_info}  ⏳ Pod $pod: Phase=$pod_phase\n"
                    all_pods_completed=false
                fi
            done
            
            if [ "$all_pods_completed" = "true" ]; then
                echo "All realm import pods completed successfully!"
                echo -e "$pod_status_info"
                return 0
            else
                echo "Some realm import pods are not completed yet (${elapsed}s/${timeout}s):"
                echo -e "$pod_status_info"
            fi
        fi
        
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    
    echo "ERROR: Realm import did not complete within ${timeout} seconds"
    
    # Output debug information for troubleshooting
    echo "Final realm import pod status check:"
    kubectl get pods -n "$namespace" -l app=keycloak-realm-import -o wide 2>/dev/null || echo "Failed to get realm import pod information"
    
    return 1
}

wait_for_keycloak_cr_ready() {
    local namespace="$1"
    local elapsed=0
    local interval=10
    local timeout="${3:-600}"  # 10 minutes default
    
    while [ $elapsed -lt $timeout ]; do
        # Check if Keycloak CR exists
        if ! kubectl get keycloak keycloak-instance -n "$namespace" &>/dev/null; then
            echo "Keycloak instance not found in namespace '$namespace'"
            return 1
        fi
        
        # Get the status conditions
        local ready_status=$(kubectl get keycloak keycloak-instance -n "$namespace" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
        local ready_reason=$(kubectl get keycloak keycloak-instance -n "$namespace" -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || echo "Unknown")
        
        if [ "$ready_status" = "True" ]; then
            echo "Keycloak instance is ready!"
            
            # Display connection info
            local keycloak_url=$(kubectl get keycloak keycloak-instance -n "$namespace" -o jsonpath='{.status.hostname}' 2>/dev/null || echo "Not available")
            echo "Keycloak URL: https://$keycloak_url"
            
            return 0
        elif [ "$ready_status" = "False" ]; then
            echo "Keycloak not ready yet. Reason: $ready_reason (${elapsed}s/${timeout}s)"
        else
            echo "Keycloak status unknown, still initializing... (${elapsed}s/${timeout}s)"
        fi
        
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    
    echo "Timeout waiting for Keycloak to be ready"
    return 1
}

# Parse command line arguments
APPLICATION_NAME="keycloak"
CLUSTER_NAME="$USER"
NAMESPACE=""
KEYCLOAK_VERSION=""
REALM_NAME=""

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
            KEYCLOAK_VERSION="$2"
            shift 2
            ;;
        --realmName)
            REALM_NAME="$2"
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

if [ -z "$REALM_NAME" ]; then
    REALM_NAME="registry"
    echo "No realm name specified, using default: $REALM_NAME"
fi

if [ -z "$NAMESPACE" ]; then
    echo "Error: --namespace argument is required"
    show_usage
    exit 1
fi

if [ -z "$KEYCLOAK_VERSION" ]; then
    echo "Error: --keycloakVersion argument is required"
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

# Generate a random password for the Keycloak database
# Using openssl to generate a 32-character random password
KEYCLOAK_DB_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-32)

# Export environment variables
export APPLICATION_NAME
export CLUSTER_NAME
export CERT_DIR="$BASE_DIR/certificates"
export NAMESPACE
export KEYCLOAK_VERSION
export REALM_NAME
export BASE_DOMAIN="apicurio-testing.org"
export APPS_DIR="$CLUSTER_DIR/namespaces/$NAMESPACE/apps"
export APP_DIR="$APPS_DIR/$APPLICATION_NAME"
export APPS_URL="apps.$CLUSTER_NAME.$BASE_DOMAIN"
export KEYCLOAK_INGRESS_URL="keycloak-$NAMESPACE.$APPS_URL"
export KEYCLOAK_HEALTH_URL="keycloak-health-$NAMESPACE.$APPS_URL"
export KEYCLOAK_DB_PASSWORD
export POSTGRES_USER="keycloak"
export POSTGRES_DB="keycloak"

mkdir -p $APP_DIR

ensure_namespace "$NAMESPACE"

# Set the Keycloak template directory
KEYCLOAK_TEMPLATE_DIR="$BASE_DIR/templates/keycloak"
if [ ! -d "$KEYCLOAK_TEMPLATE_DIR" ]; then
    echo "Error: Keycloak templates not found at '$KEYCLOAK_TEMPLATE_DIR'"
    exit 1
fi

# Install all YAML files from the Keycloak template directory
echo "Installing all Keycloak YAML files from template directory..."
for template_file in "$KEYCLOAK_TEMPLATE_DIR"/*.yaml; do
    if [ -f "$template_file" ]; then
        # Get the filename without the path
        filename=$(basename "$template_file")

        # Skip version-specific templates (they're handled separately)
        if [[ "$filename" == *.v* ]]; then
            continue
        fi

        echo "Processing template: $filename"

        # For Keycloak CR, use version-specific template if Keycloak 22.x
        if [[ "$filename" == "50-Keycloak.Keycloak.yaml" && "$KEYCLOAK_VERSION" =~ ^22\. ]]; then
            echo "Using Keycloak 22-specific template for compatibility with operator v26+"
            template_file="$KEYCLOAK_TEMPLATE_DIR/50-Keycloak.Keycloak.yaml.v22"
        fi

        # Create the processed file in the app directory
        processed_file="$APP_DIR/$filename"
        envsubst < "$template_file" > "$processed_file"
        kubectl apply -f "$processed_file" -n $NAMESPACE
    fi
done

# Wait for the Keycloak CR to be ready
wait_for_keycloak_cr_ready $NAMESPACE

# Wait for the KeycloakRealmImport pod to complete
if ! wait_for_realm_import_completion $NAMESPACE; then
    echo "ERROR: KeycloakRealmImport failed to complete"
    echo "Running debug information collection..."
    output_debug_info $NAMESPACE
    exit 1
fi

# Wait 10 seconds for Keycloak pods to restart after realm import
echo "Realm import completed. Waiting 10 seconds for Keycloak pods to restart..."
sleep 10

# Now wait for the actual Keycloak pods to be ready
if ! wait_for_keycloak_pods_ready $NAMESPACE; then
    echo "ERROR: Keycloak pods failed to become ready"
    echo "Running debug information collection..."
    output_debug_info $NAMESPACE
    exit 1
fi

# Get Admin Username/password for Keycloak
KC_ADMIN_USER=$(kubectl get secret keycloak-instance-initial-admin -n $NAMESPACE -o jsonpath='{.data.username}' | base64 --decode)
KC_ADMIN_PASS=$(kubectl get secret keycloak-instance-initial-admin -n $NAMESPACE -o jsonpath='{.data.password}' | base64 --decode)

# Gather version information for verification
echo "=========================================="
echo "KEYCLOAK VERSION INFORMATION"
echo "=========================================="
echo ""

# Get the operator CSV version
OPERATOR_CSV=$(kubectl get subscription -n $NAMESPACE -o jsonpath='{.items[?(@.spec.name=="keycloak-operator")].status.installedCSV}' 2>/dev/null || echo "Not found")
echo "Keycloak Operator CSV: $OPERATOR_CSV"

# Get the actual Keycloak image being used
KEYCLOAK_IMAGE=$(kubectl get pods -n $NAMESPACE -l app=keycloak -o jsonpath='{.items[0].spec.containers[0].image}' 2>/dev/null || echo "Not found")
echo "Keycloak Container Image: $KEYCLOAK_IMAGE"

# Extract version from image tag if possible
if [[ "$KEYCLOAK_IMAGE" != "Not found" ]]; then
    KEYCLOAK_VERSION_TAG=$(echo "$KEYCLOAK_IMAGE" | grep -oP '(?<=:).*' || echo "Unable to parse")
    echo "Keycloak Version Tag: $KEYCLOAK_VERSION_TAG"
fi

# Get Keycloak CR observedGeneration (shows CR is reconciled)
KEYCLOAK_GENERATION=$(kubectl get keycloak keycloak-instance -n $NAMESPACE -o jsonpath='{.status.observedGeneration}' 2>/dev/null || echo "Not found")
echo "Keycloak CR Observed Generation: $KEYCLOAK_GENERATION"

echo ""
echo "=========================================="
echo ""

# Keycloak is up!
echo "Keycloak is up and running!"
echo ""
echo "You can access Keycloak here:"
echo "    Keycloak Console:   https://$KEYCLOAK_INGRESS_URL"
echo ""
echo "Admin Credentials:"
echo "    Admin User:         $KC_ADMIN_USER"
echo "    Admin Password:     $KC_ADMIN_PASS"
echo ""
echo "Realm: $REALM_NAME"
echo ""
