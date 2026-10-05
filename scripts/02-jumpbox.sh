#!/usr/bin/env bash

set -euo pipefail

REPO_URL="https://github.com/kelseyhightower/kubernetes-the-hard-way.git"
REPO_DIR="kubernetes-the-hard-way"

log() {
  echo
  echo "==> $*"
}

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: Run this script as root."
  exit 1
fi


# ------------------------------------------------------------
# Install required utilities
# ------------------------------------------------------------

log "Installing command-line utilities"

apt-get update

apt-get install -y \
  wget \
  curl \
  vim \
  openssl \
  git


# ------------------------------------------------------------
# Clone Kubernetes The Hard Way
# ------------------------------------------------------------

log "Cloning Kubernetes The Hard Way"

if [ ! -d "$REPO_DIR" ]; then
  git clone \
    --depth 1 \
    "$REPO_URL" \
    "$REPO_DIR"
else
  echo "$REPO_DIR already exists. Skipping clone."
fi

cd "$REPO_DIR"

echo "Working directory:"
pwd


# ------------------------------------------------------------
# Detect architecture
# ------------------------------------------------------------

ARCH="$(dpkg --print-architecture)"

log "Detected architecture: $ARCH"

DOWNLOAD_LIST="downloads-${ARCH}.txt"

if [ ! -f "$DOWNLOAD_LIST" ]; then
  echo "ERROR: Download list not found: $DOWNLOAD_LIST"
  exit 1
fi

echo "Download manifest:"
cat "$DOWNLOAD_LIST"


# ------------------------------------------------------------
# Download Kubernetes components
# ------------------------------------------------------------

log "Downloading Kubernetes binaries"

mkdir -p downloads

wget \
  --quiet \
  --show-progress \
  --https-only \
  --timestamping \
  --directory-prefix=downloads \
  --input-file="$DOWNLOAD_LIST"

log "Downloaded files"

ls -lh downloads


# ------------------------------------------------------------
# Create binary directories
# ------------------------------------------------------------

log "Creating binary directories"

mkdir -p \
  downloads/client \
  downloads/cni-plugins \
  downloads/controller \
  downloads/worker


# ------------------------------------------------------------
# Extract CRI tools
# ------------------------------------------------------------

log "Extracting crictl"

tar \
  -xvf "downloads/crictl-v1.32.0-linux-${ARCH}.tar.gz" \
  -C downloads/worker/


# ------------------------------------------------------------
# Extract containerd
# ------------------------------------------------------------

log "Extracting containerd"

tar \
  -xvf "downloads/containerd-2.1.0-beta.0-linux-${ARCH}.tar.gz" \
  --strip-components=1 \
  -C downloads/worker/


# ------------------------------------------------------------
# Extract CNI plugins
# ------------------------------------------------------------

log "Extracting CNI plugins"

tar \
  -xvf "downloads/cni-plugins-linux-${ARCH}-v1.6.2.tgz" \
  -C downloads/cni-plugins/


# ------------------------------------------------------------
# Extract etcd
# ------------------------------------------------------------

log "Extracting etcd"

ETCD_VERSION="v3.6.0-rc.3"
ETCD_DIR="etcd-${ETCD_VERSION}-linux-${ARCH}"

tar \
  -xvf "downloads/etcd-${ETCD_VERSION}-linux-${ARCH}.tar.gz" \
  -C downloads/ \
  --strip-components=1 \
  "${ETCD_DIR}/etcd" \
  "${ETCD_DIR}/etcdctl"


# ------------------------------------------------------------
# Organize binaries
# ------------------------------------------------------------

log "Organizing Kubernetes binaries"

mv \
  downloads/etcdctl \
  downloads/kubectl \
  downloads/client/

mv \
  downloads/etcd \
  downloads/kube-apiserver \
  downloads/kube-controller-manager \
  downloads/kube-scheduler \
  downloads/controller/

mv \
  downloads/kubelet \
  downloads/kube-proxy \
  downloads/worker/

mv \
  "downloads/runc.${ARCH}" \
  downloads/worker/runc


# ------------------------------------------------------------
# Remove archives
# ------------------------------------------------------------

log "Removing downloaded archives"

find downloads \
  -maxdepth 1 \
  -type f \
  \( -name "*.gz" -o -name "*.tgz" \) \
  -delete


# ------------------------------------------------------------
# Set executable permissions
# ------------------------------------------------------------

log "Making binaries executable"

chmod +x downloads/client/*
chmod +x downloads/cni-plugins/*
chmod +x downloads/controller/*
chmod +x downloads/worker/*


# ------------------------------------------------------------
# Install kubectl
# ------------------------------------------------------------

log "Installing kubectl"

cp downloads/client/kubectl /usr/local/bin/kubectl

chmod +x /usr/local/bin/kubectl


# ------------------------------------------------------------
# Verify kubectl
# ------------------------------------------------------------

log "Verifying kubectl"

kubectl version --client


# ------------------------------------------------------------
# Final verification
# ------------------------------------------------------------

log "Jumpbox setup completed"

echo
echo "Architecture: $ARCH"
echo "Repository:   $(pwd)"
echo
echo "Client binaries:"
ls -lh downloads/client/

echo
echo "Controller binaries:"
ls -lh downloads/controller/

echo
echo "Worker binaries:"
ls -lh downloads/worker/

echo
echo "CNI plugins:"
ls -lh downloads/cni-plugins/

echo
echo "Jumpbox is ready."