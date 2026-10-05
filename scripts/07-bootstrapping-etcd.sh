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
# Enter previously cloned repository
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
  downloads/controller/etcd
  downloads/client/etcdctl
  units/etcd.service
)

for file in "${required_files[@]}"; do
  [ -f "$file" ] || die "Missing required file: $file"
done

echo "All required files are present."


# ------------------------------------------------------------
# Wait for server over Tailscale
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
# Verify certificates from the previous step already exist
# on the server
# ------------------------------------------------------------

log "Checking server certificates"

tailscale ssh "${SSH_USER}@${SERVER_HOST}" '
  set -euo pipefail

  required_files=(
    /root/ca.crt
    /root/kube-api-server.crt
    /root/kube-api-server.key
  )

  for file in "${required_files[@]}"; do
    if [ ! -f "$file" ]; then
      echo "ERROR: Missing required certificate: $file" >&2
      exit 1
    fi
  done

  echo "Required certificates are present."
'


# ------------------------------------------------------------
# Copy etcd binaries and systemd unit to server
#
# Equivalent to upstream:
#
# scp \
#   downloads/controller/etcd \
#   downloads/client/etcdctl \
#   units/etcd.service \
#   root@server:~/
#
# Using a tar stream over Tailscale SSH avoids scp entirely.
# ------------------------------------------------------------

log "Copying etcd files to server"

tar -cf - \
  downloads/controller/etcd \
  downloads/client/etcdctl \
  units/etcd.service |
tailscale ssh "${SSH_USER}@${SERVER_HOST}" '
  set -euo pipefail

  rm -rf /tmp/kthw-etcd
  mkdir -p /tmp/kthw-etcd

  tar -xf - -C /tmp/kthw-etcd

  cp /tmp/kthw-etcd/downloads/controller/etcd /root/etcd
  cp /tmp/kthw-etcd/downloads/client/etcdctl /root/etcdctl
  cp /tmp/kthw-etcd/units/etcd.service /root/etcd.service

  chmod +x /root/etcd /root/etcdctl

  rm -rf /tmp/kthw-etcd
'


# ------------------------------------------------------------
# Verify transferred files
# ------------------------------------------------------------

log "Verifying transferred files"

tailscale ssh "${SSH_USER}@${SERVER_HOST}" '
  set -euo pipefail

  ls -lh \
    /root/etcd \
    /root/etcdctl \
    /root/etcd.service
'


# ------------------------------------------------------------
# Install etcd binaries
#
# Upstream:
#
# mv etcd etcdctl /usr/local/bin/
# ------------------------------------------------------------

log "Installing etcd binaries"

tailscale ssh "${SSH_USER}@${SERVER_HOST}" '
  set -euo pipefail

  mv /root/etcd /usr/local/bin/etcd
  mv /root/etcdctl /usr/local/bin/etcdctl

  chmod 755 \
    /usr/local/bin/etcd \
    /usr/local/bin/etcdctl

  /usr/local/bin/etcd --version
  /usr/local/bin/etcdctl version
'


# ------------------------------------------------------------
# Configure etcd
#
# Upstream:
#
# mkdir -p /etc/etcd /var/lib/etcd
# chmod 700 /var/lib/etcd
#
# cp ca.crt kube-api-server.key kube-api-server.crt /etc/etcd/
# ------------------------------------------------------------

log "Configuring etcd"

tailscale ssh "${SSH_USER}@${SERVER_HOST}" '
  set -euo pipefail

  mkdir -p \
    /etc/etcd \
    /var/lib/etcd

  chmod 700 /var/lib/etcd

  cp /root/ca.crt \
     /root/kube-api-server.key \
     /root/kube-api-server.crt \
     /etc/etcd/

  chmod 644 \
    /etc/etcd/ca.crt \
    /etc/etcd/kube-api-server.crt

  chmod 600 \
    /etc/etcd/kube-api-server.key

  ls -la /etc/etcd
'


# ------------------------------------------------------------
# Install systemd service
#
# The upstream unit uses a single member named "controller"
# and binds etcd to localhost:
#
#   peer:   127.0.0.1:2380
#   client: 127.0.0.1:2379
#
# We intentionally keep that behavior unchanged.
# ------------------------------------------------------------

log "Installing etcd systemd unit"

tailscale ssh "${SSH_USER}@${SERVER_HOST}" '
  set -euo pipefail

  mv /root/etcd.service \
    /etc/systemd/system/etcd.service

  chmod 644 \
    /etc/systemd/system/etcd.service

  systemctl daemon-reload
'


# ------------------------------------------------------------
# Show resulting etcd configuration
# ------------------------------------------------------------

log "Showing etcd service configuration"

tailscale ssh "${SSH_USER}@${SERVER_HOST}" '
  set -euo pipefail

  systemctl cat etcd
'


# ------------------------------------------------------------
# Start etcd
#
# Upstream:
#
# systemctl daemon-reload
# systemctl enable etcd
# systemctl start etcd
# ------------------------------------------------------------

log "Starting etcd"

tailscale ssh "${SSH_USER}@${SERVER_HOST}" '
  set -euo pipefail

  systemctl daemon-reload
  systemctl enable etcd
  systemctl restart etcd
'


# ------------------------------------------------------------
# Wait for etcd systemd service
# ------------------------------------------------------------

log "Waiting for etcd service"

for attempt in {1..60}; do

  STATUS="$(
    tailscale ssh "${SSH_USER}@${SERVER_HOST}" \
      "systemctl is-active etcd 2>/dev/null || true"
  )"

  if [ "$STATUS" = "active" ]; then
    echo "etcd service is active."
    break
  fi

  if [ "$attempt" -eq 60 ]; then
    echo "etcd failed to become active."

    tailscale ssh "${SSH_USER}@${SERVER_HOST}" '
      systemctl status etcd --no-pager || true
      journalctl -u etcd --no-pager -n 100 || true
    '

    exit 1
  fi

  echo "Waiting for etcd... ($attempt/60)"
  sleep 2

done


# ------------------------------------------------------------
# Wait for etcd client endpoint
# ------------------------------------------------------------

log "Waiting for etcd endpoint"

for attempt in {1..60}; do

  if tailscale ssh "${SSH_USER}@${SERVER_HOST}" \
    'ETCDCTL_API=3 etcdctl \
      --endpoints=http://127.0.0.1:2379 \
      endpoint health >/dev/null 2>&1'
  then
    echo "etcd endpoint is healthy."
    break
  fi

  if [ "$attempt" -eq 60 ]; then
    echo "etcd endpoint did not become healthy."

    tailscale ssh "${SSH_USER}@${SERVER_HOST}" '
      systemctl status etcd --no-pager || true
      journalctl -u etcd --no-pager -n 100 || true
    '

    exit 1
  fi

  echo "Waiting for etcd endpoint... ($attempt/60)"
  sleep 2

done


# ------------------------------------------------------------
# Verification
#
# Upstream:
#
# etcdctl member list
# ------------------------------------------------------------

log "Listing etcd cluster members"

tailscale ssh "${SSH_USER}@${SERVER_HOST}" '
  set -euo pipefail

  ETCDCTL_API=3 etcdctl \
    --endpoints=http://127.0.0.1:2379 \
    member list
'


# ------------------------------------------------------------
# Additional health verification
# ------------------------------------------------------------

log "Checking etcd health"

tailscale ssh "${SSH_USER}@${SERVER_HOST}" '
  set -euo pipefail

  echo
  echo "Endpoint health:"
  ETCDCTL_API=3 etcdctl \
    --endpoints=http://127.0.0.1:2379 \
    endpoint health

  echo
  echo "Endpoint status:"
  ETCDCTL_API=3 etcdctl \
    --endpoints=http://127.0.0.1:2379 \
    endpoint status \
    --write-out=table
'


# ------------------------------------------------------------
# Verify ports
# ------------------------------------------------------------

log "Checking etcd listening ports"

tailscale ssh "${SSH_USER}@${SERVER_HOST}" '
  set -euo pipefail

  ss -lntp |
    grep -E ":(2379|2380)" ||
    {
      echo "ERROR: etcd ports are not listening." >&2
      exit 1
    }
'


# ------------------------------------------------------------
# Final service status
# ------------------------------------------------------------

log "Final etcd service status"

tailscale ssh "${SSH_USER}@${SERVER_HOST}" '
  systemctl status etcd \
    --no-pager \
    --full
'


log "etcd bootstrap completed"

echo
echo "etcd is running on server."
echo
echo "Client endpoint:"
echo "  http://127.0.0.1:2379"
echo
echo "Peer endpoint:"
echo "  http://127.0.0.1:2380"
echo
echo "Member name:"
echo "  controller"