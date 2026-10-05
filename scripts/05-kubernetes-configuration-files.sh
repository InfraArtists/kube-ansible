#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="kubernetes-the-hard-way"
SSH_USER="root"

SERVER_HOST="server"
NODE_0_HOST="node-0"
NODE_1_HOST="node-1"

CLUSTER_NAME="kubernetes-the-hard-way"
API_SERVER="https://server.kubernetes.local:6443"

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
# Check local requirements
# ------------------------------------------------------------

log "Checking required commands"

for command in kubectl tailscale grep; do
  command -v "$command" >/dev/null 2>&1 \
    || die "Required command not found: $command"
done


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
# Verify required certificate files from previous step
# ------------------------------------------------------------

log "Checking certificate files"

required_files=(
  ca.crt

  node-0.crt
  node-0.key

  node-1.crt
  node-1.key

  kube-proxy.crt
  kube-proxy.key

  kube-controller-manager.crt
  kube-controller-manager.key

  kube-scheduler.crt
  kube-scheduler.key

  admin.crt
  admin.key
)

for file in "${required_files[@]}"; do
  [ -f "$file" ] || die "Missing required file: $file"
done

echo "All required certificate files are present."


# ------------------------------------------------------------
# Wait for Tailscale nodes
# ------------------------------------------------------------

wait_for_tailnet_host() {
  local host="$1"

  echo "Waiting for $host..."

  for attempt in {1..60}; do
    if tailscale ping \
      --timeout=2s \
      "$host" \
      >/dev/null 2>&1
    then
      echo "$host is reachable."
      return 0
    fi

    echo "$host is not reachable yet. ($attempt/60)"
    sleep 2
  done

  die "Timed out waiting for $host"
}


log "Waiting for Kubernetes nodes"

wait_for_tailnet_host "$SERVER_HOST"
wait_for_tailnet_host "$NODE_0_HOST"
wait_for_tailnet_host "$NODE_1_HOST"


# ------------------------------------------------------------
# Verify Tailscale SSH
# ------------------------------------------------------------

test_ssh() {
  local host="$1"

  echo "Testing Tailscale SSH to $host..."

  for attempt in {1..60}; do
    if tailscale ssh "${SSH_USER}@${host}" \
      "echo SSH_OK" \
      2>/dev/null |
      grep -qx "SSH_OK"
    then
      echo "SSH to $host is ready."
      return 0
    fi

    echo "SSH to $host is not ready yet. ($attempt/60)"
    sleep 2
  done

  die "Unable to SSH to $host"
}


log "Checking Tailscale SSH"

test_ssh "$SERVER_HOST"
test_ssh "$NODE_0_HOST"
test_ssh "$NODE_1_HOST"


# ------------------------------------------------------------
# Remove old kubeconfigs
# ------------------------------------------------------------

log "Cleaning old kubeconfig files"

rm -f \
  node-0.kubeconfig \
  node-1.kubeconfig \
  kube-proxy.kubeconfig \
  kube-controller-manager.kubeconfig \
  kube-scheduler.kubeconfig \
  admin.kubeconfig


# ------------------------------------------------------------
# Generate kubelet kubeconfigs
# ------------------------------------------------------------

log "Generating kubelet kubeconfig files"

for host in node-0 node-1; do

  echo "Generating ${host}.kubeconfig"

  kubectl config set-cluster "$CLUSTER_NAME" \
    --certificate-authority=ca.crt \
    --embed-certs=true \
    --server="$API_SERVER" \
    --kubeconfig="${host}.kubeconfig"

  kubectl config set-credentials "system:node:${host}" \
    --client-certificate="${host}.crt" \
    --client-key="${host}.key" \
    --embed-certs=true \
    --kubeconfig="${host}.kubeconfig"

  kubectl config set-context default \
    --cluster="$CLUSTER_NAME" \
    --user="system:node:${host}" \
    --kubeconfig="${host}.kubeconfig"

  kubectl config use-context default \
    --kubeconfig="${host}.kubeconfig"

done


# ------------------------------------------------------------
# Generate kube-proxy kubeconfig
# ------------------------------------------------------------

log "Generating kube-proxy kubeconfig"

kubectl config set-cluster "$CLUSTER_NAME" \
  --certificate-authority=ca.crt \
  --embed-certs=true \
  --server="$API_SERVER" \
  --kubeconfig=kube-proxy.kubeconfig

kubectl config set-credentials system:kube-proxy \
  --client-certificate=kube-proxy.crt \
  --client-key=kube-proxy.key \
  --embed-certs=true \
  --kubeconfig=kube-proxy.kubeconfig

kubectl config set-context default \
  --cluster="$CLUSTER_NAME" \
  --user=system:kube-proxy \
  --kubeconfig=kube-proxy.kubeconfig

kubectl config use-context default \
  --kubeconfig=kube-proxy.kubeconfig


# ------------------------------------------------------------
# Generate kube-controller-manager kubeconfig
# ------------------------------------------------------------

log "Generating kube-controller-manager kubeconfig"

kubectl config set-cluster "$CLUSTER_NAME" \
  --certificate-authority=ca.crt \
  --embed-certs=true \
  --server="$API_SERVER" \
  --kubeconfig=kube-controller-manager.kubeconfig

kubectl config set-credentials system:kube-controller-manager \
  --client-certificate=kube-controller-manager.crt \
  --client-key=kube-controller-manager.key \
  --embed-certs=true \
  --kubeconfig=kube-controller-manager.kubeconfig

kubectl config set-context default \
  --cluster="$CLUSTER_NAME" \
  --user=system:kube-controller-manager \
  --kubeconfig=kube-controller-manager.kubeconfig

kubectl config use-context default \
  --kubeconfig=kube-controller-manager.kubeconfig


# ------------------------------------------------------------
# Generate kube-scheduler kubeconfig
# ------------------------------------------------------------

log "Generating kube-scheduler kubeconfig"

kubectl config set-cluster "$CLUSTER_NAME" \
  --certificate-authority=ca.crt \
  --embed-certs=true \
  --server="$API_SERVER" \
  --kubeconfig=kube-scheduler.kubeconfig

kubectl config set-credentials system:kube-scheduler \
  --client-certificate=kube-scheduler.crt \
  --client-key=kube-scheduler.key \
  --embed-certs=true \
  --kubeconfig=kube-scheduler.kubeconfig

kubectl config set-context default \
  --cluster="$CLUSTER_NAME" \
  --user=system:kube-scheduler \
  --kubeconfig=kube-scheduler.kubeconfig

kubectl config use-context default \
  --kubeconfig=kube-scheduler.kubeconfig


# ------------------------------------------------------------
# Generate admin kubeconfig
#
# Upstream intentionally points this one to localhost because
# it is copied to the control-plane node.
# ------------------------------------------------------------

log "Generating admin kubeconfig"

kubectl config set-cluster "$CLUSTER_NAME" \
  --certificate-authority=ca.crt \
  --embed-certs=true \
  --server=https://127.0.0.1:6443 \
  --kubeconfig=admin.kubeconfig

kubectl config set-credentials admin \
  --client-certificate=admin.crt \
  --client-key=admin.key \
  --embed-certs=true \
  --kubeconfig=admin.kubeconfig

kubectl config set-context default \
  --cluster="$CLUSTER_NAME" \
  --user=admin \
  --kubeconfig=admin.kubeconfig

kubectl config use-context default \
  --kubeconfig=admin.kubeconfig


# ------------------------------------------------------------
# Verify generated kubeconfigs
# ------------------------------------------------------------

log "Generated kubeconfig files"

ls -lh \
  node-0.kubeconfig \
  node-1.kubeconfig \
  kube-proxy.kubeconfig \
  kube-controller-manager.kubeconfig \
  kube-scheduler.kubeconfig \
  admin.kubeconfig


# ------------------------------------------------------------
# Show kubeconfig endpoints/users
# ------------------------------------------------------------

log "Validating kubeconfig contents"

for config in \
  node-0.kubeconfig \
  node-1.kubeconfig \
  kube-proxy.kubeconfig \
  kube-controller-manager.kubeconfig \
  kube-scheduler.kubeconfig \
  admin.kubeconfig
do

  echo
  echo "[$config]"

  kubectl config view \
    --kubeconfig="$config" \
    --minify

done


# ------------------------------------------------------------
# Prepare worker directories
# ------------------------------------------------------------

log "Preparing worker configuration directories"

for host in "$NODE_0_HOST" "$NODE_1_HOST"; do

  tailscale ssh "${SSH_USER}@${host}" \
    "mkdir -p /var/lib/kube-proxy /var/lib/kubelet"

done


# ------------------------------------------------------------
# Distribute kube-proxy kubeconfig
# ------------------------------------------------------------

log "Distributing kube-proxy kubeconfig"

for host in "$NODE_0_HOST" "$NODE_1_HOST"; do

  echo "Copying kube-proxy config to $host"

  cat kube-proxy.kubeconfig |
  tailscale ssh "${SSH_USER}@${host}" \
    "cat > /var/lib/kube-proxy/kubeconfig"

done


# ------------------------------------------------------------
# Distribute node kubelet configs
# ------------------------------------------------------------

log "Distributing kubelet kubeconfigs"

cat node-0.kubeconfig |
tailscale ssh "${SSH_USER}@${NODE_0_HOST}" \
  "cat > /var/lib/kubelet/kubeconfig"

cat node-1.kubeconfig |
tailscale ssh "${SSH_USER}@${NODE_1_HOST}" \
  "cat > /var/lib/kubelet/kubeconfig"


# ------------------------------------------------------------
# Set worker permissions
# ------------------------------------------------------------

log "Setting worker kubeconfig permissions"

for host in "$NODE_0_HOST" "$NODE_1_HOST"; do

  tailscale ssh "${SSH_USER}@${host}" \
    "
      chmod 600 /var/lib/kube-proxy/kubeconfig
      chmod 600 /var/lib/kubelet/kubeconfig
    "

done


# ------------------------------------------------------------
# Distribute control-plane kubeconfigs
#
# Since SSH user is root, files can go directly into /root.
# ------------------------------------------------------------

log "Distributing control-plane kubeconfigs"

for file in \
  admin.kubeconfig \
  kube-controller-manager.kubeconfig \
  kube-scheduler.kubeconfig
do

  echo "Copying $file to server"

  cat "$file" |
  tailscale ssh "${SSH_USER}@${SERVER_HOST}" \
    "cat > /root/${file}"

done


# ------------------------------------------------------------
# Set server permissions
# ------------------------------------------------------------

log "Setting server kubeconfig permissions"

tailscale ssh "${SSH_USER}@${SERVER_HOST}" \
  "
    chmod 600 \
      /root/admin.kubeconfig \
      /root/kube-controller-manager.kubeconfig \
      /root/kube-scheduler.kubeconfig
  "


# ------------------------------------------------------------
# Verify node-0
# ------------------------------------------------------------

log "Verifying node-0 configuration"

tailscale ssh "${SSH_USER}@${NODE_0_HOST}" \
  "
    set -euo pipefail

    ls -l \
      /var/lib/kubelet/kubeconfig \
      /var/lib/kube-proxy/kubeconfig

    echo
    echo 'kubelet server:'

    grep -n 'server:' \
      /var/lib/kubelet/kubeconfig

    echo
    echo 'kube-proxy server:'

    grep -n 'server:' \
      /var/lib/kube-proxy/kubeconfig
  "


# ------------------------------------------------------------
# Verify node-1
# ------------------------------------------------------------

log "Verifying node-1 configuration"

tailscale ssh "${SSH_USER}@${NODE_1_HOST}" \
  "
    set -euo pipefail

    ls -l \
      /var/lib/kubelet/kubeconfig \
      /var/lib/kube-proxy/kubeconfig

    echo
    echo 'kubelet server:'

    grep -n 'server:' \
      /var/lib/kubelet/kubeconfig

    echo
    echo 'kube-proxy server:'

    grep -n 'server:' \
      /var/lib/kube-proxy/kubeconfig
  "


# ------------------------------------------------------------
# Verify server configs
# ------------------------------------------------------------

log "Verifying control-plane configuration"

tailscale ssh "${SSH_USER}@${SERVER_HOST}" \
  "
    set -euo pipefail

    ls -l \
      /root/admin.kubeconfig \
      /root/kube-controller-manager.kubeconfig \
      /root/kube-scheduler.kubeconfig

    echo
    echo 'Admin API endpoint:'
    grep -n 'server:' /root/admin.kubeconfig

    echo
    echo 'Controller Manager API endpoint:'
    grep -n 'server:' /root/kube-controller-manager.kubeconfig

    echo
    echo 'Scheduler API endpoint:'
    grep -n 'server:' /root/kube-scheduler.kubeconfig
  "


# ------------------------------------------------------------
# Final expected endpoint checks
# ------------------------------------------------------------

log "Checking expected API endpoints"

for config in \
  node-0.kubeconfig \
  node-1.kubeconfig \
  kube-proxy.kubeconfig \
  kube-controller-manager.kubeconfig \
  kube-scheduler.kubeconfig
do

  if ! grep -q \
    "server: https://server.kubernetes.local:6443" \
    "$config"
  then
    die "$config does not reference server.kubernetes.local:6443"
  fi

done

if ! grep -q \
  "server: https://127.0.0.1:6443" \
  admin.kubeconfig
then
  die "admin.kubeconfig does not reference 127.0.0.1:6443"
fi


log "Kubernetes configuration-file step completed"

echo
echo "Generated:"
echo "  node-0.kubeconfig"
echo "  node-1.kubeconfig"
echo "  kube-proxy.kubeconfig"
echo "  kube-controller-manager.kubeconfig"
echo "  kube-scheduler.kubeconfig"
echo "  admin.kubeconfig"

echo
echo "Distributed:"
echo "  node-0 -> kubelet + kube-proxy configs"
echo "  node-1 -> kubelet + kube-proxy configs"
echo "  server -> admin + controller-manager + scheduler configs"