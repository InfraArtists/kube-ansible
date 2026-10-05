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
# Verify prerequisites
# ------------------------------------------------------------

log "Checking required commands"

for command in \
  openssl \
  tailscale \
  grep \
  awk \
  sed
do
  command -v "$command" >/dev/null 2>&1 \
    || die "Required command not found: $command"
done


# ------------------------------------------------------------
# Enter cloned repository
# ------------------------------------------------------------

if [ ! -d "$REPO_DIR" ]; then
  die "$REPO_DIR does not exist."
fi

cd "$REPO_DIR"

[ -f ca.conf ] || die "ca.conf not found in $(pwd)"

log "Working directory"

pwd


# ------------------------------------------------------------
# Wait for Tailscale nodes
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

    echo "$host not reachable yet. ($attempt/60)"
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

    echo "SSH to $host not ready yet. ($attempt/60)"
    sleep 2
  done

  die "Unable to SSH to $host"
}


log "Checking SSH connectivity"

test_ssh "$SERVER_HOST"
test_ssh "$NODE_0_HOST"
test_ssh "$NODE_1_HOST"


# ------------------------------------------------------------
# Clean old certificate artifacts
# ------------------------------------------------------------

log "Cleaning old certificate artifacts"

rm -f \
  ./*.crt \
  ./*.key \
  ./*.csr \
  ./ca.srl


# ------------------------------------------------------------
# Generate Certificate Authority
# ------------------------------------------------------------

log "Generating Kubernetes Certificate Authority"

openssl genrsa \
  -out ca.key \
  4096

openssl req \
  -x509 \
  -new \
  -sha512 \
  -noenc \
  -key ca.key \
  -days 3653 \
  -config ca.conf \
  -out ca.crt


# ------------------------------------------------------------
# Verify CA
# ------------------------------------------------------------

log "Verifying CA certificate"

openssl x509 \
  -in ca.crt \
  -noout \
  -subject \
  -issuer \
  -dates


# ------------------------------------------------------------
# Generate component certificates
# ------------------------------------------------------------

log "Generating Kubernetes client and server certificates"

certs=(
  "admin"
  "node-0"
  "node-1"
  "kube-proxy"
  "kube-scheduler"
  "kube-controller-manager"
  "kube-api-server"
  "service-accounts"
)

for cert in "${certs[@]}"; do

  echo
  echo "Generating certificate: $cert"

  openssl genrsa \
    -out "${cert}.key" \
    4096

  openssl req \
    -new \
    -key "${cert}.key" \
    -sha256 \
    -config ca.conf \
    -section "$cert" \
    -out "${cert}.csr"

  openssl x509 \
    -req \
    -days 3653 \
    -in "${cert}.csr" \
    -copy_extensions copyall \
    -sha256 \
    -CA ca.crt \
    -CAkey ca.key \
    -CAcreateserial \
    -out "${cert}.crt"

done


# ------------------------------------------------------------
# Verify generated certificates
# ------------------------------------------------------------

log "Generated certificate files"

ls -1 \
  ./*.crt \
  ./*.key \
  ./*.csr


# ------------------------------------------------------------
# Validate certificates against CA
# ------------------------------------------------------------

log "Validating certificates"

for cert in "${certs[@]}"; do

  echo "Checking ${cert}.crt"

  openssl verify \
    -CAfile ca.crt \
    "${cert}.crt"

done


# ------------------------------------------------------------
# Prepare node-0 kubelet directory
# ------------------------------------------------------------

log "Preparing node-0"

tailscale ssh \
  "${SSH_USER}@${NODE_0_HOST}" \
  "sudo mkdir -p /var/lib/kubelet"


# ------------------------------------------------------------
# Copy node-0 certificates
# ------------------------------------------------------------

log "Copying node-0 certificates"

cat ca.crt |
tailscale ssh \
  "${SSH_USER}@${NODE_0_HOST}" \
  "sudo tee /var/lib/kubelet/ca.crt >/dev/null"

cat node-0.crt |
tailscale ssh \
  "${SSH_USER}@${NODE_0_HOST}" \
  "sudo tee /var/lib/kubelet/kubelet.crt >/dev/null"

cat node-0.key |
tailscale ssh \
  "${SSH_USER}@${NODE_0_HOST}" \
  "sudo tee /var/lib/kubelet/kubelet.key >/dev/null"


# ------------------------------------------------------------
# Prepare node-1 kubelet directory
# ------------------------------------------------------------

log "Preparing node-1"

tailscale ssh \
  "${SSH_USER}@${NODE_1_HOST}" \
  "sudo mkdir -p /var/lib/kubelet"


# ------------------------------------------------------------
# Copy node-1 certificates
# ------------------------------------------------------------

log "Copying node-1 certificates"

cat ca.crt |
tailscale ssh \
  "${SSH_USER}@${NODE_1_HOST}" \
  "sudo tee /var/lib/kubelet/ca.crt >/dev/null"

cat node-1.crt |
tailscale ssh \
  "${SSH_USER}@${NODE_1_HOST}" \
  "sudo tee /var/lib/kubelet/kubelet.crt >/dev/null"

cat node-1.key |
tailscale ssh \
  "${SSH_USER}@${NODE_1_HOST}" \
  "sudo tee /var/lib/kubelet/kubelet.key >/dev/null"


# ------------------------------------------------------------
# Set worker certificate permissions
# ------------------------------------------------------------

log "Setting worker certificate permissions"

for host in \
  "$NODE_0_HOST" \
  "$NODE_1_HOST"
do

  tailscale ssh \
    "${SSH_USER}@${host}" \
    "
      sudo chmod 644 \
        /var/lib/kubelet/ca.crt \
        /var/lib/kubelet/kubelet.crt

      sudo chmod 600 \
        /var/lib/kubelet/kubelet.key
    "

done


# ------------------------------------------------------------
# Copy control-plane certificates to server
#
# The upstream tutorial copies these into root's home directory.
# Since we are logging in through a non-root Tailscale SSH account,
# use /tmp first and then move them into /root.
# ------------------------------------------------------------

log "Copying control-plane certificates to server"

for file in \
  ca.key \
  ca.crt \
  kube-api-server.key \
  kube-api-server.crt \
  service-accounts.key \
  service-accounts.crt
do

  echo "Copying $file"

  cat "$file" |
  tailscale ssh \
    "${SSH_USER}@${SERVER_HOST}" \
    "cat > /tmp/${file}"

done


# ------------------------------------------------------------
# Move server certificates into /root
# ------------------------------------------------------------

log "Installing certificates on server"

tailscale ssh \
  "${SSH_USER}@${SERVER_HOST}" \
  "
    set -euo pipefail

    sudo mv /tmp/ca.key /root/ca.key
    sudo mv /tmp/ca.crt /root/ca.crt

    sudo mv \
      /tmp/kube-api-server.key \
      /root/kube-api-server.key

    sudo mv \
      /tmp/kube-api-server.crt \
      /root/kube-api-server.crt

    sudo mv \
      /tmp/service-accounts.key \
      /root/service-accounts.key

    sudo mv \
      /tmp/service-accounts.crt \
      /root/service-accounts.crt

    sudo chmod 600 \
      /root/ca.key \
      /root/kube-api-server.key \
      /root/service-accounts.key

    sudo chmod 644 \
      /root/ca.crt \
      /root/kube-api-server.crt \
      /root/service-accounts.crt
  "


# ------------------------------------------------------------
# Verify node-0 certificate installation
# ------------------------------------------------------------

log "Verifying node-0 certificates"

tailscale ssh \
  "${SSH_USER}@${NODE_0_HOST}" \
  "
    sudo ls -l /var/lib/kubelet/

    sudo openssl x509 \
      -in /var/lib/kubelet/kubelet.crt \
      -noout \
      -subject
  "


# ------------------------------------------------------------
# Verify node-1 certificate installation
# ------------------------------------------------------------

log "Verifying node-1 certificates"

tailscale ssh \
  "${SSH_USER}@${NODE_1_HOST}" \
  "
    sudo ls -l /var/lib/kubelet/

    sudo openssl x509 \
      -in /var/lib/kubelet/kubelet.crt \
      -noout \
      -subject
  "


# ------------------------------------------------------------
# Verify server certificates
# ------------------------------------------------------------

log "Verifying server certificates"

tailscale ssh \
  "${SSH_USER}@${SERVER_HOST}" \
  "
    sudo ls -l \
      /root/ca.crt \
      /root/ca.key \
      /root/kube-api-server.crt \
      /root/kube-api-server.key \
      /root/service-accounts.crt \
      /root/service-accounts.key

    sudo openssl x509 \
      -in /root/kube-api-server.crt \
      -noout \
      -subject \
      -issuer
  "


# ------------------------------------------------------------
# Final local certificate summary
# ------------------------------------------------------------

log "Certificate summary"

for cert in \
  ca \
  admin \
  node-0 \
  node-1 \
  kube-proxy \
  kube-scheduler \
  kube-controller-manager \
  kube-api-server \
  service-accounts
do

  echo
  echo "[$cert]"

  openssl x509 \
    -in "${cert}.crt" \
    -noout \
    -subject \
    -issuer \
    2>/dev/null || true

done


log "Certificate authority step completed"

echo
echo "CA and component certificates have been generated."
echo "Worker certificates were installed on node-0 and node-1."
echo "Control-plane certificates were installed on server."