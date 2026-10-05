#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="kubernetes-the-hard-way"
SSH_USER="root"

SERVER_HOST="server"
WORKERS=(
  "node-0"
  "node-1"
)

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
# Enter repository
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

log "Checking required local files"

required_files=(
  machines.txt

  downloads/client/kubectl

  downloads/worker/crictl
  downloads/worker/kube-proxy
  downloads/worker/kubelet
  downloads/worker/runc
  downloads/worker/containerd
  downloads/worker/containerd-shim-runc-v2
  downloads/worker/containerd-stress

  configs/10-bridge.conf
  configs/99-loopback.conf
  configs/containerd-config.toml
  configs/kube-proxy-config.yaml

  units/containerd.service
  units/kubelet.service
  units/kube-proxy.service
)

for file in "${required_files[@]}"; do
  [ -f "$file" ] || die "Missing required file: $file"
done

if [ ! -d downloads/cni-plugins ]; then
  die "downloads/cni-plugins directory not found."
fi

echo "Required local files are present."


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

    echo "$host is not reachable yet. ($attempt/60)"
    sleep 2
  done

  die "Timed out waiting for $host"
}


log "Waiting for Kubernetes machines"

wait_for_host "$SERVER_HOST"

for host in "${WORKERS[@]}"; do
  wait_for_host "$host"
done


# ------------------------------------------------------------
# Verify Tailscale SSH
# ------------------------------------------------------------

test_ssh() {
  local host="$1"

  echo "Testing Tailscale SSH to $host..."

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

    echo "SSH to $host is not ready yet. ($attempt/60)"
    sleep 2
  done

  die "Unable to SSH to $host"
}


log "Checking Tailscale SSH"

test_ssh "$SERVER_HOST"

for host in "${WORKERS[@]}"; do
  test_ssh "$host"
done


# ------------------------------------------------------------
# Verify previous-step files on worker nodes
#
# Step 04/05 should already have installed:
#
# /var/lib/kubelet/ca.crt
# /var/lib/kubelet/kubelet.crt
# /var/lib/kubelet/kubelet.key
# /var/lib/kubelet/kubeconfig
# /var/lib/kube-proxy/kubeconfig
# ------------------------------------------------------------

log "Checking worker certificates and kubeconfigs"

for host in "${WORKERS[@]}"; do

  echo "Checking $host..."

  tailscale ssh "${SSH_USER}@${host}" '
    set -euo pipefail

    required_files=(
      /var/lib/kubelet/ca.crt
      /var/lib/kubelet/kubelet.crt
      /var/lib/kubelet/kubelet.key
      /var/lib/kubelet/kubeconfig
      /var/lib/kube-proxy/kubeconfig
    )

    for file in "${required_files[@]}"; do
      if [ ! -f "$file" ]; then
        echo "ERROR: Missing required file: $file" >&2
        exit 1
      fi
    done
  '

done


# ------------------------------------------------------------
# Generate worker-specific configuration files
#
# Upstream:
#
# SUBNET=$(grep ${HOST} machines.txt | cut -d " " -f 4)
#
# sed "s|SUBNET|$SUBNET|g" ...
# ------------------------------------------------------------

log "Generating worker-specific configuration"

rm -rf .worker-configs
mkdir -p .worker-configs

for host in "${WORKERS[@]}"; do

  subnet="$(
    awk -v host="$host" \
      '$3 == host { print $4 }' \
      machines.txt
  )"

  [ -n "$subnet" ] \
    || die "No pod subnet found for $host in machines.txt"

  echo "$host pod subnet: $subnet"

  mkdir -p ".worker-configs/$host"

  sed "s|SUBNET|${subnet}|g" \
    configs/10-bridge.conf \
    > ".worker-configs/${host}/10-bridge.conf"

  sed "s|SUBNET|${subnet}|g" \
    configs/kubelet-config.yaml \
    > ".worker-configs/${host}/kubelet-config.yaml"

done


# ------------------------------------------------------------
# Copy worker files
#
# Instead of scp, use tar over Tailscale SSH.
# ------------------------------------------------------------

log "Copying worker files"

for host in "${WORKERS[@]}"; do

  echo "Copying files to $host..."

  staging_dir=".worker-stage-${host}"

  rm -rf "$staging_dir"

  mkdir -p \
    "$staging_dir/cni-plugins"

  cp ".worker-configs/${host}/10-bridge.conf" \
    "$staging_dir/10-bridge.conf"

  cp ".worker-configs/${host}/kubelet-config.yaml" \
    "$staging_dir/kubelet-config.yaml"

  cp configs/99-loopback.conf \
    "$staging_dir/99-loopback.conf"

  cp configs/containerd-config.toml \
    "$staging_dir/containerd-config.toml"

  cp configs/kube-proxy-config.yaml \
    "$staging_dir/kube-proxy-config.yaml"

  cp units/containerd.service \
    "$staging_dir/containerd.service"

  cp units/kubelet.service \
    "$staging_dir/kubelet.service"

  cp units/kube-proxy.service \
    "$staging_dir/kube-proxy.service"

  cp downloads/client/kubectl \
    "$staging_dir/kubectl"

  cp downloads/worker/crictl \
    "$staging_dir/crictl"

  cp downloads/worker/kube-proxy \
    "$staging_dir/kube-proxy"

  cp downloads/worker/kubelet \
    "$staging_dir/kubelet"

  cp downloads/worker/runc \
    "$staging_dir/runc"

  cp downloads/worker/containerd \
    "$staging_dir/containerd"

  cp downloads/worker/containerd-shim-runc-v2 \
    "$staging_dir/containerd-shim-runc-v2"

  cp downloads/worker/containerd-stress \
    "$staging_dir/containerd-stress"

  cp downloads/cni-plugins/* \
    "$staging_dir/cni-plugins/"

  tar -C "$staging_dir" -cf - . |
  tailscale ssh "${SSH_USER}@${host}" '
    set -euo pipefail

    rm -rf /root/kthw-worker
    mkdir -p /root/kthw-worker

    tar -xf - -C /root/kthw-worker
  '

  rm -rf "$staging_dir"

done


# ------------------------------------------------------------
# Provision workers
# ------------------------------------------------------------

log "Provisioning Kubernetes workers"

for host in "${WORKERS[@]}"; do

  echo
  echo "Provisioning $host..."

  tailscale ssh "${SSH_USER}@${host}" '
    set -euo pipefail

    cd /root/kthw-worker


    # --------------------------------------------------------
    # Install OS dependencies
    # --------------------------------------------------------

    apt-get update

    DEBIAN_FRONTEND=noninteractive \
    apt-get install -y \
      socat \
      conntrack \
      ipset \
      kmod


    # --------------------------------------------------------
    # Disable swap
    # --------------------------------------------------------

    swapoff -a

    echo "Current swap configuration:"
    swapon --show || true


    # --------------------------------------------------------
    # Create installation directories
    # --------------------------------------------------------

    mkdir -p \
      /etc/cni/net.d \
      /opt/cni/bin \
      /var/lib/kubelet \
      /var/lib/kube-proxy \
      /var/lib/kubernetes \
      /var/run/kubernetes


    # --------------------------------------------------------
    # Install worker binaries
    # --------------------------------------------------------

    install -m 0755 \
      crictl \
      kube-proxy \
      kubelet \
      runc \
      kubectl \
      /usr/local/bin/

    install -m 0755 \
      containerd \
      containerd-shim-runc-v2 \
      containerd-stress \
      /bin/

    cp cni-plugins/* \
      /opt/cni/bin/

    chmod 0755 /opt/cni/bin/*


    # --------------------------------------------------------
    # Configure CNI networking
    # --------------------------------------------------------

    mv \
      10-bridge.conf \
      99-loopback.conf \
      /etc/cni/net.d/


    # --------------------------------------------------------
    # Enable bridge netfilter
    # --------------------------------------------------------

    modprobe br-netfilter

    printf "%s\n" \
      "br-netfilter" \
      > /etc/modules-load.d/kubernetes.conf

    cat > /etc/sysctl.d/kubernetes.conf <<EOF
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

    sysctl -p /etc/sysctl.d/kubernetes.conf


    # --------------------------------------------------------
    # Configure containerd
    # --------------------------------------------------------

    mkdir -p /etc/containerd

    mv \
      containerd-config.toml \
      /etc/containerd/config.toml

    mv \
      containerd.service \
      /etc/systemd/system/containerd.service


    # --------------------------------------------------------
    # Configure kubelet
    # --------------------------------------------------------

    mv \
      kubelet-config.yaml \
      /var/lib/kubelet/kubelet-config.yaml

    mv \
      kubelet.service \
      /etc/systemd/system/kubelet.service


    # --------------------------------------------------------
    # Configure kube-proxy
    # --------------------------------------------------------

    mv \
      kube-proxy-config.yaml \
      /var/lib/kube-proxy/kube-proxy-config.yaml

    mv \
      kube-proxy.service \
      /etc/systemd/system/kube-proxy.service


    # --------------------------------------------------------
    # Start worker services
    # --------------------------------------------------------

    systemctl daemon-reload

    systemctl enable \
      containerd \
      kubelet \
      kube-proxy

    systemctl restart \
      containerd \
      kubelet \
      kube-proxy
  '

done


# ------------------------------------------------------------
# Wait for services
# ------------------------------------------------------------

log "Waiting for worker services"

services=(
  containerd
  kubelet
  kube-proxy
)

for host in "${WORKERS[@]}"; do

  echo
  echo "Worker: $host"

  for service in "${services[@]}"; do

    echo "Waiting for $service..."

    for attempt in {1..60}; do

      status="$(
        tailscale ssh \
          "${SSH_USER}@${host}" \
          "systemctl is-active ${service} 2>/dev/null || true"
      )"

      if [ "$status" = "active" ]; then
        echo "$service is active."
        break
      fi

      if [ "$attempt" -eq 60 ]; then

        echo "$service failed on $host."

        tailscale ssh "${SSH_USER}@${host}" "
          systemctl status ${service} \
            --no-pager \
            --full || true

          journalctl \
            -u ${service} \
            --no-pager \
            -n 150 || true
        "

        exit 1
      fi

      echo "$service is not ready yet. ($attempt/60)"
      sleep 2

    done

  done

done


# ------------------------------------------------------------
# Verify containerd
# ------------------------------------------------------------

log "Checking containerd"

for host in "${WORKERS[@]}"; do

  echo
  echo "[$host]"

  tailscale ssh "${SSH_USER}@${host}" '
    set -euo pipefail

    crictl \
      --runtime-endpoint unix:///run/containerd/containerd.sock \
      info >/dev/null

    echo "containerd OK"
  '

done


# ------------------------------------------------------------
# Verify CNI configuration
# ------------------------------------------------------------

log "Checking CNI configuration"

for host in "${WORKERS[@]}"; do

  echo
  echo "[$host]"

  tailscale ssh "${SSH_USER}@${host}" '
    set -euo pipefail

    echo "CNI configs:"
    ls -l /etc/cni/net.d/

    echo
    echo "Bridge config:"
    cat /etc/cni/net.d/10-bridge.conf
  '

done


# ------------------------------------------------------------
# Verify kubelet API endpoint configuration
#
# This should point at server.kubernetes.local, which step 03
# mapped to the server Tailscale IP.
# ------------------------------------------------------------

log "Checking worker API endpoint configuration"

for host in "${WORKERS[@]}"; do

  echo
  echo "[$host]"

  tailscale ssh "${SSH_USER}@${host}" '
    grep -n "server:" \
      /var/lib/kubelet/kubeconfig
  '

done


# ------------------------------------------------------------
# Wait for nodes to register
# ------------------------------------------------------------

log "Waiting for Kubernetes nodes to register"

for attempt in {1..90}; do

  node_count="$(
    tailscale ssh "${SSH_USER}@${SERVER_HOST}" \
      "kubectl get nodes \
        --kubeconfig /root/admin.kubeconfig \
        --no-headers 2>/dev/null |
       wc -l"
  )"

  if [ "$node_count" -ge 2 ]; then
    echo "Both worker nodes have registered."
    break
  fi

  if [ "$attempt" -eq 90 ]; then

    echo "Timed out waiting for Kubernetes workers."

    echo
    echo "Server:"
    tailscale ssh "${SSH_USER}@${SERVER_HOST}" \
      "kubectl get nodes \
        -o wide \
        --kubeconfig /root/admin.kubeconfig || true"

    for host in "${WORKERS[@]}"; do

      echo
      echo "Kubelet logs on $host:"

      tailscale ssh "${SSH_USER}@${host}" \
        "journalctl \
          -u kubelet \
          --no-pager \
          -n 150 || true"

    done

    exit 1
  fi

  echo "Registered nodes: $node_count/2 ($attempt/90)"
  sleep 2

done


# ------------------------------------------------------------
# Wait until both nodes become Ready
# ------------------------------------------------------------

log "Waiting for workers to become Ready"

for attempt in {1..90}; do

  ready_nodes="$(
    tailscale ssh "${SSH_USER}@${SERVER_HOST}" \
      "kubectl get nodes \
        --kubeconfig /root/admin.kubeconfig \
        --no-headers 2>/dev/null |
       awk '\$2 == \"Ready\" {count++} END {print count+0}'"
  )"

  if [ "$ready_nodes" -eq 2 ]; then
    echo "Both worker nodes are Ready."
    break
  fi

  if [ "$attempt" -eq 90 ]; then

    echo "Workers did not become Ready."

    tailscale ssh "${SSH_USER}@${SERVER_HOST}" \
      "kubectl get nodes \
        -o wide \
        --kubeconfig /root/admin.kubeconfig"

    for host in "${WORKERS[@]}"; do

      echo
      echo "[$host kubelet]"

      tailscale ssh "${SSH_USER}@${host}" \
        "journalctl \
          -u kubelet \
          --no-pager \
          -n 150 || true"

    done

    exit 1
  fi

  echo "Ready workers: $ready_nodes/2 ($attempt/90)"
  sleep 2

done


# ------------------------------------------------------------
# Final verification
# ------------------------------------------------------------

log "Kubernetes workers"

tailscale ssh "${SSH_USER}@${SERVER_HOST}" \
  "kubectl get nodes \
    -o wide \
    --kubeconfig /root/admin.kubeconfig"


# ------------------------------------------------------------
# Worker service summary
# ------------------------------------------------------------

log "Worker service summary"

for host in "${WORKERS[@]}"; do

  echo
  echo "[$host]"

  tailscale ssh "${SSH_USER}@${host}" '
    for service in \
      containerd \
      kubelet \
      kube-proxy
    do
      printf "%-12s " "$service"
      systemctl is-active "$service"
    done
  '

done


log "Kubernetes worker bootstrap completed"

echo
echo "Workers:"
echo "  node-0"
echo "  node-1"
echo
echo "Expected Kubernetes status:"
echo "  node-0   Ready"
echo "  node-1   Ready"