# Cluster

The Talos Kubernetes cluster. [guests](../guests/README.md) builds the VMs and
stops, leaving the nodes in maintenance mode.

It stops at a cluster that runs pods and can route, with nothing stateful in
it; [platform](../platform/README.md) adds what a workload assumes exists.

How the cluster is run, upgraded and restored:
[Talos / Kubernetes](../docs/src/platform/talos.md),
[Maintenance](../docs/src/maintenance.md#talos).

## Running

```sh
mise run cluster plan
mise run cluster apply
```

Arguments are forwarded to `tofu`. `init` runs automatically on first use.

## Credentials

Read out of the ansible vault by `scripts/tofu.sh` and exported -- the same
three as the guests layer, for different reasons:

| Variable                           | Source                      | For                         |
|------------------------------------|-----------------------------|-----------------------------|
| `PROXMOX_VE_API_TOKEN`             | `secrets/proxmox-token.yml` | finding the nodes by tag    |
| `UNIFI_API_KEY`                    | `secrets/vault.yml`         | the VIP's DNS record        |
| `TF_VAR_terraform_state_passphrase`| `secrets/vault.yml`         | this layer's encrypted state |
| `TF_VAR_lab_domain`                | `secrets/vault.yml`         | every name here             |

> [!NOTE]
> the terraform state is committed and encrypted.

## Nodes

**Discovered, not listed.** The guests layer tags each Talos VM, and this layer
asks Proxmox which VMs carry those tags:

| Tag                  | Means                    |
|----------------------|--------------------------|
| `talos`              | a member of this cluster |
| `talos-controlplane` | control plane            |
| `talos-worker`       | worker                   |

The data source returns names and ids but **no addresses**, so both things this
layer needs are derived from what it does return:

- the **endpoint** is the guest's own DNS record, `<name>.<lab_domain>`,
  written by the guests layer in the same file as the guest
- the **address** comes from the vm id, which encodes it: guests numbers a
  Talos VM `<third octet><host octet>`, so `4010` is `10.212.4.10`

## What it builds

|                 |                                                            |
|-----------------|----------------------------------------------------------- |
| cluster name    | `lab` -- same as the Proxmox cluster                       |
| endpoint        | `https://k8s.<lab_domain>:6443` -> the VIP at `10.212.4.5` |
| Talos           | `talos_version` in `cluster_nodes.tf`                      |
| Kubernetes      | `kubernetes_version` in `cluster_nodes.tf`                 |
| pods / services | `10.244.0.0/16` / `10.96.0.0/12`                           |
| CNI             | Cilium (`cilium_version` in `cluster_cilium.tf`), kube-proxy replaced |
| Gateway API     | CRDs (`gateway_api_version` in `cluster_gateway_api.tf`, standard), `GatewayClass/cilium` |
| `LoadBalancer`  | `10.212.4.201-.254`, Cilium LB-IPAM + L2 announcements     |
| ingress address | `10.212.4.200`, a pool of one bound to the Gateway         |

`secrets/talosconfig` and `secrets/kubeconfig` are written at 0600 and
gitignored:

```sh
talosctl --talosconfig secrets/talosconfig -n talos-cp-1.<lab_domain> health
KUBECONFIG=secrets/kubeconfig kubectl get nodes
```

Nothing is merged into `~/.kube/config` on purpose.

## Upgrading

Talos and Kubernetes upgrades are **not** a `tofu apply`: `talosctl` first,
then bump the versions here and in the guests layer and apply both. Steps:
[Maintenance](../docs/src/maintenance.md#talos) (`--preserve` is mandatory on
one control plane).

Once there are three control planes, the better upgrade is to roll nodes one at
a time from a new image instead -- immutably, through the guests layer. That is
not available with one node, because it destroys the cluster.

## Known trade-offs

- **The extension list is stated twice**, here and in the guests layer. The
  image a node boots and the installer it upgrades onto must carry the same
  extensions or an upgrade silently drops them. Duplicated as a readable list
  rather than a copied hash, so a mismatch is visible; both layers output
  `talos_schematic_id` for comparison.
- **`kubectl_manifest`, not `kubernetes_manifest`,** for the two Cilium CRs.
  `kubernetes_manifest` does API discovery at plan time and so cannot plan a
  custom resource whose CRD does not exist -- which on a first apply is every
  Cilium CRD.
- **Gateway API is pinned twice, by two different things.** Its version is
  not chosen here: Cilium's minor dictates the minimum. Bumping either means
  checking the other. Upstream's `safe-upgrades` admission policy is installed
  alongside and refuses a downgrade below v1.5 -- delete it first if one is
  ever intended
- **`.200` is stated four times.** The `ingress` pool here, the wildcard DNS
  record in [network](../network/README.md), the address plan in
  [Networking](../docs/src/networking.md#vlans), and
  [platform](../platform/README.md), which notes it does not request one.
  Nothing catches a missed edit; the symptom of one is a hostname that resolves
  to an address nothing answers on.
- **The `ingress` pool names a Gateway this layer does not own.** Its
  `serviceSelector` matches `cilium-gateway-lab` in namespace `gateway`, both
  of which are written in [platform](../platform/README.md)
  (`platform_gateway.tf`). Rename the Gateway there and the
  reservation stops matching -- visible as a Gateway that never gets an
  address, and not as anything mentioning a pool.
