#!/usr/bin/env bash
# Builds the app image, loads it into the local kind cluster, and applies
# the k8s/ manifests. Mirrors the flow CI (Phase 4) will automate.
set -euo pipefail

CLUSTER_NAME="agent-relay"
CONTEXT="kind-${CLUSTER_NAME}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHA="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
IMAGE="agent-relay:${SHA}"
KUBECTL="kubectl --context=${CONTEXT}"

echo "Building ${IMAGE}"
docker build -t "${IMAGE}" "${REPO_ROOT}"

echo "Loading ${IMAGE} into kind cluster ${CLUSTER_NAME}"
kind load docker-image "${IMAGE}" --name "${CLUSTER_NAME}"

"$(dirname "${BASH_SOURCE[0]}")/generate-secret.sh"

echo "Applying postgres manifests"
${KUBECTL} apply -f "${REPO_ROOT}/k8s/postgres-pvc.yaml"
${KUBECTL} apply -f "${REPO_ROOT}/k8s/postgres-deployment.yaml"
${KUBECTL} apply -f "${REPO_ROOT}/k8s/postgres-service.yaml"
${KUBECTL} rollout status deployment/postgres --timeout=120s

echo "Applying app manifests with image tag ${SHA}"
${KUBECTL} apply -f "${REPO_ROOT}/k8s/app-service.yaml"
sed "s/agent-relay:IMAGE_TAG/${IMAGE}/" "${REPO_ROOT}/k8s/app-deployment.yaml" | ${KUBECTL} apply -f -
${KUBECTL} rollout status deployment/agent-relay --timeout=120s

echo "Deployed. Run: kubectl port-forward svc/agent-relay 8000:8000"
