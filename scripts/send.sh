#!/bin/sh
# Sends one record to a topic through the gateway as a SASL client: by default, the director
# director uplinks a burn command.
#
#   scripts/send.sh                        # director uplinks to commands.uplink
#   CLIENT=systems scripts/send.sh           # denied: only the flight director uplinks
set -eu
BOOTSTRAP="${BOOTSTRAP:-localhost:9092}"
CLIENT="${CLIENT:-director}"
TOPIC="${TOPIC:-commands.uplink}"
DEMO_DIR="${DEMO_DIR:-/demo}"
KAFKA_BIN="${KAFKA_BIN:-/opt/kafka/bin}"
MESSAGE='{"cmd":"OMS-BURN","craft":"artemis-3","durationS":42,"issuedBy":"director"}'
[ $# -gt 0 ] && MESSAGE="$1"

echo "sending to $TOPIC as $CLIENT: $MESSAGE" >&2
printf '%s\n' "$MESSAGE" | "$KAFKA_BIN/kafka-console-producer.sh" --bootstrap-server "$BOOTSTRAP" \
    --command-config "$DEMO_DIR/clients/$CLIENT.properties" --topic "$TOPIC" \
    --command-property max.block.ms=10000 --command-property delivery.timeout.ms=15000 \
    --command-property request.timeout.ms=10000
