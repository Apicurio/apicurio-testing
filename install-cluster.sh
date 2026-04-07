#!/bin/bash

# Script to install OCP cluster
# Usage: ./install-cluster.sh [--cluster <cluster-name>]

# Get the directory where this script is located
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$BASE_DIR/shared.sh"

load_cache_config

# Source secrets.env if it exists
if [[ -f "$BASE_DIR/secrets.env" ]]; then
    echo "Sourcing environment variables from secrets.env..."
    source "$BASE_DIR/secrets.env"
fi

# Function to validate required environment variables
validate_env_vars() {
    local missing_vars=()
    
    if [[ -z "${AWS_ACCESS_KEY_ID:-}" ]]; then
        missing_vars+=("AWS_ACCESS_KEY_ID")
    fi
    
    if [[ -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
        missing_vars+=("AWS_SECRET_ACCESS_KEY")
    fi
    
    if [[ -z "${AWS_DEFAULT_REGION:-}" ]]; then
        missing_vars+=("AWS_DEFAULT_REGION")
    fi
    
    if [[ -z "${OPENSHIFT_PULL_SECRET:-}" ]]; then
        missing_vars+=("OPENSHIFT_PULL_SECRET")
    fi
    
    if [[ -z "${SSH_PUBLIC_KEY:-}" ]]; then
        missing_vars+=("SSH_PUBLIC_KEY")
    fi
    
    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        echo "Error: The following required environment variables are not set:"
        for var in "${missing_vars[@]}"; do
            echo "  - $var"
        done
        echo ""
        echo "Please set these environment variables before running the script."
        exit 1
    fi
}

extract_console_password() {

    if [[ ! -f "$CLUSTER_DIR/.openshift_install.log" ]]; then
        error_exit "$CLUSTER_DIR/.openshift_install.log file not found."
    fi

    local console_password
    console_password=$(grep -o 'Login to the console with user: \\"kubeadmin\\", and password: \\"[^"]*\\"' "$CLUSTER_DIR/.openshift_install.log" | sed 's/.*password: \\"\([^"]*\)\\".*/\1/')

    if [[ -z "$console_password" ]]; then
        warning "Could not extract console password from installation logs. Check $CLUSTER_DIR/.openshift_install.log for manual extraction."
        return
    fi

    if [[ -f "$CLUSTER_DIR/auth/kubeadmin-password" ]]; then
        local file_password
        file_password=$(cat auth/kubeadmin-password)
        if [[ "$console_password" != "$file_password" ]]; then
            warning "Console password from logs differs from the password file."
            important "Using password from logs as it's more reliable."
            echo "$console_password" > "$CLUSTER_DIR/auth/kubeadmin-password"
        fi
    else
        warning "$CLUSTER_DIR/auth/kubeadmin-password file not found, creating it with extracted password."
        mkdir -p auth
        echo "$console_password" > "$CLUSTER_DIR/auth/kubeadmin-password"
    fi
}

# Function to display usage
usage() {
    echo    "Usage: $0 [--cluster <cluster-name>] [--ocpVersion <ocp-version>] [--region <aws-region>] [--computeNodes <count>] [--controlPlaneNodes <count>] [--baseDomain <domain>] [--log-level <level>] [--force]"
    echo    ""
    echo    "Optional Parameters:"
    echo    "  --cluster <cluster-name>     Name of the cluster to install (default: $USER)"
    echo    "                               Must contain only letters and numbers"
    echo    ""
    echo    "Optional Parameters:"
    echo    "  --ocpVersion <version>       OCP version to install (default: 4.20)"
    echo    "  --region <aws-region>        AWS region to deploy to (default: us-east-1)"
    echo    "  --computeNodes <count>       Number of compute/worker nodes (default: 3)"
    echo    "  --controlPlaneNodes <count>  Number of control plane/master nodes (default: 3)"
    echo    "  --baseDomain <domain>        Base domain name for the cluster (default: apicurio-testing.org)"
    echo -e "  --log-level <level>          Log level for openshift-install (default: info). ${LIGHT_PURPLE}Use warn log level in CI to avoid leaking admin password.${NO_COLOR}"
    echo -e "  --force                     Force deletion of existing cluster directory. ${LIGHT_PURPLE}Might delete live cluster metadata.${NO_COLOR}"
    echo    "  --expiration <hours>         Set cluster expiration time in hours from now. A timestamp will be saved to the cluster directory."
    echo    "  --created-by <username>      Record who created the cluster (e.g. GitHub actor). Defaults to \$USER."
    echo    "  -h, --help                   Show this help message"
    exit 1
}

# Initialize variables
CLUSTER_NAME="$USER"
OCP_VERSION="4.20"
REGION="us-east-1"
COMPUTE_NODES="3"
CONTROL_PLANE_NODES="3"
BASE_DOMAIN="apicurio-testing.org"
LOG_LEVEL="info"
FORCE="false"
EXPIRATION_HOURS=""
CREATED_BY="$USER"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --cluster)
            CLUSTER_NAME="$2"
            shift 2
            ;;
        --ocpVersion)
            OCP_VERSION="$2"
            shift 2
            ;;
        --region)
            REGION="$2"
            shift 2
            ;;
        --computeNodes)
            COMPUTE_NODES="$2"
            shift 2
            ;;
        --controlPlaneNodes)
            CONTROL_PLANE_NODES="$2"
            shift 2
            ;;
        --baseDomain)
            BASE_DOMAIN="$2"
            shift 2
            ;;
        --log-level)
            LOG_LEVEL="$2"
            shift 2
            ;;
        --force)
            FORCE="true"
            shift 1
            ;;
        --expiration)
            EXPIRATION_HOURS="$2"
            shift 2
            ;;
        --created-by)
            CREATED_BY="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate cluster name format (only letters and numbers allowed)
if [[ ! "$CLUSTER_NAME" =~ ^[a-zA-Z0-9]+$ ]]; then
    echo "Error: Cluster name '$CLUSTER_NAME' is invalid"
    echo "Cluster name must contain only letters and numbers (no spaces, hyphens, or special characters)"
    exit 1
fi

# Validate node count parameters
if [[ ! "$COMPUTE_NODES" =~ ^[0-9]+$ ]] || [[ "$COMPUTE_NODES" -lt 0 ]]; then
    echo "Error: --computeNodes must be a non-negative integer"
    exit 1
fi

# Validate expiration hours if provided
if [[ -n "$EXPIRATION_HOURS" ]]; then
    if [[ ! "$EXPIRATION_HOURS" =~ ^[0-9]+$ ]] || [[ "$EXPIRATION_HOURS" -lt 1 ]]; then
        echo "Error: --expiration must be a positive integer (hours)"
        exit 1
    fi
fi

if [[ ! "$CONTROL_PLANE_NODES" =~ ^[0-9]+$ ]] || [[ "$CONTROL_PLANE_NODES" -lt 1 ]]; then
    echo "Error: --controlPlaneNodes must be a positive integer (minimum 1)"
    exit 1
fi

# Validate that control plane nodes is odd number for HA
if [[ "$CONTROL_PLANE_NODES" -gt 1 ]] && [[ $((CONTROL_PLANE_NODES % 2)) -eq 0 ]]; then
    echo "Warning: Control plane nodes should be an odd number for proper HA quorum (1, 3, 5, etc.)"
    echo "You specified $CONTROL_PLANE_NODES control plane nodes."
fi

# Validate base domain format (basic domain validation)
if [[ ! "$BASE_DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
    echo "Error: Base domain '$BASE_DOMAIN' is not a valid domain name format"
    echo "Domain names should contain only letters, numbers, dots, and hyphens"
    exit 1
fi

# Set AWS_DEFAULT_REGION to the region (either default or provided via --region)
export AWS_DEFAULT_REGION="$REGION"
echo "Using AWS region: $REGION"

# Validate required environment variables
validate_env_vars

echo "Installing OCP cluster with name: $CLUSTER_NAME (OCP version: $OCP_VERSION)"
echo "Cluster configuration: $CONTROL_PLANE_NODES control plane nodes, $COMPUTE_NODES compute nodes"
echo "Using base domain: $BASE_DOMAIN"
CLUSTER_DIR=$CLUSTERS_DIR/$CLUSTER_NAME

# Check if cluster directory already exists and handle it safely
if [[ -d "$CLUSTER_DIR" ]]; then
    warning "Cluster directory '$CLUSTER_DIR' already exists! It might contain state from a live cluster."

    if [[ "$FORCE" != "true" ]]; then
        echo ""
        echo "To proceed and DELETE the existing cluster directory, re-run with --force flag:"
        echo "  $0 --cluster $CLUSTER_NAME --force"
        echo ""
        echo "Warning: Make sure the cluster has been properly destroyed before using --force."
        exit 1
    else
        echo "Force flag detected. Removing existing cluster directory..."
        rm -rf "$CLUSTER_DIR"
    fi
fi

# Create a work directory for installing the OCP cluster
mkdir -p $CLUSTER_DIR
cd $CLUSTER_DIR || exit 1

# Write cluster metadata
echo -n "$CREATED_BY" > "$CLUSTER_DIR/created-by"
if [[ -n "$EXPIRATION_HOURS" ]]; then
    CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    EXPIRATION=$(date -u -d "+${EXPIRATION_HOURS} hours" +%Y-%m-%dT%H:%M:%SZ)
    echo -n "$CREATED_AT" > "$CLUSTER_DIR/created-at"
    echo -n "$EXPIRATION" > "$CLUSTER_DIR/expiration"
    echo "Cluster will expire at $EXPIRATION (in $EXPIRATION_HOURS hours)"
fi

"$BASE_DIR/download-ocp-installer.sh" --version "$OCP_VERSION"
if [[ $? -ne 0 ]]; then
    echo "Error: Failed to download openshift-install for OCP version $OCP_VERSION."
    exit 1
fi
OPENSHIFT_INSTALLER="$BIN_DIR/$OCP_VERSION/openshift-install"

# Create the install-config.yaml file (from template)
echo "Creating install-config.yaml from template with environment variable substitution"
export CLUSTER_NAME
export REGION
export COMPUTE_NODES
export CONTROL_PLANE_NODES
export BASE_DOMAIN
envsubst < $BASE_DIR/templates/ocp/$OCP_VERSION/install-config.yaml > $CLUSTER_DIR/install-config.yaml

echo -n "$OCP_VERSION" > "$CLUSTER_DIR/version"

unset SSH_AUTH_SOCK

# Install the cluster
$OPENSHIFT_INSTALLER create cluster --log-level="$LOG_LEVEL"

extract_console_password

# Generate a TLS cert for the cluster
cd $BASE_DIR || exit 1
./install-tls-cert.sh --cluster $CLUSTER_NAME

# Verify cluster is reachable and display information
echo ""
echo "=========================================="
echo "CLUSTER VERIFICATION"
echo "=========================================="
echo ""

# Load the cluster config to set KUBECONFIG
load_cluster_config "$CLUSTER_NAME"

# Test basic cluster connectivity
echo "Testing cluster connectivity..."
if ! kubectl cluster-info &>/dev/null; then
    echo "ERROR: Unable to connect to cluster"
    echo "KUBECONFIG: $KUBECONFIG"
    exit 1
fi
echo "✓ Cluster is reachable"
echo ""

# Get cluster version
CLUSTER_VERSION=$(kubectl get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || echo "Unable to determine")
echo "Cluster Version: $CLUSTER_VERSION"

# Get API server URL
API_SERVER=$(kubectl cluster-info | grep -oP 'Kubernetes control plane.*https://\K[^ ]+' || echo "Unable to determine")
echo "API Server: $API_SERVER"

# Get cluster operator status
echo ""
echo "Cluster Operators Status:"
DEGRADED_OPERATORS=$(kubectl get co --no-headers 2>/dev/null | awk '$3 != "False" || $4 != "False" || $5 != "True" {print $1}')
if [[ -z "$DEGRADED_OPERATORS" ]]; then
    echo "✓ All cluster operators are healthy"
else
    echo "⚠ The following operators are not healthy:"
    echo "$DEGRADED_OPERATORS"
fi

# Get node status
echo ""
echo "Node Status:"
NOT_READY_NODES=$(kubectl get nodes --no-headers 2>/dev/null | grep -v " Ready " || true)
READY_NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || echo "0")
TOTAL_NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l || echo "0")

if [[ "$READY_NODE_COUNT" -eq "$TOTAL_NODE_COUNT" ]] && [[ "$TOTAL_NODE_COUNT" -gt 0 ]]; then
    echo "✓ All $TOTAL_NODE_COUNT nodes are ready"
else
    echo "⚠ $READY_NODE_COUNT of $TOTAL_NODE_COUNT nodes are ready"
    if [[ -n "$NOT_READY_NODES" ]]; then
        echo "Not ready nodes:"
        echo "$NOT_READY_NODES"
    fi
fi

# Display nodes
echo ""
echo "Nodes:"
kubectl get nodes -o wide 2>/dev/null || echo "Unable to retrieve node information"

echo ""
echo "=========================================="
echo ""

echo "✓ Cluster installation completed successfully!"
echo ""
echo "Cluster: $CLUSTER_NAME"
echo "Console URL: https://console-openshift-console.apps.$CLUSTER_NAME.$BASE_DOMAIN"
echo "Kubeconfig: $CLUSTER_DIR/auth/kubeconfig"
echo ""
