#!/bin/sh
# The spacecraft's flight computer: one telemetry reading per $INTERVAL seconds to telemetry.raw
# through the gateway. Two crafts (artemis-3, gateway) and four subsystems take turns; most
# readings are nominal, with cautions, warnings and the odd critical on fixed cadences, so the
# telemetry.alerts view sees roughly one reading in six.
#
# Started by spacecraft.sh, in the apache/kafka image.
#   BOOTSTRAP=localhost:9092 CLIENT_CONFIG=clients/spacecraft.properties scripts/produce-telemetry.sh
set -eu
BOOTSTRAP="${BOOTSTRAP:-localhost:9092}"
CLIENT_CONFIG="${CLIENT_CONFIG:-/demo/clients/spacecraft.properties}"
TOPIC="${TOPIC:-telemetry.raw}"
INTERVAL="${INTERVAL:-1}"
KAFKA_BIN="${KAFKA_BIN:-/opt/kafka/bin}"

readings() {
    i=0
    while true; do
        i=$((i + 1))
        case $((i % 2)) in 0) craft=artemis-3 ;; *) craft=gateway ;; esac
        # offset cadences, so alerts land on every craft and subsystem
        if   [ $((i % 19)) -eq 5 ]; then severity=critical; drift=90
        elif [ $((i % 7)) -eq 3 ];  then severity=warning;  drift=45
        elif [ $((i % 5)) -eq 2 ];  then severity=caution;  drift=20
        else                             severity=nominal;  drift=$((i % 7))
        fi
        # base and drift in tenths of the unit
        case $(( (i / 2) % 4 )) in
            0) subsystem=power;        metric=bus_voltage;   unit=V;   base=280 ;;
            1) subsystem=thermal;      metric=cabin_temp;    unit=C;   base=220 ;;
            2) subsystem=life-support; metric=co2_partial;   unit=mmHg; base=30 ;;
            *) subsystem=propulsion;   metric=tank_pressure; unit=kPa; base=17000 ;;
        esac
        value=$((base + drift))
        printf '{"craft":"%s","subsystem":"%s","metric":"%s","value":%d.%d,"unit":"%s","severity":"%s","met":%d}\n' \
            "$craft" "$subsystem" "$metric" $((value / 10)) $((value % 10)) "$unit" "$severity" $((86400 + i))
        sleep "$INTERVAL"
    done
}

echo "streaming telemetry to $TOPIC via $BOOTSTRAP every ${INTERVAL}s"
readings | "$KAFKA_BIN/kafka-console-producer.sh" --bootstrap-server "$BOOTSTRAP" \
    --command-config "$CLIENT_CONFIG" --topic "$TOPIC"
