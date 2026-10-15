#!/bin/sh
# Consumes an Avro virtual topic, printing records decoded with the schema registry.
#
#   scripts/consume-avro.sh     # navigator reads navigation.artemis: only artemis-3, decoded
set -eu
BOOTSTRAP="${BOOTSTRAP:-localhost:9092}"
CLIENT="${CLIENT:-navigator}"
TOPIC="${TOPIC:-navigation.artemis}"
GROUP="${GROUP:-$CLIENT.trajectory}"
SCHEMA_REGISTRY_URL="${SCHEMA_REGISTRY_URL:-http://schema-registry:8081}"
DEMO_DIR="${DEMO_DIR:-/demo}"

exec kafka-avro-console-consumer --bootstrap-server "$BOOTSTRAP" --topic "$TOPIC" --group "$GROUP" \
    --consumer.config "$DEMO_DIR/clients/$CLIENT.properties" --from-beginning \
    --timeout-ms "${TIMEOUT_MS:-15000}" \
    --property schema.registry.url="$SCHEMA_REGISTRY_URL"
