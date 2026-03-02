#!/bin/bash

# Start Kafka Connect in distributed mode with configuration from environment variables

set -e

CONNECT_PROPS="/tmp/connect-distributed.properties"

# Generate connect-distributed.properties from environment variables
cat > "$CONNECT_PROPS" <<EOF
# Kafka Connect Distributed Worker Configuration
bootstrap.servers=${KAFKA_CONNECT_BOOTSTRAP_SERVERS:-localhost:9092}
group.id=${KAFKA_CONNECT_GROUP_ID:-converter-test-group}

# Internal topic configuration
config.storage.topic=${KAFKA_CONNECT_CONFIG_STORAGE_TOPIC:-connect-configs}
offset.storage.topic=${KAFKA_CONNECT_OFFSET_STORAGE_TOPIC:-connect-offsets}
status.storage.topic=${KAFKA_CONNECT_STATUS_STORAGE_TOPIC:-connect-status}
config.storage.replication.factor=${KAFKA_CONNECT_CONFIG_STORAGE_REPLICATION_FACTOR:-1}
offset.storage.replication.factor=${KAFKA_CONNECT_OFFSET_STORAGE_REPLICATION_FACTOR:-1}
status.storage.replication.factor=${KAFKA_CONNECT_STATUS_STORAGE_REPLICATION_FACTOR:-1}

# Default converters
key.converter=${KAFKA_CONNECT_KEY_CONVERTER:-org.apache.kafka.connect.storage.StringConverter}
value.converter=${KAFKA_CONNECT_VALUE_CONVERTER:-org.apache.kafka.connect.storage.StringConverter}

# Plugin path
plugin.path=${KAFKA_CONNECT_PLUGIN_PATH:-/opt/kafka/connect-plugins}

# REST API
rest.advertised.host.name=${KAFKA_CONNECT_REST_ADVERTISED_HOST_NAME:-connect}
rest.port=8083

# Offset flush interval
offset.flush.interval.ms=10000
EOF

echo "Starting Kafka Connect with configuration:"
echo "============================================"
cat "$CONNECT_PROPS"
echo "============================================"

exec /opt/kafka/bin/connect-distributed.sh "$CONNECT_PROPS"
