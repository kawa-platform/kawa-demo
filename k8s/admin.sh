#!/usr/bin/env bash
# Runs one of the admin API scripts (token.sh, seed.sh, governance.sh) on this machine against
# the minikube gateway, through a temporary port-forward.
#
#   k8s/admin.sh governance.sh
set -euo pipefail
source "$(dirname "$0")/env.sh"
script="${1:?usage: k8s/admin.sh <token.sh|seed.sh|governance.sh>}"
port="${ADMIN_FORWARD_PORT:-18080}"

kubectl --context "$MINIKUBE_PROFILE" -n "$NAMESPACE" port-forward "svc/$RELEASE-gateway" "$port:8080" >/dev/null &
pf=$!
trap 'kill $pf 2>/dev/null' EXIT
for _ in $(seq 1 30); do curl -fsS -o /dev/null "http://localhost:$port/docs" 2>/dev/null && break; sleep 0.5; done
KAWA_ADMIN_PASSWORD="${KAWA_ADMIN_PASSWORD:-$(kc get secret "$RELEASE-gateway" -o jsonpath='{.data.admin-password}' | base64 -d)}" \
ADMIN_URL="http://localhost:$port" STUDIO_URL=http://localhost:5173 "$DEMO_DIR/scripts/$script"
