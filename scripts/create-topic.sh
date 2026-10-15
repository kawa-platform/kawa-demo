#!/bin/sh
# Creates a physical topic through the gateway as a SASL client, so governance rules apply.
#
#   NAME=comms.loop-a scripts/create-topic.sh                                 # allowed
#   NAME=Houston scripts/create-topic.sh                                      # topic-naming
#   NAME=payload.big PARTITIONS=5 scripts/create-topic.sh                     # topic-sizing
#   NAME=commands.abort CONFIGS=retention.ms=60000 scripts/create-topic.sh    # command-retention
#
# CONFIGS is a comma-separated list of topic configs (key=value).
set -eu
BOOTSTRAP="${BOOTSTRAP:-localhost:9092}"
CLIENT="${CLIENT:-director}"
NAME="${NAME:?NAME is required}"
PARTITIONS="${PARTITIONS:-3}"
DEMO_DIR="${DEMO_DIR:-/demo}"
KAFKA_BIN="${KAFKA_BIN:-/opt/kafka/bin}"

CONFIGS="${CONFIGS:-}"

set -- --bootstrap-server "$BOOTSTRAP" --command-config "$DEMO_DIR/clients/$CLIENT.properties" \
    --create --topic "$NAME" --partitions "$PARTITIONS" --replication-factor 1
old_ifs=$IFS; IFS=,
for c in $CONFIGS; do set -- "$@" --config "$c"; done
IFS=$old_ifs
exec "$KAFKA_BIN/kafka-topics.sh" "$@"
