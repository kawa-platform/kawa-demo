#!/usr/bin/env bash
# Starts mission control on minikube: Kafka, a schema registry, the kawa chart (gateway + studio),
# the gateway setup, the spacecraft and tool pods. Idempotent: re-run it to apply new versions.
#
#   k8s/up.sh
#   GATEWAY_VERSION=0.1.0-rc.3 k8s/up.sh       # versions come from versions.env otherwise
#
# Runs in the minikube profile kawa-demo (MINIKUBE_PROFILE), so other clusters are left alone.
# Needs: minikube, kubectl, helm, docker, envsubst.
set -euo pipefail
source "$(dirname "$0")/env.sh"

step "🛰️  minikube (profile $MINIKUBE_PROFILE)"
# check whether a Minikube profile named $MINIKUBE_PROFILE exists, regardless of whether Minikube considers it valid or invalid
if ! minikube profile list -o json 2>/dev/null | jq -e --arg p "$MINIKUBE_PROFILE" '[.valid[]?, .invalid[]?] | any(.Name == $p)' >/dev/null; then
    mk start --cpus="${MINIKUBE_CPUS:-4}" --memory="${MINIKUBE_MEMORY:-4g}"
elif [ "$(mk status --format '{{.APIServer}}' 2>/dev/null || true)" != Running ]; then
    # an existing cluster keeps its CPU and memory settings
    mk start || { echo "minikube profile $MINIKUBE_PROFILE does not start; recreate it with: minikube delete -p $MINIKUBE_PROFILE" >&2; exit 1; }
fi

step "📦 images"
for img in "$GATEWAY_IMAGE:$GATEWAY_VERSION" "$STUDIO_IMAGE:$STUDIO_VERSION"; do
    # If the image name ends with :local, load it into minikube. Otherwise, minikube will pull it from the registry.
    if [[ "$img" == *:local ]]; then
        echo "📥 loading $img"
        mk image load "$img"
    fi
done

step "🧱 namespace $NAMESPACE, Kafka, schema registry"
kc create namespace "$NAMESPACE" --dry-run=client -o yaml | kc apply -f - >/dev/null
envsubst "$SUBST_VARS" < "$DEMO_DIR/k8s/kafka.yaml" | kc apply -f -
envsubst "$SUBST_VARS" < "$DEMO_DIR/k8s/schema-registry.yaml" | kc apply -f -
kc rollout status statefulset/kafka --timeout=600s
kc wait --for=condition=complete job/kafka-topics-init --timeout=600s
kc rollout status deployment/schema-registry --timeout=600s

step "⎈  kawa chart $KAWA_CHART${KAWA_CHART_VERSION:+ $KAWA_CHART_VERSION} ($RELEASE): gateway $GATEWAY_VERSION, studio $STUDIO_VERSION"
chart="$KAWA_CHART"
[[ "$chart" == ../* || "$chart" == ./* ]] && chart="$DEMO_DIR/$chart"
chart_args=()
# if $chart is not a directory AND KAWA_CHART_VERSION is not empty, append --version and its value to chart_args.
[ ! -d "$chart" ] && [ -n "${KAWA_CHART_VERSION:-}" ] && chart_args+=(--version "$KAWA_CHART_VERSION")
helm upgrade --install "$RELEASE" "$chart" ${chart_args[@]+"${chart_args[@]}"} \
    --kube-context "$MINIKUBE_PROFILE" -n "$NAMESPACE" \
    -f "$DEMO_DIR/k8s/values-minikube.yaml" \
    --set gateway.image.repository="$GATEWAY_IMAGE",gateway.image.tag="$GATEWAY_VERSION" \
    --set studio.image.repository="$STUDIO_IMAGE",studio.image.tag="$STUDIO_VERSION" \
    --wait --timeout 5m

step "🧑‍🚀 demo workloads"
for part in scripts clients schemas; do
    kc create configmap "kawa-demo-$part" --from-file="$DEMO_DIR/$part" --dry-run=client -o yaml | kc apply -f - >/dev/null
done
kc delete job kawa-gateway-init --ignore-not-found >/dev/null
kc apply -f "$DEMO_DIR/k8s/gateway-init.yaml"
kc wait --for=condition=complete job/kawa-gateway-init --timeout=300s || { kc logs job/kawa-gateway-init; exit 1; }
kc logs job/kawa-gateway-init | tail -n 1
envsubst "$SUBST_VARS" < "$DEMO_DIR/k8s/demo.yaml" | kc apply -f -
kc rollout status deployment/kawa-spacecraft --timeout=600s
kc rollout status deployment/kawa-tools --timeout=600s
kc rollout status deployment/kawa-avro-tools --timeout=600s

step "🟢 running"
kc get pods -o custom-columns='POD:.metadata.name,IMAGE:.spec.containers[0].image,STATUS:.status.phase'
printf '\n  \033[1;36m%-14s\033[0m \033[1;32m%s\033[0m    then \033[4mhttp://localhost:5173/admin/\033[0m   (admin@kawa / admin)\n' "Open studio:" "make k8s-forward"
printf '  \033[1;36m%-14s\033[0m \033[1;32m%s\033[0m          (systems watches telemetry.alerts)\n' "Alerts:" "make k8s-consume"
printf '  \033[1;36m%-14s\033[0m \033[1;32m%s\033[0m (k8s-* targets)\n' "More:" "make help"
