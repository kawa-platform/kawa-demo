#!/usr/bin/env bash
# Removes the kawa demo from minikube (the release and the whole namespace); the kawa-demo minikube
# profile keeps running. To remove the cluster too: minikube delete -p kawa-demo
set -euo pipefail
source "$(dirname "$0")/env.sh"

# The operator resources first, while the operator can still run their finalizers (it removes them
# from the gateway); otherwise deleting the namespace would hang on them.
if kubectl --context "$MINIKUBE_PROFILE" get crd groups.kawa.kawa-platform.github.io >/dev/null 2>&1; then
    kc delete $KAWA_KINDS --all --ignore-not-found --wait --timeout=120s
fi
helm uninstall "$RELEASE" --kube-context "$MINIKUBE_PROFILE" -n "$NAMESPACE" --ignore-not-found
kc delete namespace "$NAMESPACE" --ignore-not-found
