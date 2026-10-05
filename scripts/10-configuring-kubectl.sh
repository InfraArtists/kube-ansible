#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="kubernetes-the-hard-way"
API_SERVER="https://server.kubernetes.local:6443"
CLUSTER_NAME="kubernetes-the-hard-way"

log() {
  echo
  echo "============================================================"
  echo "==> $*"
  echo "============================================================"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}


# ------------------------------------------------------------
# Enter previously cloned repository
# ------------------------------------------------------------

if [ ! -d "$REPO_DIR" ]; then
  die "$REPO_DIR does not exist."
fi

cd "$REPO_DIR"

log "Working directory"
pwd


# ------------------------------------------------------------
# Check required files
# ------------------------------------------------------------

log "Checking required files"

required_files=(
  ca.crt
  admin.crt
  admin.key
)

for file in "${required_files[@]}"; do
  [ -f "$file" ] || die "Missing required file: $file"
done

command -v kubectl >/dev/null 2>&1 \
  || die "kubectl is not installed."

command -v curl >/dev/null 2>&1 \
  || die "curl is not installed."

command -v tailscale >/dev/null 2>&1 \
  || die "tailscale is not installed."


# ------------------------------------------------------------
# Verify server is reachable over Tailscale
# ------------------------------------------------------------

log "Checking Tailscale connectivity to server"

for attempt in {1..60}; do

  if tailscale ping \
    --timeout=2s \
    server \
    >/dev/null 2>&1
  then
    echo "server is reachable over Tailscale."
    break
  fi

  if [ "$attempt" -eq 60 ]; then
    die "Timed out waiting for server over Tailscale."
  fi

  echo "server is not reachable yet. ($attempt/60)"
  sleep 2

done


# ------------------------------------------------------------
# Verify server.kubernetes.local resolves
#
# This should resolve to the server's Tailscale IP from the
# /etc/hosts entries created in the compute-resources step.
# ------------------------------------------------------------

log "Checking Kubernetes API hostname"

getent hosts server.kubernetes.local \
  || die "server.kubernetes.local does not resolve."

SERVER_IP="$(
  getent hosts server.kubernetes.local |
  awk 'NR == 1 {print $1}'
)"

echo "server.kubernetes.local -> $SERVER_IP"


# ------------------------------------------------------------
# Verify remote API server
#
# Same verification as the upstream guide.
# ------------------------------------------------------------

log "Checking Kubernetes API server"

for attempt in {1..60}; do

  if curl \
    --fail \
    --silent \
    --show-error \
    --cacert ca.crt \
    "${API_SERVER}/version" \
    >/tmp/kubernetes-version.json
  then
    echo "Kubernetes API server is reachable."
    break
  fi

  if [ "$attempt" -eq 60 ]; then
    die "Unable to reach Kubernetes API server."
  fi

  echo "API server not ready yet. ($attempt/60)"
  sleep 2

done

cat /tmp/kubernetes-version.json
echo


# ------------------------------------------------------------
# Prepare kubeconfig directory
# ------------------------------------------------------------

log "Preparing local kubeconfig"

mkdir -p "$HOME/.kube"

if [ -f "$HOME/.kube/config" ]; then
  echo "Backing up existing kubeconfig."

  cp \
    "$HOME/.kube/config" \
    "$HOME/.kube/config.backup"
fi


# ------------------------------------------------------------
# Build admin kubeconfig
#
# This intentionally uses the default kubeconfig location:
#
#   ~/.kube/config
#
# so kubectl can be used without --kubeconfig afterward.
# ------------------------------------------------------------

log "Configuring kubectl cluster"

kubectl config set-cluster "$CLUSTER_NAME" \
  --certificate-authority=ca.crt \
  --embed-certs=true \
  --server="$API_SERVER"


log "Configuring admin credentials"

kubectl config set-credentials admin \
  --client-certificate=admin.crt \
  --client-key=admin.key \
  --embed-certs=true


log "Creating kubectl context"

kubectl config set-context "$CLUSTER_NAME" \
  --cluster="$CLUSTER_NAME" \
  --user=admin


log "Selecting kubectl context"

kubectl config use-context "$CLUSTER_NAME"


# ------------------------------------------------------------
# Protect kubeconfig
# ------------------------------------------------------------

chmod 600 "$HOME/.kube/config"


# ------------------------------------------------------------
# Show kubeconfig information
#
# Do not print raw embedded certificate/key data.
# ------------------------------------------------------------

log "Checking kubeconfig"

echo "Current context:"
kubectl config current-context

echo

echo "API server:"
kubectl config view \
  --minify \
  -o jsonpath='{.clusters[0].cluster.server}'

echo


# ------------------------------------------------------------
# Verify client/server versions
# ------------------------------------------------------------

log "Checking Kubernetes version"

kubectl version


# ------------------------------------------------------------
# Verify cluster nodes
# ------------------------------------------------------------

log "Listing Kubernetes nodes"

kubectl get nodes


# ------------------------------------------------------------
# Additional useful verification
# ------------------------------------------------------------

log "Listing nodes with addresses"

kubectl get nodes -o wide


# ------------------------------------------------------------
# Check expected nodes
# ------------------------------------------------------------

log "Checking node registration"

NODE_0="$(
  kubectl get node node-0 \
    -o jsonpath='{.metadata.name}' \
    2>/dev/null || true
)"

NODE_1="$(
  kubectl get node node-1 \
    -o jsonpath='{.metadata.name}' \
    2>/dev/null || true
)"

[ "$NODE_0" = "node-0" ] \
  || die "node-0 is not registered."

[ "$NODE_1" = "node-1" ] \
  || die "node-1 is not registered."

echo "node-0 is registered."
echo "node-1 is registered."


# ------------------------------------------------------------
# Check Ready state
# ------------------------------------------------------------

log "Checking worker readiness"

for node in node-0 node-1; do

  READY="$(
    kubectl get node "$node" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
  )"

  if [ "$READY" != "True" ]; then
    echo "ERROR: $node is not Ready."
    kubectl describe node "$node" || true
    exit 1
  fi

  echo "$node is Ready."

done


# ------------------------------------------------------------
# Final summary
# ------------------------------------------------------------

log "kubectl remote access configured"

echo
echo "Kubeconfig:"
echo "  $HOME/.kube/config"

echo
echo "Cluster:"
echo "  $CLUSTER_NAME"

echo
echo "API server:"
echo "  $API_SERVER"

echo
echo "Workers:"
echo "  node-0   Ready"
echo "  node-1   Ready"