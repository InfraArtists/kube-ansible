#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="kubernetes-the-hard-way"
SSH_USER="root"
SERVER_HOST="server"

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
# Enter repo
# ------------------------------------------------------------

if [ ! -d "$REPO_DIR" ]; then
  die "$REPO_DIR does not exist."
fi

cd "$REPO_DIR"

log "Working directory"
pwd


# ------------------------------------------------------------
# Check required local files
# ------------------------------------------------------------

log "Checking required files"

required_files=(
  downloads/controller/kube-apiserver
  downloads/controller/kube-controller-manager
  downloads/controller/kube-scheduler
  downloads/client/kubectl

  units/kube-apiserver.service
  units/kube-controller-manager.service
  units/kube-scheduler.service

  configs/kube-scheduler.yaml
  configs/kube-apiserver-to-kubelet.yaml

  ca.crt
)

for file in "${required_files[@]}"; do
  [ -f "$file" ] || die "Missing required file: $file"
done

echo "All required local files exist."


# ------------------------------------------------------------
# Wait for Tailscale server
# ------------------------------------------------------------

log "Waiting for server"

for attempt in {1..60}; do
  if tailscale ping \
    --timeout=2s \
    "$SERVER_HOST" \
    >/dev/null 2>&1
  then
    echo "$SERVER_HOST is reachable."
    break
  fi

  if [ "$attempt" -eq 60 ]; then
    die "Timed out waiting for $SERVER_HOST"
  fi

  echo "$SERVER_HOST is not reachable yet. ($attempt/60)"
  sleep 2
done


# ------------------------------------------------------------
# Verify Tailscale SSH
# ------------------------------------------------------------

log "Checking Tailscale SSH"

for attempt in {1..60}; do
  if tailscale ssh \
    "${SSH_USER}@${SERVER_HOST}" \
    "echo SSH_OK" \
    2>/dev/null |
    grep -qx "SSH_OK"
  then
    echo "SSH to $SERVER_HOST is ready."
    break
  fi

  if [ "$attempt" -eq 60 ]; then
    die "Unable to SSH to $SERVER_HOST"
  fi

  echo "SSH to $SERVER_HOST is not ready yet. ($attempt/60)"
  sleep 2
done


# ------------------------------------------------------------
# Check files produced by previous steps on server
# ------------------------------------------------------------

log "Checking previous-step files on server"

tailscale ssh "${SSH_USER}@${SERVER_HOST}" '
  set -euo pipefail

  required_files=(
    /root/ca.crt
    /root/ca.key
    /root/kube-api-server.crt
    /root/kube-api-server.key
    /root/service-accounts.crt
    /root/service-accounts.key
    /root/encryption-config.yaml
    /root/admin.kubeconfig
    /root/kube-controller-manager.kubeconfig
    /root/kube-scheduler.kubeconfig
  )

  for file in "${required_files[@]}"; do
    if [ ! -f "$file" ]; then
      echo "ERROR: Missing required server file: $file" >&2
      exit 1
    fi
  done

  echo "Previous-step files are present."
'


# ------------------------------------------------------------
# Copy binaries and configuration files
# ------------------------------------------------------------

log "Copying control-plane files to server"

tar -cf - \
  downloads/controller/kube-apiserver \
  downloads/controller/kube-controller-manager \
  downloads/controller/kube-scheduler \
  downloads/client/kubectl \
  units/kube-apiserver.service \
  units/kube-controller-manager.service \
  units/kube-scheduler.service \
  configs/kube-scheduler.yaml \
  configs/kube-apiserver-to-kubelet.yaml |
tailscale ssh "${SSH_USER}@${SERVER_HOST}" '
  set -euo pipefail

  rm -rf /tmp/kthw-control-plane
  mkdir -p /tmp/kthw-control-plane

  tar -xf - -C /tmp/kthw-control-plane

  cp \
    /tmp/kthw-control-plane/downloads/controller/kube-apiserver \
    /root/kube-apiserver

  cp \
    /tmp/kthw-control-plane/downloads/controller/kube-controller-manager \
    /root/kube-controller-manager

  cp \
    /tmp/kthw-control-plane/downloads/controller/kube-scheduler \
    /root/kube-scheduler

  cp \
    /tmp/kthw-control-plane/downloads/client/kubectl \
    /root/kubectl

  cp \
    /tmp/kthw-control-plane/units/kube-apiserver.service \
    /root/kube-apiserver.service

  cp \
    /tmp/kthw-control-plane/units/kube-controller-manager.service \
    /root/kube-controller-manager.service

  cp \
    /tmp/kthw-control-plane/units/kube-scheduler.service \
    /root/kube-scheduler.service

  cp \
    /tmp/kthw-control-plane/configs/kube-scheduler.yaml \
    /root/kube-scheduler.yaml

  cp \
    /tmp/kthw-control-plane/configs/kube-apiserver-to-kubelet.yaml \
    /root/kube-apiserver-to-kubelet.yaml

  rm -rf /tmp/kthw-control-plane
'


# ------------------------------------------------------------
# Provision control plane
# ------------------------------------------------------------

log "Provisioning Kubernetes control plane"

tailscale ssh "${SSH_USER}@${SERVER_HOST}" '
  set -euo pipefail

  mkdir -p \
    /etc/kubernetes/config \
    /var/lib/kubernetes


  # ----------------------------------------------------------
  # Install binaries
  # ----------------------------------------------------------

  mv \
    /root/kube-apiserver \
    /root/kube-controller-manager \
    /root/kube-scheduler \
    /root/kubectl \
    /usr/local/bin/

  chmod 755 \
    /usr/local/bin/kube-apiserver \
    /usr/local/bin/kube-controller-manager \
    /usr/local/bin/kube-scheduler \
    /usr/local/bin/kubectl


  # ----------------------------------------------------------
  # Configure API server
  # ----------------------------------------------------------

  mv \
    /root/ca.crt \
    /root/ca.key \
    /root/kube-api-server.key \
    /root/kube-api-server.crt \
    /root/service-accounts.key \
    /root/service-accounts.crt \
    /root/encryption-config.yaml \
    /var/lib/kubernetes/

  chmod 600 \
    /var/lib/kubernetes/ca.key \
    /var/lib/kubernetes/kube-api-server.key \
    /var/lib/kubernetes/service-accounts.key \
    /var/lib/kubernetes/encryption-config.yaml

  chmod 644 \
    /var/lib/kubernetes/ca.crt \
    /var/lib/kubernetes/kube-api-server.crt \
    /var/lib/kubernetes/service-accounts.crt

  mv \
    /root/kube-apiserver.service \
    /etc/systemd/system/kube-apiserver.service


  # ----------------------------------------------------------
  # Configure controller manager
  # ----------------------------------------------------------

  mv \
    /root/kube-controller-manager.kubeconfig \
    /var/lib/kubernetes/

  chmod 600 \
    /var/lib/kubernetes/kube-controller-manager.kubeconfig

  mv \
    /root/kube-controller-manager.service \
    /etc/systemd/system/


  # ----------------------------------------------------------
  # Configure scheduler
  # ----------------------------------------------------------

  mv \
    /root/kube-scheduler.kubeconfig \
    /var/lib/kubernetes/

  chmod 600 \
    /var/lib/kubernetes/kube-scheduler.kubeconfig

  mv \
    /root/kube-scheduler.yaml \
    /etc/kubernetes/config/

  mv \
    /root/kube-scheduler.service \
    /etc/systemd/system/


  # ----------------------------------------------------------
  # Install RBAC manifest for later
  # ----------------------------------------------------------

  test -f /root/kube-apiserver-to-kubelet.yaml


  # ----------------------------------------------------------
  # Start services
  # ----------------------------------------------------------

  systemctl daemon-reload

  systemctl enable \
    kube-apiserver \
    kube-controller-manager \
    kube-scheduler

  systemctl restart \
    kube-apiserver \
    kube-controller-manager \
    kube-scheduler
'


# ------------------------------------------------------------
# Wait for services
# ------------------------------------------------------------

log "Waiting for control-plane services"

services=(
  kube-apiserver
  kube-controller-manager
  kube-scheduler
)

for service in "${services[@]}"; do

  echo "Waiting for $service..."

  for attempt in {1..60}; do

    STATUS="$(
      tailscale ssh "${SSH_USER}@${SERVER_HOST}" \
        "systemctl is-active '$service' 2>/dev/null || true"
    )"

    if [ "$STATUS" = "active" ]; then
      echo "$service is active."
      break
    fi

    if [ "$attempt" -eq 60 ]; then
      echo "$service failed to become active."

      tailscale ssh "${SSH_USER}@${SERVER_HOST}" "
        systemctl status '$service' --no-pager || true
        journalctl -u '$service' --no-pager -n 100 || true
      "

      exit 1
    fi

    echo "$service is not ready yet. ($attempt/60)"
    sleep 2

  done

done


# ------------------------------------------------------------
# Verify API server locally on controller
# ------------------------------------------------------------

log "Waiting for Kubernetes API server"

for attempt in {1..60}; do

  if tailscale ssh "${SSH_USER}@${SERVER_HOST}" \
    'curl \
      --fail \
      --silent \
      --cacert /var/lib/kubernetes/ca.crt \
      https://127.0.0.1:6443/version \
      >/dev/null 2>&1'
  then
    echo "Kubernetes API server is reachable."
    break
  fi

  if [ "$attempt" -eq 60 ]; then
    echo "API server failed to become ready."

    tailscale ssh "${SSH_USER}@${SERVER_HOST}" '
      systemctl status kube-apiserver --no-pager || true
      journalctl -u kube-apiserver --no-pager -n 150 || true
    '

    exit 1
  fi

  echo "Waiting for API server... ($attempt/60)"
  sleep 2

done


# ------------------------------------------------------------
# Verify cluster from server with admin kubeconfig
# ------------------------------------------------------------

log "Checking Kubernetes cluster info"

tailscale ssh "${SSH_USER}@${SERVER_HOST}" '
  set -euo pipefail

  kubectl cluster-info \
    --kubeconfig /root/admin.kubeconfig
'


# ------------------------------------------------------------
# Apply RBAC for kubelet API access
# ------------------------------------------------------------

log "Applying kubelet RBAC"

tailscale ssh "${SSH_USER}@${SERVER_HOST}" '
  set -euo pipefail

  kubectl apply \
    -f /root/kube-apiserver-to-kubelet.yaml \
    --kubeconfig /root/admin.kubeconfig
'


# ------------------------------------------------------------
# Verify RBAC object
# ------------------------------------------------------------

log "Checking kube-apiserver-to-kubelet RBAC"

tailscale ssh "${SSH_USER}@${SERVER_HOST}" '
  set -euo pipefail

  kubectl get clusterrole \
    system:kube-apiserver-to-kubelet \
    --kubeconfig /root/admin.kubeconfig
'


# ------------------------------------------------------------
# Verify from jumpbox through Tailscale-backed hostname mapping
#
# Upstream uses:
#
# curl --cacert ca.crt \
#   https://server.kubernetes.local:6443/version
#
# We preserve that exact endpoint because step 03 placed
# server.kubernetes.local in /etc/hosts with the server's
# Tailscale IP.
# ------------------------------------------------------------

log "Verifying API server from jumpbox"

curl \
  --fail \
  --silent \
  --show-error \
  --cacert ca.crt \
  https://server.kubernetes.local:6443/version

echo


# ------------------------------------------------------------
# Additional API health checks
# ------------------------------------------------------------

log "Checking API readiness"

curl \
  --fail \
  --silent \
  --show-error \
  --cacert ca.crt \
  https://server.kubernetes.local:6443/readyz

echo


log "Checking API liveness"

curl \
  --fail \
  --silent \
  --show-error \
  --cacert ca.crt \
  https://server.kubernetes.local:6443/livez

echo


# ------------------------------------------------------------
# Show service status
# ------------------------------------------------------------

log "Final control-plane service status"

tailscale ssh "${SSH_USER}@${SERVER_HOST}" '
  for service in \
    kube-apiserver \
    kube-controller-manager \
    kube-scheduler
  do
    echo
    echo "[$service]"
    systemctl is-active "$service"
  done
'


log "Kubernetes control plane bootstrap completed"

echo
echo "Control plane:"
echo "  kube-apiserver         active"
echo "  kube-controller-manager active"
echo "  kube-scheduler          active"
echo
echo "API endpoint:"
echo "  https://server.kubernetes.local:6443"