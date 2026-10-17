#!/usr/bin/env bash
# Port-forwards kawa studio to http://localhost:5173 and the gateway admin API to
# http://localhost:8080 (the studio rc image calls the admin API there from the browser).
# Runs until Ctrl-C.
set -euo pipefail
source "$(dirname "$0")/env.sh"

kubectl --context "$MINIKUBE_PROFILE" -n "$NAMESPACE" port-forward "svc/$RELEASE-studio" "${STUDIO_PORT:-5173}:80" &
kubectl --context "$MINIKUBE_PROFILE" -n "$NAMESPACE" port-forward "svc/$RELEASE-gateway" "${ADMIN_PORT:-8080}:8080" &
trap 'kill $(jobs -p) 2>/dev/null' EXIT INT TERM
echo "🖥️  kawa studio: http://localhost:${STUDIO_PORT:-5173}/admin/   (Ctrl-C to stop)"
wait
