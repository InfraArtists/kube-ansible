#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="kubernetes-the-hard-way"

# GitHub-hosted Ubuntu runners normally use the "runner" account.
# Override if your Tailscale SSH policy maps to another user.
SSH_USER="root"

SERVER_HOST="server"
NODE_0_HOST="node-0"
NODE_1_HOST="node-1"


# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

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
# SSH configuration
#
# These options intentionally disable the interactive:
#
#   Are you sure you want to continue connecting (yes/no)?
#
# prompt.
#
# This is appropriate for disposable CI runners.
# ------------------------------------------------------------

SSH_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ConnectTimeout=10
  -o ServerAliveInterval=10
  -o ServerAliveCountMax=3
)

SCP_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -o ConnectTimeout=10
)


# ------------------------------------------------------------
# Required commands
# ------------------------------------------------------------

log "Checking required commands"

for command in \
  ssh \
  scp \
  tailscale \
  awk \
  sed \
  grep \
  getent
do
  command -v "$command" >/dev/null 2>&1 \
    || die "Required command not found: $command"
done


# ------------------------------------------------------------
# Enter the previously cloned repository
# ------------------------------------------------------------

if [ ! -d "$REPO_DIR" ]; then
  die "$REPO_DIR does not exist. Run the jumpbox setup first."
fi

cd "$REPO_DIR"

log "Using repository"

pwd


# ------------------------------------------------------------
# Wait until MagicDNS nodes are reachable over Tailscale
# ------------------------------------------------------------

wait_for_tailnet_host() {
  local host="$1"

  echo "Waiting for Tailscale node: $host"

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
# Verify SSH connectivity
# ------------------------------------------------------------

test_ssh() {
  local host="$1"

  echo "Testing SSH to $host..."

  for attempt in {1..60}; do

    if ssh \
      "${SSH_OPTS[@]}" \
      "${SSH_USER}@${host}" \
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
# Discover Tailscale IPv4 addresses through SSH
#
# MagicDNS names are used for management.
# The discovered IP addresses are stored in machines.txt.
# ------------------------------------------------------------

get_tailscale_ip() {
  local host="$1"

  ssh \
    "${SSH_OPTS[@]}" \
    "${SSH_USER}@${host}" \
    "tailscale ip -4 | head -n1"
}


log "Discovering Tailscale IP addresses"

SERVER_IP="$(get_tailscale_ip "$SERVER_HOST")"
NODE_0_IP="$(get_tailscale_ip "$NODE_0_HOST")"
NODE_1_IP="$(get_tailscale_ip "$NODE_1_HOST")"

[ -n "$SERVER_IP" ] || die "Could not determine server Tailscale IP."
[ -n "$NODE_0_IP" ] || die "Could not determine node-0 Tailscale IP."
[ -n "$NODE_1_IP" ] || die "Could not determine node-1 Tailscale IP."

echo "server : $SERVER_IP"
echo "node-0 : $NODE_0_IP"
echo "node-1 : $NODE_1_IP"


# ------------------------------------------------------------
# Create machines.txt
#
# Upstream schema:
#
# IPV4_ADDRESS FQDN HOSTNAME POD_SUBNET
#
# The server does not require a POD_SUBNET.
# ------------------------------------------------------------

log "Creating machines.txt"

cat > machines.txt <<EOF
${SERVER_IP} server.kubernetes.local server
${NODE_0_IP} node-0.kubernetes.local node-0 10.200.0.0/24
${NODE_1_IP} node-1.kubernetes.local node-1 10.200.1.0/24
EOF

cat machines.txt


# ------------------------------------------------------------
# Configure hostnames
#
# Management connections still use the Tailscale MagicDNS
# names server/node-0/node-1.
# ------------------------------------------------------------

log "Configuring machine hostnames"

while read -r IP FQDN HOST SUBNET; do

  echo
  echo "Configuring:"
  echo "  MagicDNS: $HOST"
  echo "  IP:       $IP"
  echo "  FQDN:     $FQDN"

  ssh \
    "${SSH_OPTS[@]}" \
    "${SSH_USER}@${HOST}" \
    "sudo bash -s" <<EOF
set -euo pipefail

if grep -q '^127\.0\.1\.1' /etc/hosts; then
  sed -i \
    's/^127\.0\.1\.1.*/127.0.1.1\t${FQDN} ${HOST}/' \
    /etc/hosts
else
  echo -e '127.0.1.1\t${FQDN} ${HOST}' >> /etc/hosts
fi

hostnamectl set-hostname "${HOST}"

systemctl restart systemd-hostnamed
EOF

done < machines.txt


# ------------------------------------------------------------
# Verify remote hostnames
# ------------------------------------------------------------

log "Verifying hostnames"

while read -r IP FQDN HOST SUBNET; do

  echo
  echo "$HOST:"

  ssh \
    "${SSH_OPTS[@]}" \
    "${SSH_USER}@${HOST}" \
    "hostname && hostname --fqdn"

done < machines.txt


# ------------------------------------------------------------
# Generate hosts file
# ------------------------------------------------------------

log "Generating Kubernetes hosts file"

cat > hosts <<'EOF'

# Kubernetes The Hard Way
EOF

while read -r IP FQDN HOST SUBNET; do
  echo "${IP} ${FQDN} ${HOST}" >> hosts
done < machines.txt

echo
cat hosts


# ------------------------------------------------------------
# Update jumpbox /etc/hosts
#
# Remove the previous managed block first so this script can
# safely be executed multiple times.
# ------------------------------------------------------------

log "Updating jumpbox /etc/hosts"

sudo sed -i \
  '/# Kubernetes The Hard Way/,/# End Kubernetes The Hard Way/d' \
  /etc/hosts

{
  echo
  echo "# Kubernetes The Hard Way"

  while read -r IP FQDN HOST SUBNET; do
    echo "${IP} ${FQDN} ${HOST}"
  done < machines.txt

  echo "# End Kubernetes The Hard Way"

} | sudo tee -a /etc/hosts >/dev/null


# ------------------------------------------------------------
# Verify local name resolution
# ------------------------------------------------------------

log "Checking jumpbox hostname resolution"

for host in \
  server \
  node-0 \
  node-1
do
  echo
  echo "$host:"
  getent hosts "$host"
done


# ------------------------------------------------------------
# Copy hosts file to remote machines
# ------------------------------------------------------------

log "Distributing hosts file"

while read -r IP FQDN HOST SUBNET; do

  echo "Copying host table to $HOST..."

  scp \
    "${SCP_OPTS[@]}" \
    hosts \
    "${SSH_USER}@${HOST}:/tmp/kubernetes-hosts"

done < machines.txt


# ------------------------------------------------------------
# Install host entries on remote machines
# ------------------------------------------------------------

log "Updating remote /etc/hosts files"

while read -r IP FQDN HOST SUBNET; do

  echo "Updating /etc/hosts on $HOST..."

  ssh \
    "${SSH_OPTS[@]}" \
    "${SSH_USER}@${HOST}" \
    "sudo bash -s" <<'EOF'
set -euo pipefail

sed -i \
  '/# Kubernetes The Hard Way/,/# End Kubernetes The Hard Way/d' \
  /etc/hosts

{
  echo
  echo "# Kubernetes The Hard Way"

  sed \
    '/^$/d; /^# Kubernetes The Hard Way$/d' \
    /tmp/kubernetes-hosts

  echo "# End Kubernetes The Hard Way"

} >> /etc/hosts

rm -f /tmp/kubernetes-hosts
EOF

done < machines.txt


# ------------------------------------------------------------
# Verify SSH using Kubernetes hostnames
#
# These now resolve from /etc/hosts as well as Tailscale.
# ------------------------------------------------------------

log "Verifying SSH using hostnames"

for host in \
  server \
  node-0 \
  node-1
do

  echo
  echo "SSH -> $host"

  ssh \
    "${SSH_OPTS[@]}" \
    "${SSH_USER}@${host}" \
    "hostname"

done


# ------------------------------------------------------------
# Verify cross-node resolution
# ------------------------------------------------------------

log "Verifying cross-node hostname resolution"

while read -r IP FQDN HOST SUBNET; do

  echo
  echo "Resolution from $HOST:"

  ssh \
    "${SSH_OPTS[@]}" \
    "${SSH_USER}@${HOST}" \
    "
      set -euo pipefail

      echo 'server:'
      getent hosts server

      echo 'node-0:'
      getent hosts node-0

      echo 'node-1:'
      getent hosts node-1
    "

done < machines.txt


# ------------------------------------------------------------
# Verify machines.txt against remote Tailscale addresses
# ------------------------------------------------------------

log "Validating machines.txt"

while read -r IP FQDN HOST SUBNET; do

  CURRENT_IP="$(
    ssh \
      "${SSH_OPTS[@]}" \
      "${SSH_USER}@${HOST}" \
      "tailscale ip -4 | head -n1"
  )"

  if [ "$CURRENT_IP" != "$IP" ]; then
    echo "IP mismatch for $HOST"
    echo "machines.txt: $IP"
    echo "Tailscale:    $CURRENT_IP"
    exit 1
  fi

  echo "$HOST -> $CURRENT_IP OK"

done < machines.txt


# ------------------------------------------------------------
# Final output
# ------------------------------------------------------------

log "Compute-resource configuration completed"

echo
echo "machines.txt"
echo "------------------------------------------------------------"
cat machines.txt

echo
echo "hosts"
echo "------------------------------------------------------------"
cat hosts

echo
echo "Cluster machines"
echo "------------------------------------------------------------"
printf '%-10s %-16s %-30s %-20s\n' \
  "HOST" \
  "TAILSCALE IP" \
  "FQDN" \
  "POD SUBNET"

while read -r IP FQDN HOST SUBNET; do

  printf '%-10s %-16s %-30s %-20s\n' \
    "$HOST" \
    "$IP" \
    "$FQDN" \
    "${SUBNET:-N/A}"

done < machines.txt

echo
echo "Compute resources are ready."