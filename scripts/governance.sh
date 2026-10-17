#!/usr/bin/env bash
# Loads mission control's governance rules: what topics and consumer groups may be called, how
# physical topics are sized, and how long uplinked commands are kept. Rules are CEL checks the
# gateway evaluates on CreateTopics / AlterConfigs and group joins, so a violating request is
# rejected before it reaches Kafka.
#
#   ADMIN_URL=http://localhost:8080 scripts/governance.sh
#
# Afterwards, as director:  make topic NAME=comms.loop-a                                  -> created
#                         make topic NAME=Houston                                       -> naming
#                         make topic NAME=payload.big PARTITIONS=5                      -> sizing
#                         make topic NAME=commands.abort CONFIGS=retention.ms=60000     -> retention
set -euo pipefail
source "$(dirname "$0")/lib.sh"

wait_for_admin
ensure_token
q='?consistency=applied'

echo "📐 variables"
api PUT "/governance/variables/missionDomains$q" <<'JSON'
{"type": "list<string>", "value": "[\"telemetry\", \"navigation\", \"commands\", \"comms\", \"payload\"]", "note": "Mission domains a topic name starts with."}
JSON
api PUT "/governance/variables/partitionTiers$q" <<'JSON'
{"type": "list<int>", "value": "[1, 3, 6, 12]", "note": "Allowed partition counts."}
JSON
api PUT "/governance/variables/minCommandRetentionMs$q" <<'JSON'
{"type": "int", "value": "604800000", "note": "7 days: the post-flight review replays every command."}
JSON

echo "📜 rules"
api PUT "/governance/rules/topic-naming$q" <<'JSON'
{
  "description": "Topics are <domain>.<name>[.<name>...] in lower case, with a mission domain.",
  "errorMessage": "Topic names must be <domain>.<name> in lower case, with domain one of: telemetry, navigation, commands, comms, payload.",
  "selector": {"resourceType": "TOPIC", "scope": "BOTH", "operations": ["CREATE"]},
  "match": "ALL",
  "subRules": [
    {"kind": "check", "name": "shape",
     "expression": {"type": "CEL", "value": "topic.name.matches(\"^[a-z]+(\\\\.[a-z0-9-]+)+$\")"}},
    {"kind": "check", "name": "domain",
     "expression": {"type": "CEL", "value": "missionDomains.exists(d, topic.name.startsWith(d + '.'))"}}
  ]
}
JSON
api PUT "/governance/rules/topic-sizing$q" <<'JSON'
{
  "description": "Physical topics come in fixed sizes.",
  "errorMessage": "Partitions must be one of 1, 3, 6 or 12.",
  "selector": {"resourceType": "TOPIC", "scope": "PHYSICAL", "operations": ["CREATE"]},
  "match": "ALL",
  "subRules": [
    {"kind": "check", "name": "tier", "expression": {"type": "CEL", "value": "topic.partitions in partitionTiers"}}
  ]
}
JSON
api PUT "/governance/rules/command-retention$q" <<'JSON'
{
  "description": "Uplinked commands are kept for the post-flight review; checked on create and on config changes.",
  "errorMessage": "Command topics keep data for at least 7 days (retention.ms >= 604800000, or -1 for forever).",
  "selector": {"resourceType": "TOPIC", "scope": "PHYSICAL", "operations": ["CREATE", "ALTER"],
               "expression": {"type": "CEL", "value": "topic.name.startsWith('commands.')"}},
  "match": "ALL",
  "subRules": [
    {"kind": "check", "name": "retention",
     "expression": {"type": "CEL", "value": "!('retention.ms' in topic.configs) || int(topic.configs['retention.ms']) == -1 || int(topic.configs['retention.ms']) >= minCommandRetentionMs"}}
  ]
}
JSON
api PUT "/governance/rules/console-groups$q" <<'JSON'
{
  "description": "Consumer groups are <client>.<purpose>, so every console's groups are recognisable.",
  "errorMessage": "Consumer groups must be <client>.<purpose>, e.g. systems.console.",
  "selector": {"resourceType": "GROUP"},
  "match": "ALL",
  "subRules": [
    {"kind": "check", "name": "owner",
     "expression": {"type": "CEL", "value": "group.id.matches(\"^[a-z]+\\\\.[a-z0-9-]+$\")"}}
  ]
}
JSON

echo "✅ governance loaded. Dry run of a topic called Houston:"
curl -sS -X POST "$ADMIN_URL/governance/dry-run" -H "Authorization: Bearer $KAWA_TOKEN" \
    -H 'Content-Type: application/json' \
    -d '{"resourceType":"TOPIC","resource":{"name":"Houston","partitions":3,"replicationFactor":1}}' \
    | jq -r '"  allowed: \(.allowed)", (.rules[] | select(.outcome == "FAIL") | "  \(.rule): \(.message)")'
