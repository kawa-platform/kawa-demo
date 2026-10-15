#!/usr/bin/env bash
# Removes the kawa demo from minikube (the release and the whole namespace); the kawa-demo minikube
# profile keeps running. To remove the cluster too: minikube delete -p kawa-demo
set -euo pipefail
source "$(dirname "$0")/env.sh"

helm uninstall "$RELEASE" --kube-context "$MINIKUBE_PROFILE" -n "$NAMESPACE" --ignore-not-found
kc delete namespace "$NAMESPACE" --ignore-not-found
