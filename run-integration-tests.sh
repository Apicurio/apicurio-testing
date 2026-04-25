#!/bin/bash

# Function to display usage information
show_usage() {
    echo "Usage: $0 [--cluster <cluster_name>] --namespace <namespace> [--tag <registry_tag>] [--testGroups <groups>] [--registryProtocol <protocol>] [--registryHost <host>] [--registryPort <port>] [--realmName <realm>]"
    echo ""
    echo "This script runs the apicurio-registry integration tests against a deployed Registry instance."
    echo "The Registry URL is constructed as: http://registry-app-NAMESPACE.apps.CLUSTER_NAME.apicurio-testing.org"
    echo ""
    echo "Arguments:"
    echo "  --cluster           Optional. The OpenShift cluster name (default: \$USER)"
    echo "  --namespace         Required. The namespace where Registry is deployed"
    echo "  --tag               Optional. Git branch/tag to test against (default: main)"
    echo "  --testGroups       Optional. Test group(s) to run (default: smoke | serdes | acceptance). Examples: smoke, auth, 'smoke | serdes'"
    echo "  --registryProtocol  Optional. Registry protocol (default: http)"
    echo "  --registryHost      Optional. Registry host (default: registry-app-NAMESPACE.apps.CLUSTER_NAME.apicurio-testing.org)"
    echo "  --registryPort      Optional. Registry port (default: 80)"
    echo "  --realmName         Optional. Keycloak realm name (default: registry)"
    echo ""
    echo "Example: $0 --cluster okd419 --namespace testns1 --tag main --testGroups smoke"
    echo "Example: $0 --cluster okd419 --namespace testns1 --registryProtocol https --registryPort 443 --realmName myrealm"
}

# Parse command line arguments
CLUSTER_NAME="$USER"
NAMESPACE=""
APICURIO_REGISTRY_TAG="main"
TEST_GROUPS=""
REGISTRY_PROTOCOL=""
REGISTRY_HOST=""
REGISTRY_PORT=""
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
        --tag)
            APICURIO_REGISTRY_TAG="$2"
            shift 2
            ;;
        --testGroups)
            TEST_GROUPS="$2"
            shift 2
            ;;
        --registryProtocol)
            REGISTRY_PROTOCOL="$2"
            shift 2
            ;;
        --registryHost)
            REGISTRY_HOST="$2"
            shift 2
            ;;
        --registryPort)
            REGISTRY_PORT="$2"
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

# If no test profile specified, use the default groups from the pom.xml
# (smoke | serdes | acceptance)

if [ -z "$REGISTRY_PROTOCOL" ]; then
    REGISTRY_PROTOCOL=http
fi

if [ -z "$REGISTRY_HOST" ]; then
    REGISTRY_HOST=
fi

if [ -z "$REGISTRY_PORT" ]; then
    REGISTRY_PORT=80
fi

if [ -z "$REALM_NAME" ]; then
    REALM_NAME=registry
fi

# Get the directory where this script is located
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$BASE_DIR/shared.sh"

load_cluster_config "$CLUSTER_NAME"

export CLUSTER_NAME
export APICURIO_REGISTRY_TAG
export NAMESPACE
export BASE_DOMAIN="apicurio-testing.org"
export TESTS_DIR="$CLUSTER_DIR/namespaces/$NAMESPACE/tests"
export INTEGRATION_TESTS_DIR="$TESTS_DIR/integration"
export APPS_URL="apps.$CLUSTER_NAME.$BASE_DOMAIN"
export REGISTRY_PROTOCOL
if [ -z "$REGISTRY_HOST" ]; then
    REGISTRY_HOST=registry-app-$NAMESPACE.$APPS_URL
fi
export REGISTRY_HOST
export REGISTRY_PORT
export REALM_NAME
export REGISTRY_URL="$REGISTRY_PROTOCOL://$REGISTRY_HOST"
export KEYCLOAK_HOST="keycloak-$NAMESPACE.$APPS_URL"

export TOKEN_AUTH_URL="https://$KEYCLOAK_HOST/realms/$REALM_NAME/protocol/openid-connect/token"

mkdir -p $INTEGRATION_TESTS_DIR
cd $INTEGRATION_TESTS_DIR

# Clone the apicurio-registry repository
echo "Cloning apicurio-registry git repository at branch/tag: $APICURIO_REGISTRY_TAG"
if [ -d "apicurio-registry" ]; then
    echo "Repository already exists, removing and re-cloning..."
    rm -rf apicurio-registry
fi
git clone --branch $APICURIO_REGISTRY_TAG --depth 1 https://github.com/Apicurio/apicurio-registry.git

# Change to the repository directory
cd apicurio-registry

# Display some diagnostic info
echo ""
echo "Registry System Info:"
echo "--"
curl -s $REGISTRY_URL/apis/registry/v3/system/info | jq
echo "--"
echo ""
echo "Registry URL: $REGISTRY_URL"
echo "Testing against Registry version: $APICURIO_REGISTRY_TAG"
echo "Cluster: $CLUSTER_NAME"
echo "Namespace: $NAMESPACE"
echo ""
echo "------------------------------------"
echo "Running Integration Tests (groups: ${TEST_GROUPS:-default})..."
echo "------------------------------------"

# Step 1: Build dependency modules (skip all tests to avoid -Dgroups leaking into
# modules that don't have JUnit 5 on their test classpath)
echo "Building dependency modules..."
./mvnw install -am --no-transfer-progress \
    -Pintegration-tests \
    -pl integration-tests \
    -DskipTests \
    -Dmaven.javadoc.skip=true

# Step 2: Run integration tests (failsafe) in the integration-tests module only
MVNW_ARGS=(verify --no-transfer-progress -Pintegration-tests)
if [ -n "$TEST_GROUPS" ]; then
    MVNW_ARGS+=("-Dgroups=$TEST_GROUPS")
fi

./mvnw "${MVNW_ARGS[@]}" \
    -pl integration-tests \
    -Dmaven.javadoc.skip=true \
    -Dquarkus.oidc.token-path=$TOKEN_AUTH_URL \
    -Dquarkus.http.test-protocol=$REGISTRY_PROTOCOL \
    -Dquarkus.http.test-host=$REGISTRY_HOST \
    -Dquarkus.http.test-port=$REGISTRY_PORT

# Check if the mvnw command succeeded
MVNW_EXIT_CODE=$?
if [ $MVNW_EXIT_CODE -ne 0 ]; then
    echo ""
    echo "Integration tests failed with exit code: $MVNW_EXIT_CODE"
    exit $MVNW_EXIT_CODE
fi

echo ""
echo "Integration tests completed successfully."
