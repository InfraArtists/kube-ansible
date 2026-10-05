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
# Check required commands
# ------------------------------------------------------------

log "Checking required commands"

for command in \
  tailscale \
  envsubst \
  base64 \
  head \
  grep
do
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

[ -f configs/encryption-config.yaml ] \
  || die "configs/encryption-config.yaml not found."

log "Working directory"

pwd


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
# Generate encryption key
#
# Upstream:
#
# export ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)
# ------------------------------------------------------------

log "Generating Kubernetes data-encryption key"

export ENCRYPTION_KEY="$(
  head -c 32 /dev/urandom |
  base64
)"

[ -n "$ENCRYPTION_KEY" ] \
  || die "Failed to generate ENCRYPTION_KEY"

echo "Encryption key generated."


# ------------------------------------------------------------
# Generate encryption-config.yaml
#
# Do not print the file because it contains the encryption key.
# ------------------------------------------------------------

log "Generating encryption-config.yaml"

envsubst \
  < configs/encryption-config.yaml \
  > encryption-config.yaml

[ -s encryption-config.yaml ] \
  || die "encryption-config.yaml was not generated."


# ------------------------------------------------------------
# Basic validation
# ------------------------------------------------------------

log "Validating encryption config"

if grep -q '\${ENCRYPTION_KEY}' encryption-config.yaml; then
  die "ENCRYPTION_KEY was not substituted."
fi

grep -q 'EncryptionConfiguration' encryption-config.yaml \
  || die "EncryptionConfiguration not found."

grep -q 'aescbc' encryption-config.yaml \
  || die "aescbc provider not found."

echo "Encryption configuration looks valid."


# ------------------------------------------------------------
# Copy encryption config to server
#
# Upstream uses:
#
# scp encryption-config.yaml root@server:~/
#
# Here we use Tailscale SSH and stdin.
# ------------------------------------------------------------

log "Copying encryption-config.yaml to server"

cat encryption-config.yaml |
tailscale ssh \
  "${SSH_USER}@${SERVER_HOST}" \
  "umask 077 && cat > /root/encryption-config.yaml"


# ------------------------------------------------------------
# Verify remote file
#
# Only verify metadata/content structure.
# Do not print the embedded secret.
# ------------------------------------------------------------

log "Verifying encryption config on server"

tailscale ssh \
  "${SSH_USER}@${SERVER_HOST}" \
  '
    set -euo pipefail

    test -s /root/encryption-config.yaml

    grep -q "EncryptionConfiguration" \
      /root/encryption-config.yaml

    grep -q "aescbc" \
      /root/encryption-config.yaml

    chmod 600 /root/encryption-config.yaml

    ls -l /root/encryption-config.yaml
  '


# ------------------------------------------------------------
# Final summary
# ------------------------------------------------------------

log "Data-encryption configuration completed"

echo
echo "Generated:"
echo "  encryption-config.yaml"

echo
echo "Copied to:"
echo "  root@server:/root/encryption-config.yaml"

echo
echo "The encryption key was intentionally not printed."