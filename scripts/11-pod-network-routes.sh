#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="kubernetes-the-hard-way"
SSH_USER="root"

SERVER_HOST="server"
NODE_0_HOST="node-0"
NODE_1_HOST="node-1"

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

[ -f machines.txt ] || die "machines.txt does not exist."

log "Working directory"
pwd

# ------------------------------------------------------------
# Read Pod CIDRs
# ------------------------------------------------------------

NODE_0_SUBNET="$(
  awk '$3 == "node-0" {print $4}' machines.txt
)"

NODE_1_SUBNET="$(
  awk '$3 == "node-1" {print $4}' machines.txt
)"

[ -n "$NODE_0_SUBNET" ] \
  || die "Could not determine node-0 Pod subnet."

[ -n "$NODE_1_SUBNET" ] \
  || die "Could not determine node-1 Pod subnet."

echo "node-0 Pod subnet: $NODE_0_SUBNET"
echo "node-1 Pod subnet: $NODE_1_SUBNET"

# ------------------------------------------------------------
# Wait for Tailscale nodes
# ------------------------------------------------------------

wait_for_host() {
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

    echo "$host not reachable yet. ($attempt/60)"
    sleep 2
  done

  die "Timed out waiting for $host"
}

log "Checking Tailscale connectivity"

wait_for_host "$SERVER_HOST"
wait_for_host "$NODE_0_HOST"
wait_for_host "$NODE_1_HOST"

# ------------------------------------------------------------
# Verify Tailscale SSH
# ------------------------------------------------------------

test_ssh() {
  local host="$1"

  echo "Testing SSH to $host..."

  for attempt in {1..60}; do
    if tailscale ssh \
      "${SSH_USER}@${host}" \
      "echo SSH_OK" \
      2>/dev/null |
      grep -qx "SSH_OK"
    then
      echo "SSH to $host is ready."
      return 0
    fi

    echo "SSH to $host not ready yet. ($attempt/60)"
    sleep 2
  done

  die "Unable to SSH to $host"
}

log "Checking Tailscale SSH"

test_ssh "$SERVER_HOST"
test_ssh "$NODE_0_HOST"
test_ssh "$NODE_1_HOST"

# ------------------------------------------------------------
# Discover Tailscale IPs from each runner itself
# ------------------------------------------------------------

get_ts_ip() {
  local host="$1"

  tailscale ssh \
    "${SSH_USER}@${host}" \
    "tailscale ip -4 | head -n1"
}

SERVER_IP="$(get_ts_ip "$SERVER_HOST")"
NODE_0_IP="$(get_ts_ip "$NODE_0_HOST")"
NODE_1_IP="$(get_ts_ip "$NODE_1_HOST")"

[ -n "$SERVER_IP" ] || die "Could not get server Tailscale IP."
[ -n "$NODE_0_IP" ] || die "Could not get node-0 Tailscale IP."
[ -n "$NODE_1_IP" ] || die "Could not get node-1 Tailscale IP."

log "Tailscale addresses"

echo "server : $SERVER_IP"
echo "node-0 : $NODE_0_IP"
echo "node-1 : $NODE_1_IP"

# ------------------------------------------------------------
# Enable forwarding on worker nodes
# ------------------------------------------------------------

log "Enabling IPv4 forwarding"

for host in \
  "$NODE_0_HOST" \
  "$NODE_1_HOST"
do

  tailscale ssh "${SSH_USER}@${host}" '
    set -euo pipefail

    cat > /etc/sysctl.d/99-kubernetes-routing.conf <<EOF
net.ipv4.ip_forward = 1
EOF

    sysctl -p /etc/sysctl.d/99-kubernetes-routing.conf

    test "$(sysctl -n net.ipv4.ip_forward)" = "1"
  '

done

# ------------------------------------------------------------
# Show Tailscale routes before changes
# ------------------------------------------------------------

log "Checking Tailscale interfaces"

for host in \
  "$SERVER_HOST" \
  "$NODE_0_HOST" \
  "$NODE_1_HOST"
do

  echo
  echo "[$host]"

  tailscale ssh "${SSH_USER}@${host}" '
    set -euo pipefail

    ip link show tailscale0
    ip addr show dev tailscale0

    echo
    echo "Tailscale table 52:"
    ip route show table 52 || true
  '

done

# ------------------------------------------------------------
# Add routes on server
#
# Equivalent upstream logic:
#
#   NODE_0_SUBNET via NODE_0_IP
#   NODE_1_SUBNET via NODE_1_IP
#
# Tailscale adaptation:
#
#   dev tailscale0 onlink
#
# `onlink` tells Linux to accept the Tailscale peer address
# as the next-hop even though it is not part of a conventional
# directly attached subnet.
# ------------------------------------------------------------

log "Adding Pod routes on server"

tailscale ssh "${SSH_USER}@${SERVER_HOST}" \
  "
    set -euo pipefail

    ip route replace '${NODE_0_SUBNET}' \
      via '${NODE_0_IP}' \
      dev tailscale0 \
      onlink

    ip route replace '${NODE_1_SUBNET}' \
      via '${NODE_1_IP}' \
      dev tailscale0 \
      onlink
  "

# ------------------------------------------------------------
# node-0 -> node-1 Pod CIDR
# ------------------------------------------------------------

log "Adding node-0 route to node-1 Pod network"

tailscale ssh "${SSH_USER}@${NODE_0_HOST}" \
  "
    set -euo pipefail

    ip route replace '${NODE_1_SUBNET}' \
      via '${NODE_1_IP}' \
      dev tailscale0 \
      onlink
  "

# ------------------------------------------------------------
# node-1 -> node-0 Pod CIDR
# ------------------------------------------------------------

log "Adding node-1 route to node-0 Pod network"

tailscale ssh "${SSH_USER}@${NODE_1_HOST}" \
  "
    set -euo pipefail

    ip route replace '${NODE_0_SUBNET}' \
      via '${NODE_0_IP}' \
      dev tailscale0 \
      onlink
  "

# ------------------------------------------------------------
# Show resulting routes
# ------------------------------------------------------------

log "Verifying routes"

echo
echo "[server]"
tailscale ssh "${SSH_USER}@${SERVER_HOST}" \
  "ip route"

echo
echo "[node-0]"
tailscale ssh "${SSH_USER}@${NODE_0_HOST}" \
  "ip route"

echo
echo "[node-1]"
tailscale ssh "${SSH_USER}@${NODE_1_HOST}" \
  "ip route"

# ------------------------------------------------------------
# Explicit route validation
# ------------------------------------------------------------

log "Checking expected route entries"

SERVER_ROUTES="$(
  tailscale ssh "${SSH_USER}@${SERVER_HOST}" \
    "ip route"
)"

NODE_0_ROUTES="$(
  tailscale ssh "${SSH_USER}@${NODE_0_HOST}" \
    "ip route"
)"

NODE_1_ROUTES="$(
  tailscale ssh "${SSH_USER}@${NODE_1_HOST}" \
    "ip route"
)"

grep -Fq \
  "${NODE_0_SUBNET} via ${NODE_0_IP} dev tailscale0" \
  <<< "$SERVER_ROUTES" \
  || die "server route to node-0 Pod CIDR is missing."

grep -Fq \
  "${NODE_1_SUBNET} via ${NODE_1_IP} dev tailscale0" \
  <<< "$SERVER_ROUTES" \
  || die "server route to node-1 Pod CIDR is missing."

grep -Fq \
  "${NODE_1_SUBNET} via ${NODE_1_IP} dev tailscale0" \
  <<< "$NODE_0_ROUTES" \
  || die "node-0 route to node-1 Pod CIDR is missing."

grep -Fq \
  "${NODE_0_SUBNET} via ${NODE_0_IP} dev tailscale0" \
  <<< "$NODE_1_ROUTES" \
  || die "node-1 route to node-0 Pod CIDR is missing."

# ------------------------------------------------------------
# Generate representative IP inside each Pod subnet
# ------------------------------------------------------------

NODE_0_TEST_IP="$(
  python3 - <<PY
import ipaddress
net = ipaddress.ip_network("${NODE_0_SUBNET}")
print(net.network_address + 10)
PY
)"

NODE_1_TEST_IP="$(
  python3 - <<PY
import ipaddress
net = ipaddress.ip_network("${NODE_1_SUBNET}")
print(net.network_address + 10)
PY
)"

echo
echo "node-0 test Pod IP: $NODE_0_TEST_IP"
echo "node-1 test Pod IP: $NODE_1_TEST_IP"

# ------------------------------------------------------------
# Verify kernel routing decisions
# ------------------------------------------------------------

log "Checking route decisions"

echo
echo "server -> node-0 Pod network"

tailscale ssh "${SSH_USER}@${SERVER_HOST}" \
  "ip route get '${NODE_0_TEST_IP}'"

echo
echo "server -> node-1 Pod network"

tailscale ssh "${SSH_USER}@${SERVER_HOST}" \
  "ip route get '${NODE_1_TEST_IP}'"

echo
echo "node-0 -> node-1 Pod network"

tailscale ssh "${SSH_USER}@${NODE_0_HOST}" \
  "ip route get '${NODE_1_TEST_IP}'"

echo
echo "node-1 -> node-0 Pod network"

tailscale ssh "${SSH_USER}@${NODE_1_HOST}" \
  "ip route get '${NODE_0_TEST_IP}'"

# ------------------------------------------------------------
# Verify forwarding
# ------------------------------------------------------------

log "Checking forwarding"

for host in \
  "$NODE_0_HOST" \
  "$NODE_1_HOST"
do

  value="$(
    tailscale ssh "${SSH_USER}@${host}" \
      "sysctl -n net.ipv4.ip_forward"
  )"

  echo "$host: net.ipv4.ip_forward=$value"

  [ "$value" = "1" ] \
    || die "IPv4 forwarding is disabled on $host"

done

# ------------------------------------------------------------
# Check local worker Pod subnet routes
#
# CNI bridge should own each node's own Pod CIDR.
# ------------------------------------------------------------

log "Checking local Pod network routes"

echo
echo "[node-0 own Pod CIDR]"

tailscale ssh "${SSH_USER}@${NODE_0_HOST}" \
  "ip route show '${NODE_0_SUBNET}' || true"

echo
echo "[node-1 own Pod CIDR]"

tailscale ssh "${SSH_USER}@${NODE_1_HOST}" \
  "ip route show '${NODE_1_SUBNET}' || true"

# ------------------------------------------------------------
# Final output
# ------------------------------------------------------------

log "Pod network routing completed"

echo
echo "server:"
echo "  ${NODE_0_SUBNET} -> ${NODE_0_IP} dev tailscale0 onlink"
echo "  ${NODE_1_SUBNET} -> ${NODE_1_IP} dev tailscale0 onlink"

echo
echo "node-0:"
echo "  ${NODE_1_SUBNET} -> ${NODE_1_IP} dev tailscale0 onlink"

echo
echo "node-1:"
echo "  ${NODE_0_SUBNET} -> ${NODE_0_IP} dev tailscale0 onlink"

echo
echo "Step 11 completed."