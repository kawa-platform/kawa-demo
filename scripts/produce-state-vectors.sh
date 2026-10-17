#!/bin/sh
# Produces Avro state vectors (schema registry wire format) to navigation.raw as the spacecraft,
# alternating artemis-3 and gateway. The schema (schemas/state-vector.avsc) is registered under
# subject navigation.raw-value on first use. The gateway decodes these records with the registry,
# so navigation.artemis can filter on value.craft even though the bytes on the wire are Avro.
#
# Runs in the confluentinc/cp-schema-registry image, which ships kafka-avro-console-producer.
set -eu
BOOTSTRAP="${BOOTSTRAP:-localhost:9092}"
CLIENT="${CLIENT:-spacecraft}"
TOPIC="${TOPIC:-navigation.raw}"
SCHEMA_REGISTRY_URL="${SCHEMA_REGISTRY_URL:-http://schema-registry:8081}"
DEMO_DIR="${DEMO_DIR:-/demo}"
COUNT="${COUNT:-8}"

i=0
while [ "$i" -lt "$COUNT" ]; do
    i=$((i + 1))
    if [ $((i % 2)) -eq 0 ]; then
        # artemis-3 on its way to the Moon: higher every fix, slowing down
        printf '{"craft":"artemis-3","met":%d,"altitudeKm":%d.0,"velocityKms":%d.%d,"groundStation":"%s"}\n' \
            $((86400 + i * 600)) $((120000 + i * 15000)) $(( (30 - i) / 10 )) $(( (30 - i) % 10 )) madrid
    else
        # the Gateway station in its lunar halo orbit
        printf '{"craft":"gateway","met":%d,"altitudeKm":%d.0,"velocityKms":1.%d,"groundStation":"%s"}\n' \
            $((86400 + i * 600)) $((380000 + i * 100)) "$i" canberra
    fi
done | kafka-avro-console-producer --bootstrap-server "$BOOTSTRAP" --topic "$TOPIC" \
    --producer.config "$DEMO_DIR/clients/$CLIENT.properties" \
    --property schema.registry.url="$SCHEMA_REGISTRY_URL" \
    --property value.schema.file="$DEMO_DIR/schemas/state-vector.avsc"
echo "🧭 produced $COUNT state vectors to $TOPIC (half of them artemis-3)"
