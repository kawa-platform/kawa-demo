#!/usr/bin/env bash
# Starts mission control on minikube: Kafka, a schema registry, the kawa chart (gateway and studio), the
# kawa-operator chart, mission control as operator resources, the governance rules, the spacecraft and tool pods.
# Idempotent: re-run it to apply new versions.
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
# The gateway and the operator share the operator client's secret. Demo only: a fixed value.
kc create secret generic kawa-operator-client --from-literal=client-secret=kawa-operator-secret \
    --dry-run=client -o yaml | kc apply -f - >/dev/null
# chart_ref <chart> <version>: sets CHART and CHART_ARGS for helm. A local directory (relative to the
# demo) is used as is; a repository or OCI reference gets --version.
chart_ref() {
    CHART="$1"; CHART_ARGS=()
    [[ "$CHART" == ../* || "$CHART" == ./* ]] && CHART="$DEMO_DIR/$CHART"
    if [ ! -d "$CHART" ] && [ -n "$2" ]; then CHART_ARGS+=(--version "$2"); fi
}
chart_ref "$KAWA_CHART" "${KAWA_CHART_VERSION:-}"
helm upgrade --install "$RELEASE" "$CHART" ${CHART_ARGS[@]+"${CHART_ARGS[@]}"} \
    --kube-context "$MINIKUBE_PROFILE" -n "$NAMESPACE" \
    -f "$DEMO_DIR/k8s/values-minikube.yaml" \
    --set gateway.image.repository="$GATEWAY_IMAGE",gateway.image.tag="$GATEWAY_VERSION" \
    --set studio.image.repository="$STUDIO_IMAGE",studio.image.tag="$STUDIO_VERSION" \
    --wait --timeout 5m

step "⎈  kawa-operator chart $OPERATOR_CHART ($OPERATOR_RELEASE): operator $OPERATOR_VERSION"
# The operator chart is published with the operator's version, so OPERATOR_VERSION is also the chart
# version. With OPERATOR_VERSION=local, point OPERATOR_CHART at the operator checkout's chart.
chart_ref "$OPERATOR_CHART" "$([ "$OPERATOR_VERSION" = local ] || echo "$OPERATOR_VERSION")"
helm upgrade --install "$OPERATOR_RELEASE" "$CHART" ${CHART_ARGS[@]+"${CHART_ARGS[@]}"} \
    --kube-context "$MINIKUBE_PROFILE" -n "$NAMESPACE" \
    -f "$DEMO_DIR/k8s/operator-values-minikube.yaml" \
    --set image.repository="$OPERATOR_IMAGE",image.tag="$OPERATOR_VERSION" \
    --wait --timeout 5m

step "🛰️  mission control (operator resources)"
kc apply -f "$DEMO_DIR/k8s/mission-control.yaml"
if ! kc wait --for=condition=Ready $KAWA_KINDS --all --timeout=120s >/dev/null; then
    kc get $KAWA_KINDS -o wide
    echo "💥 mission control is not Ready; see REASON above and: kubectl logs deploy/$OPERATOR_RELEASE" >&2
    exit 1
fi
kc get $KAWA_KINDS

step "🧑‍🚀 demo workloads"
for part in scripts clients schemas; do
    kc create configmap "kawa-demo-$part" --from-file="$DEMO_DIR/$part" --dry-run=client -o yaml | kc apply -f - >/dev/null
done
kc delete job kawa-gateway-init kawa-governance --ignore-not-found >/dev/null
kc apply -f "$DEMO_DIR/k8s/governance.yaml"
kc wait --for=condition=complete job/kawa-governance --timeout=300s || { kc logs job/kawa-governance; exit 1; }
kc logs job/kawa-governance | tail -n 1
envsubst "$SUBST_VARS" < "$DEMO_DIR/k8s/demo.yaml" | kc apply -f -
kc rollout status deployment/kawa-spacecraft --timeout=600s
kc rollout status deployment/kawa-tools --timeout=600s
kc rollout status deployment/kawa-avro-tools --timeout=600s

step "🟢 running"
kc get pods -o custom-columns='POD:.metadata.name,IMAGE:.spec.containers[0].image,STATUS:.status.phase'
printf '\n  \033[1;36m%-14s\033[0m \033[1;32m%s\033[0m    then \033[4mhttp://localhost:5173/admin/\033[0m   (admin@kawa / admin)\n' "Open studio:" "make k8s-forward"
printf '  \033[1;36m%-14s\033[0m \033[1;32m%s\033[0m          (systems watches telemetry.alerts)\n' "Alerts:" "make k8s-consume"
printf '  \033[1;36m%-14s\033[0m \033[1;32m%s\033[0m (k8s-* targets)\n' "More:" "make help"
