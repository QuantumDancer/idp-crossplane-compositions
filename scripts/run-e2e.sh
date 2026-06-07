#!/usr/bin/env bash
# Spins up a k3d cluster, installs Crossplane + the IDP chart, and runs all
# Chainsaw tests. The cluster is always deleted on exit (pass or fail).
#
# k3d (k3s in Docker/Podman) is used instead of kind because kind node images
# run systemd as PID 1, which requires a writable /sys/fs/cgroup. In a GitLab
# CI Docker executor container that path is read-only, so systemd never starts.
# k3s has no such dependency and works fine in nested container environments.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# In CI, append the job ID so concurrent pipelines on the same runner don't
# clash. CI_JOB_ID is unique across all jobs in a GitLab instance.
if [[ -n "${CI:-}" ]]; then
  CLUSTER_NAME="idp-test-${CI_JOB_ID}"
else
  CLUSTER_NAME="idp-test"
fi

cleanup() {
  echo "==> Deleting k3d cluster $CLUSTER_NAME"
  k3d cluster delete "$CLUSTER_NAME"
}
trap cleanup EXIT

echo "==> Creating k3d cluster"
# --snapshotter=native avoids overlay-on-overlay: k3s defaults to overlayfs,
# which fails when the job container's own filesystem is already overlay2.
#
# --api-port 0.0.0.0:6443 publishes the k3s API on all host interfaces. This
# is required when DOCKER_HOST points to a remote/Podman socket (CI): k3d
# containers are created on the host daemon, so the API server is a host
# process. The job container can only reach it via the host's gateway IP, not
# 127.0.0.1 (which resolves to the job container's own loopback).
#
# When DOCKER_HOST is set, we also inject the host gateway IP as a k3s TLS SAN.
# The cert k3s auto-generates covers 127.0.0.1 and the container's own IPs, but
# not the gateway. Without the SAN, kubectl rejects the cert after we patch the
# kubeconfig server address to the gateway IP.
k3d_cmd=(
  k3d cluster create "$CLUSTER_NAME"
  --wait
  --timeout 120s
  --api-port "0.0.0.0:6443"
  --k3s-arg "--snapshotter=native@server:*"
)
if [[ -n "${DOCKER_HOST:-}" ]]; then
  HOST_GW=$(ip route show default | awk '{print $3; exit}')
  if [[ -z "$HOST_GW" ]]; then
    echo "ERROR: could not determine host gateway IP from default route" >&2
    exit 1
  fi
  echo "==> Host gateway: ${HOST_GW} (adding to k3s TLS SANs)"
  # The TLS cert k3s auto-generates covers 127.0.0.1 and the container's own
  # IPs, but not the gateway we patch the kubeconfig to. Adding it here means
  # the cert is already valid when kubectl connects after the kubeconfig patch.
  k3d_cmd+=(--k3s-arg "--tls-san=${HOST_GW}@server:*")
fi

"${k3d_cmd[@]}"

# Patch the kubeconfig server address to the gateway so the job container can
# reach the API server, which runs on the host daemon (not inside this container).
if [[ -n "${DOCKER_HOST:-}" ]]; then
  echo "==> Patching kubeconfig server to host gateway ${HOST_GW}"
  kubectl config set-cluster "k3d-${CLUSTER_NAME}" --server="https://${HOST_GW}:6443"
fi

echo "==> Installing Crossplane"
# Read the pinned version from CI config; CI jobs override via the CROSSPLANE_VERSION env var.
# Helm chart versions don't carry the leading 'v', so strip it.
: "${CROSSPLANE_VERSION:=$(grep 'CROSSPLANE_VERSION:' "$REPO_ROOT/.gitlab-ci.yml" | awk -F'"' '{print $2}')}"
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm repo update
helm install crossplane crossplane-stable/crossplane \
  --version "${CROSSPLANE_VERSION#v}" \
  --namespace crossplane-system \
  --create-namespace \
  --wait

echo "==> Installing CRD stubs for external dependencies"
kubectl apply -f "$REPO_ROOT/tests/crds/"

# ArgoCD Application and ExternalSecret resources are created in the argocd namespace.
# We only need the namespace to exist — no ArgoCD controllers are required for composition testing.
echo "==> Creating argocd namespace"
kubectl create namespace argocd

echo "==> Installing IDP compositions chart"
helm install idp-compositions "$REPO_ROOT" --wait

echo "==> Waiting for Crossplane Functions to become healthy"
# Functions are OCI packages — give them time to pull and install
kubectl wait --for=condition=Healthy function \
  crossplane-contrib-function-go-templating \
  crossplane-contrib-function-auto-ready \
  --timeout=300s

echo "==> Waiting for XRDs to be Established"
# Crossplane must finish reconciling the XRD before XRs can be created.
# helm --wait does not block on this; the explicit wait is required.
# Note: "Offered" only applies to XRDs with claim types; this XRD has none.
kubectl wait --for=condition=Established \
  xrd/applicationenvironments.idp.rottler.io \
  --timeout=60s

echo "==> Running Chainsaw tests"
chainsaw test \
  --config "$REPO_ROOT/tests/chainsaw/chainsaw.yaml" \
  "$REPO_ROOT/tests/chainsaw/"
