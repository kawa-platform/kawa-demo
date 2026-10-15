#!/bin/sh
# The spacecraft, as SASL client spacecraft: streams telemetry to telemetry.raw
# (produce-telemetry.sh) and, at the same time, receives the commands uplinked to commands.uplink,
# printing each one as it arrives (consumer group spacecraft.receiver).
#
# Runs in the apache/kafka image (compose: the `spacecraft` service; k8s: the kawa-spacecraft pod).
# When either half stops, the other is stopped too, so the container restarts as a whole.
set -u
dir=$(dirname "$0")

sh "$dir/produce-telemetry.sh" &
telemetry=$!
CLIENT=spacecraft TOPIC=commands.uplink GROUP=spacecraft.receiver sh "$dir/consume.sh" &
receiver=$!

trap 'kill $telemetry $receiver 2>/dev/null; exit 0' TERM INT
while kill -0 "$telemetry" 2>/dev/null && kill -0 "$receiver" 2>/dev/null; do sleep 2; done
kill "$telemetry" "$receiver" 2>/dev/null
exit 1
