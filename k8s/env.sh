# Sourced by the k8s scripts: loads versions.env without overriding values already set in the
# environment, so `GATEWAY_VERSION=edge k8s/up.sh` wins over the file.
DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
while IFS='=' read -r key value; do
    [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
    [ -n "${!key+x}" ] || export "$key=$value"
done < "$DEMO_DIR/versions.env"
# The demo runs in its own minikube profile (and kubectl context), apart from any other cluster.
MINIKUBE_PROFILE="${MINIKUBE_PROFILE:-kawa-demo}"
NAMESPACE="${NAMESPACE:-kawa-demo}"
RELEASE="${RELEASE:-kawa}"
SUBST_VARS='${KAFKA_IMAGE} ${KAFKA_TOOLS_IMAGE} ${KAFKA_VERSION} ${SCHEMA_REGISTRY_IMAGE} ${SCHEMA_REGISTRY_VERSION}'
mk() { minikube -p "$MINIKUBE_PROFILE" "$@"; }
kc() { kubectl --context "$MINIKUBE_PROFILE" -n "$NAMESPACE" "$@"; }
step() { printf '\n\033[1m── %s\033[0m\n' "$*"; }
