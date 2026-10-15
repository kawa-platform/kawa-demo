#!/usr/bin/env bash
# Sets up mission control in a running gateway through the admin API. Idempotent (PUTs).
#
#   Physical topics telemetry.raw     JSON readings from the spacecraft
#                   navigation.raw    Avro state vectors (schema registry wire format)
#                   commands.uplink   commands to the crew
#   Virtual topics  telemetry.alerts   -> telemetry.raw    value.severity in ["warning", "critical"]
#                   navigation.artemis -> navigation.raw   Avro decoded via the schema registry,
#                                                          value.craft == "artemis-3"
#   SASL clients    spacecraft  the flight computer: streams telemetry and state vectors, and
#                               receives the uplinked commands
#                   director    the flight director: sees everything, uplinks commands, opens topics
#                   systems     the systems engineer: telemetry alerts only
#                   navigator   the navigation officer: Artemis state vectors only
#   Passwords are <client>-secret; each client's consumer groups are <client>.<purpose>.
#
# Each physical topic backs exactly one virtual topic: kawa 0.1.0-rc.2 maps a physical topic
# back to a single virtual name, so several filtered views over one physical topic don't work yet.
# The physical topics stay visible (exposePhysicalTopic) so the spacecraft can produce to them.
#
#   ADMIN_URL=http://localhost:8080 scripts/seed.sh
set -euo pipefail
source "$(dirname "$0")/lib.sh"

wait_for_admin
ensure_token
q='?consistency=applied'

echo "── virtual topics"
api PUT "/topics/telemetry.alerts$q" <<'JSON'
{"type": "virtual", "topic": "telemetry.raw", "exposePhysicalTopic": true,
 "valueFormat": {"type": "json"},
 "filter": {"type": "cel", "expression": "value.severity in [\"warning\", \"critical\"]"}}
JSON
api PUT "/topics/navigation.artemis$q" <<'JSON'
{"type": "virtual", "topic": "navigation.raw", "exposePhysicalTopic": true,
 "valueFormat": {"type": "avro"},
 "filter": {"type": "cel", "expression": "value.craft == \"artemis-3\""}}
JSON

echo "── SASL clients"
for client in spacecraft director systems navigator; do
    api PUT "/auth/clients/$client$q" <<JSON
{"mechanism": "PLAIN", "password": "$client-secret"}
JSON
done

# ACLs: a TOPIC/GROUP resource, an operation, ALLOW by default.
acl() { printf '{"resource": {"type": "%s", "pattern": "%s", "patternType": "%s"}, "operation": "%s"}' "$1" "$2" "$3" "$4"; }
role() {
    local name="$1"; shift
    local acls; acls=$(IFS=,; echo "$*")
    api PUT "/rbac/roles/$name$q" <<< "{\"acls\": [$acls]}"
}

echo "── RBAC roles"
# DESCRIBE on the virtual names too: rc.2 authorizes Metadata for an exposed physical topic under
# its virtual name, so without it telemetry.raw never shows up for the spacecraft.
role flight-computer \
    "$(acl TOPIC telemetry.raw LITERAL WRITE)" "$(acl TOPIC telemetry.raw LITERAL DESCRIBE)" \
    "$(acl TOPIC telemetry.alerts LITERAL DESCRIBE)" \
    "$(acl TOPIC navigation.raw LITERAL WRITE)" "$(acl TOPIC navigation.raw LITERAL DESCRIBE)" \
    "$(acl TOPIC navigation.artemis LITERAL DESCRIBE)" \
    "$(acl TOPIC commands.uplink LITERAL READ)" "$(acl TOPIC commands.uplink LITERAL DESCRIBE)" \
    "$(acl GROUP spacecraft. PREFIXED READ)" "$(acl GROUP spacecraft. PREFIXED DESCRIBE)" \
    '{"resource": {"type": "CLUSTER"}, "operation": "IDEMPOTENT_WRITE"}'
role flight-director \
    "$(acl TOPIC telemetry. PREFIXED READ)" "$(acl TOPIC telemetry. PREFIXED DESCRIBE)" \
    "$(acl TOPIC navigation. PREFIXED READ)" "$(acl TOPIC navigation. PREFIXED DESCRIBE)" \
    "$(acl TOPIC commands. PREFIXED READ)" "$(acl TOPIC commands. PREFIXED DESCRIBE)" \
    "$(acl TOPIC commands. PREFIXED WRITE)" \
    '{"resource": {"type": "CLUSTER"}, "operation": "CREATE"}' \
    '{"resource": {"type": "CLUSTER"}, "operation": "IDEMPOTENT_WRITE"}' \
    "$(acl GROUP director. PREFIXED READ)" "$(acl GROUP director. PREFIXED DESCRIBE)"
role alerts-console \
    "$(acl TOPIC telemetry.alerts LITERAL READ)" "$(acl TOPIC telemetry.alerts LITERAL DESCRIBE)" \
    "$(acl GROUP systems. PREFIXED READ)" "$(acl GROUP systems. PREFIXED DESCRIBE)"
role navigation-console \
    "$(acl TOPIC navigation.artemis LITERAL READ)" "$(acl TOPIC navigation.artemis LITERAL DESCRIBE)" \
    "$(acl GROUP navigator. PREFIXED READ)" "$(acl GROUP navigator. PREFIXED DESCRIBE)"

echo "── RBAC groups"
api PUT "/rbac/groups/spacecraft$q" <<'JSON'
{"clients": ["spacecraft"], "roles": ["flight-computer"]}
JSON
api PUT "/rbac/groups/flight-directors$q" <<'JSON'
{"clients": ["director"], "roles": ["flight-director"]}
JSON
api PUT "/rbac/groups/systems-engineers$q" <<'JSON'
{"clients": ["systems"], "roles": ["alerts-console"]}
JSON
api PUT "/rbac/groups/navigation-officers$q" <<'JSON'
{"clients": ["navigator"], "roles": ["navigation-console"]}
JSON

echo "mission control is go."
