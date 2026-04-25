#!/bin/bash

_BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export CACHE_DIR="$_BASE_DIR/cache"

function load_cache_config() {

  if [[ ! -d "$CACHE_DIR" || ! -d "$CACHE_DIR/.git" ]]; then
    error_exit "Cache directory '$CACHE_DIR' does not exist or is not a git repository. Please run load-cache.sh first."
  fi

  # TIL: `declare -g` allows the variable to be global in the sourcing script, not just in this function. `export` does not work inside functions.
  # TIL: `declare -x` allows the variable to be passed to a subprocess e.g. kubectl, like `export`.
  declare -gx  CLUSTERS_DIR="$CACHE_DIR/clusters"
  mkdir -p "$CLUSTERS_DIR"

  declare -gx  BIN_DIR="$CACHE_DIR/bin"
  mkdir -p "$BIN_DIR"

  declare -gx  CERTS_DIR="$CACHE_DIR/certificates"
  mkdir -p "$CERTS_DIR"
}

function load_cluster_config() {

    load_cache_config

    local CLUSTER_NAME="$1"

    if [[ ! "$CLUSTER_NAME" =~ ^[a-zA-Z0-9]+$ ]]; then
        error_exit "Cluster name '$CLUSTER_NAME' is invalid. Cluster name must not be empty and must contain only letters and numbers."
    fi

    local CLUSTER_DIR="$CLUSTERS_DIR/$CLUSTER_NAME"

    if [[ ! -d "$CLUSTER_DIR" ]]; then
        error_exit "Cluster directory '$CLUSTER_DIR' does not exist. Make sure the cluster '$CLUSTER_NAME' has been created, or loaded from cache using load-cache.sh."
    fi

    if [[ ! -f "$CLUSTER_DIR/auth/kubeconfig" ]]; then
        error_exit "Kubeconfig file '$CLUSTER_DIR/auth/kubeconfig' does not exist. Make sure the cluster '$CLUSTER_NAME' has been properly configured."
    fi

    declare -gx CLUSTER_DIR="$CLUSTER_DIR"
    declare -gx KUBECONFIG="$CLUSTER_DIR/auth/kubeconfig"
    declare -gx CERT_DIR="$CERTS_DIR/$CLUSTER_NAME"
}

declare -rx GREEN='\033[0;32m'
declare -rx LIGHT_GREEN='\033[0;92m'
declare -rx CYAN='\033[0;36m'
declare -rx LIGHT_CYAN='\033[0;96m'
declare -rx PURPLE='\033[0;35m'
declare -rx LIGHT_PURPLE='\033[0;95m'
declare -rx YELLOW='\033[0;33m'
declare -rx LIGHT_YELLOW='\033[0;93m'
declare -rx RED='\033[0;31m'
declare -rx LIGHT_RED='\033[0;91m'
declare -rx NO_COLOR='\033[0m'

function success() {
    echo -e "${LIGHT_CYAN}[Success] $1${NO_COLOR}"
}

function success_exit() {
    echo -e "${LIGHT_GREEN}[Success] $1\nExiting.${NO_COLOR}"
    exit "${2:-0}"
}

function important() {
    echo -e "${LIGHT_PURPLE}$1${NO_COLOR}"
}

function warning() {
    echo -e "${LIGHT_YELLOW}[Warning] $1${NO_COLOR}"
}

function warning_exit() {
    echo -e "${LIGHT_YELLOW}[Warning] $1\nExiting.${NO_COLOR}"
    exit "${2:-0}"
}

function error() {
    echo -e "${LIGHT_RED}[Error] $1${NO_COLOR}" >&2
}

function error_exit() {
    echo -e "${LIGHT_RED}[Error] $1\nExiting.${NO_COLOR}" >&2
    exit "${2:-1}"
}

# Retries a command with exponential backoff.
# Usage: retry_with_backoff <max_retries> <label> <command...>
# Backoff schedule: 2^attempt seconds (2s, 4s, 8s, 16s, ...)
function retry_with_backoff() {
    local max_retries="$1"
    local label="$2"
    shift 2

    if [[ -z "$max_retries" || -z "$label" || -z "$*" ]]; then
        error_exit "retry_with_backoff requires at least 3 arguments: MAX_RETRIES LABEL COMMAND..."
    fi

    local attempt=1
    while true; do
        echo "Attempt $attempt/$max_retries for '$label'..."
        if "$@"; then
            return 0
        fi

        if [[ $attempt -ge $max_retries ]]; then
            error "All $max_retries attempt(s) for '$label' have failed."
            return 1
        fi

        local delay=$(( 2 ** attempt ))
        warning "Attempt $attempt/$max_retries for '$label' failed. Retrying in ${delay}s..."
        sleep "$delay"
        attempt=$(( attempt + 1 ))
    done
}

# Ensures a namespace exists and, on OpenShift, waits for SCC annotations to be applied.
# Usage: ensure_namespace <namespace>
function ensure_namespace() {
    local ns="$1"
    if [[ -z "$ns" ]]; then
        error_exit "ensure_namespace requires a namespace argument."
    fi

    if kubectl get namespace "$ns" >/dev/null 2>&1; then
        echo "Namespace '$ns' already exists, skipping creation"
    else
        echo "Creating namespace: $ns"
        kubectl create namespace "$ns"
    fi

    # On OpenShift the namespace controller asynchronously adds SCC annotations.
    # Deploying pods before the annotation lands causes FailedCreate errors.
    echo "Waiting for namespace '$ns' SCC annotations..."
    local timeout=60
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        local uid_range
        uid_range=$(kubectl get namespace "$ns" \
            -o jsonpath='{.metadata.annotations.openshift\.io/sa\.scc\.uid-range}' 2>/dev/null || echo "")
        if [[ -n "$uid_range" ]]; then
            echo "Namespace '$ns' is ready (uid-range: $uid_range)"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    warning "Namespace '$ns' SCC annotations were not applied within ${timeout}s — proceeding anyway."
    return 0
}

function wait_for() {

  local LABEL=$1
  local TIMEOUT=$2
  shift 2
  if [[ -z "$LABEL" || -z "$TIMEOUT" || -z "$*" ]]; then
      error_exit "wait function requires at least 3 arguments: LABEL TIMEOUT COMMAND... ."
  fi

  local START_TIME=$(date +%s)
  while true; do
      CURRENT_TIME=$(date +%s)
      ELAPSED_TIME=$((CURRENT_TIME - START_TIME))
      if [ $ELAPSED_TIME -ge "$TIMEOUT" ]; then
          warning "Timeout of $TIMEOUT seconds reached, stopping wait."
          return 1
      fi
      echo "Attempting $LABEL (elapsed: ${ELAPSED_TIME}s)..."
      if "$@" > /dev/null 2>&1 ; then
          success "Success!"
          return
      fi
      # echo "Attempt failed, retrying in 5 seconds..."
      sleep 5
  done
}
