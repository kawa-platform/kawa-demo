#!/bin/sh
# Consumes a topic through the gateway as a SASL client, from the beginning.
#
#   scripts/consume.sh                                   # systems watches telemetry.alerts
#   CLIENT=navigator TOPIC=telemetry.alerts scripts/consume.sh   # denied: navigator has no access
#
# The consumer group is <client>.console, which the governance rules accept.
set -eu
BOOTSTRAP="${BOOTSTRAP:-localhost:9092}"
CLIENT="${CLIENT:-systems}"
TOPIC="${TOPIC:-telemetry.alerts}"
GROUP="${GROUP:-$CLIENT.console}"
MAX="${MAX:-}"
DEMO_DIR="${DEMO_DIR:-/demo}"
KAFKA_BIN="${KAFKA_BIN:-/opt/kafka/bin}"

set -- --bootstrap-server "$BOOTSTRAP" --command-config "$DEMO_DIR/clients/$CLIENT.properties" \
    --topic "$TOPIC" --group "$GROUP" --from-beginning --property print.timestamp=true
echo "consuming $TOPIC as $CLIENT (group $GROUP)" >&2
if [ -z "$MAX" ]; then
    exec "$KAFKA_BIN/kafka-console-consumer.sh" "$@"
fi
# With MAX, also cap the run time (MAX_WAIT seconds): a topic the client may not see makes the
# consumer retry its metadata forever, which --timeout-ms does not cover.
set -- "$@" --max-messages "$MAX" --timeout-ms 15000
status=0
timeout "${MAX_WAIT:-30}" "$KAFKA_BIN/kafka-console-consumer.sh" "$@" || status=$?
if [ "$status" -eq 124 ] || [ "$status" -eq 143 ]; then
    echo "no records after ${MAX_WAIT:-30}s: $CLIENT cannot see $TOPIC (RBAC hides it), or the topic is empty" >&2
fi
exit "$status"
