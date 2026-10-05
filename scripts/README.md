# Kubernetes The Hard Way on GitHub Actions

This project runs **Kubernetes The Hard Way on ephemeral GitHub Actions runners**.

Instead of maintaining permanent VMs, GitHub-hosted runners temporarily become the Kubernetes machines:

## Results

### Workflow

![](../assets/k8s-workflow/k8s-workflow2.png)

### Kublet service and nodes status

![](../assets/k8s-workflow/k8s-kubelet-and-get-nodes.png)

### Nginx pod logs

![](../assets/k8s-workflow/k8s-nginx-pod-logs-port-forward.png)

## Architecture

```text
GitHub Actions
│
├── jumpbox    → bootstrap / administration
├── server     → etcd + Kubernetes control plane
├── node-0     → Kubernetes worker
└── node-1     → Kubernetes worker
```

**Tailscale** connects these isolated runners to the same private network, providing private IPs, MagicDNS hostnames, and SSH connectivity.

The workflow then automates the main Kubernetes The Hard Way stages:

```text
Create runners
      ↓
Connect through Tailscale
      ↓
Generate certificates & kubeconfigs
      ↓
Bootstrap etcd
      ↓
Bootstrap control plane
      ↓
Bootstrap workers
      ↓
Configure Pod networking
      ↓
Verify cluster
```

Each workflow run therefore creates a **temporary multi-machine Kubernetes lab from scratch** and disposes of it when the jobs finish.

> This project is intended for learning, testing, and experimentation — not production Kubernetes deployments.

---

## Tailscale Setup

### 1. Create a Tailscale account

Create or sign in to your tailnet:

https://login.tailscale.com/admin

The GitHub Actions runners will join this tailnet during the workflow.

---

### 2. Create the `tag:ci` tag

Open:

**Tailscale Admin Console → Access controls**

Add a tag for CI runners:

```json
{
  "tagOwners": {
    "tag:ci": []
  }
}
```

For this lab, the CI machines also need to communicate with each other.

A simple permissive configuration is:

```json
{
  "tagOwners": {
    "tag:ci": []
  },

  "grants": [
    {
      "src": ["tag:ci"],
      "dst": ["*"],
      "ip": ["*"]
    }
  ]
}
```

This configuration is suitable for an isolated test/lab tailnet. Use more restrictive access rules for production environments.

---

### 3. Create an OAuth client

Open:

**Tailscale Admin Console → Settings → Trust credentials → OAuth clients**

Create a new OAuth client.

Give the client permission to create authentication keys/devices and allow it to use:

```text
tag:ci
```

After creating the OAuth client, Tailscale provides two values:

```text
Client ID:
xxxxxxxxxxxxxxxxxxxx

Client Secret:
tskey-client-xxxxxxxxxxxxxxxxxxxxxxxx
```

The value beginning with:

```text
tskey-client-
```

is the **OAuth Client Secret**.

---

### 4. Add the credentials to GitHub

Open your GitHub repository:

**Settings → Secrets and variables → Actions → New repository secret**

Create these two secrets:

```text
TS_OAUTH_CLIENT_ID
TS_OAUTH_SECRET
```

Their values should be:

```text
TS_OAUTH_CLIENT_ID=<Tailscale OAuth Client ID>

TS_OAUTH_SECRET=tskey-client-xxxxxxxxxxxxxxxx
```

Do **not** commit these credentials to the repository.

---

### 5. Connect a GitHub runner to Tailscale

Use the official Tailscale GitHub Action:

```yaml
- name: Connect to Tailscale
  uses: tailscale/github-action@v4
  with:
    oauth-client-id: ${{ secrets.TS_OAUTH_CLIENT_ID }}
    oauth-secret: ${{ secrets.TS_OAUTH_SECRET }}
    tags: tag:ci
    hostname: server
```

Each Kubernetes machine should use its own hostname:

```text
server
node-0
node-1
```

For example, a worker can join as:

```yaml
- name: Connect node-0 to Tailscale
  uses: tailscale/github-action@v4
  with:
    oauth-client-id: ${{ secrets.TS_OAUTH_CLIENT_ID }}
    oauth-secret: ${{ secrets.TS_OAUTH_SECRET }}
    tags: tag:ci
    hostname: node-0
```

Once connected, the machines can reach each other using Tailscale MagicDNS:

```bash
ping server
ping node-0
ping node-1
```

You can check the runner's Tailscale IP with:

```bash
tailscale ip -4
```

---

### 6. Enable SSH

On each runner that needs remote access:

```bash
sudo tailscale set --ssh
```

The machines can then be reached through Tailscale:

```bash
tailscale ssh root@server
tailscale ssh root@node-0
tailscale ssh root@node-1
```

Normal SSH can also be used over the Tailscale network when configured:

```bash
sudo ssh \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  root@node-0
```

The relaxed host-key checking is appropriate here because the runners are temporary and receive new identities on each workflow run.

---

## Kubernetes Networking

Tailscale connects the **machines**, while Kubernetes CNI manages the **Pod networks**.

The workers use separate Pod CIDRs:

```text
node-0 → 10.200.0.0/24
node-1 → 10.200.1.0/24
```

Tailscale IPs are discovered dynamically because GitHub runners are ephemeral:

```bash
SERVER_IP=$(tailscale ssh root@server "tailscale ip -4 | head -n1")
NODE_0_IP=$(tailscale ssh root@node-0 "tailscale ip -4 | head -n1")
NODE_1_IP=$(tailscale ssh root@node-1 "tailscale ip -4 | head -n1")
```

This information is used to generate the Kubernetes The Hard Way machine configuration:

```text
<TS_IP> server.kubernetes.local server
<TS_IP> node-0.kubernetes.local node-0 10.200.0.0/24
<TS_IP> node-1.kubernetes.local node-1 10.200.1.0/24
```

Pod routes are then configured across the Tailscale interface. For example:

```bash
ip route replace 10.200.1.0/24 \
  via "$NODE_1_IP" \
  dev tailscale0 \
  onlink
```

The result is a fully disposable Kubernetes lab where the machines themselves are GitHub Actions runners and Tailscale acts as their private network.

---

## References

- [Kubernetes The Hard Way](https://github.com/kelseyhightower/kubernetes-the-hard-way)
- [Tailscale GitHub Action](https://github.com/tailscale/github-action)
- [Tailscale OAuth Clients](https://tailscale.com/kb/1215/oauth-clients)