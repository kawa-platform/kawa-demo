#!/bin/sh
# Lists the topics the gateway advertises to a SASL client: virtual topics under their virtual
# names (telemetry.alerts, navigation.artemis), next to the physical topics they expose.
#
#   CLIENT=director scripts/list-topics.sh
set -eu
BOOTSTRAP="${BOOTSTRAP:-localhost:9092}"
CLIENT="${CLIENT:-director}"
DEMO_DIR="${DEMO_DIR:-/demo}"
KAFKA_BIN="${KAFKA_BIN:-/opt/kafka/bin}"

echo "topics visible to $CLIENT:" >&2
exec "$KAFKA_BIN/kafka-topics.sh" --bootstrap-server "$BOOTSTRAP" \
    --command-config "$DEMO_DIR/clients/$CLIENT.properties" --list
