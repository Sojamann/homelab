# Talos / Kubernetes

## What it's for

The cluster every workload runs on. Talos Linux (immutable, API-only, no SSH)
on one VM, which is control plane and worker at once. Cilium is the CNI,
replaces kube-proxy, implements the Gateway API and hands out `LoadBalancer`
addresses.

## Access

- **Kubernetes API:** `https://k8s.<lab_domain>:6443`, the VIP `10.212.4.5`.
  From Trusted and the tailnet (admins).
  ```sh
  KUBECONFIG=secrets/kubeconfig kubectl get nodes
  ```
- **Talos API:** `:50000` on the node itself, not the VIP.
  ```sh
  talosctl --talosconfig secrets/talosconfig -n talos-cp-1.<lab_domain> health
  ```
- **Login:** both files are admin client certificates, written by `mise run
  cluster apply` (0600, gitignored, not merged into `~/.kube/config`). No SSO.
- **Break-glass:** the Talos API answers when Kubernetes and the VIP do not --
  it is how you fix a cluster whose endpoint is dead. Last resort: the VM 4010
  console in Proxmox (Talos dashboard). Lost both files: `mise run cluster
  apply` regenerates them from the tofu state.

## Where it runs

VM 4010 `talos-cp-1` on titan, `10.212.4.10`, VLAN 40, 4 cores, 16G, 40G disk
on `local`. Built by the guests layer (`guests/guest_vm_talos_cp_1.tf`),
configured by the cluster layer (`cluster/`).
Build: [Build guide: Cluster](../build/cluster/README.md).

| | |
|--|--|
| cluster name | `lab` |
| pods / services | `10.244.0.0/16` / `10.96.0.0/12` |
| `LoadBalancer` pool | `10.212.4.201-.254`, Cilium LB-IPAM + L2 announcements |
| ingress address | `10.212.4.200`, a pool of one selected onto `cilium-gateway-lab` in `gateway` |
| versions | `talos_version`, `kubernetes_version` in `cluster/cluster_nodes.tf`; `cilium_version` in `cluster/cluster_cilium.tf` |

## Data

- **etcd** -- every Kubernetes object, on the VM disk.
- **Machine secrets** (cluster CAs, tokens) -- `talos_machine_secrets` in the
  cluster layer's encrypted state, `prevent_destroy`. Lost = a new cluster.
- **Not state:** the node itself (image + machineconfig, regenerated), and
  the workloads' data -- PVCs live on the NAS. The node is throwaway by
  design: storage is on the NAS, apps are in git.

## Backup & restore

| Route | Covers |
|--|--|
| [PBS](../backups.md#pbs) | the whole VM, nightly |
| [etcd snapshots](../backups.md#etcd-snapshots) | etcd, by hand, before upgrades |
| [Secrets repo](../backups.md#secrets-repo) | machine secrets, in tofu state |
| apps repo + [VolSync](../backups.md#volsync) | everything else, rebuilt |

A VM restored from PBS rolls etcd back to 23:00 of that day -- see the
caveat in [Backups: PBS](../backups.md#pbs). A lost cluster:
[Recover from zero](../recover-from-zero.md).

**Rebuild without a backup** (VM gone, PBS unusable): the intent is to
rebuild the node, or create a new one, through the guests and cluster layers
with the machine secrets from `secrets/` --
[Build guide: Guests](../build/guests/README.md),
[Build guide: Cluster](../build/cluster/README.md), then
[Recover from zero](../recover-from-zero.md) for what lived in etcd.
Untested: `talos_machine_bootstrap` is in state too, so whether a plain `mise
run cluster apply` bootstraps etcd on a fresh disk is unknown.

**Verify.**

```sh
talosctl -n talos-cp-1.<lab_domain> health
kubectl get nodes -o wide
kubectl -n kube-system get pods -l k8s-app=cilium
flux get kustomizations
```

## Admin

**Nodes are discovered, not listed.** The cluster layer asks Proxmox for VMs
tagged `talos` + `talos-controlplane` / `talos-worker`, takes the endpoint
from the guest's DNS record and the address from its vm id (`4010` ->
`10.212.4.10`). A new node is a new VM file in `guests/` with the tags; a
mistyped tag is a VM nothing configures, silently.

**Upgrades** (Talos, then Kubernetes) are `talosctl`, not `tofu apply`:
[Maintenance](../maintenance.md#talos).
Afterwards bump the versions in `cluster/` and `guests/` and `talosctl` /
`kubectl` in `mise.toml`, and apply both layers.

**Extensions** (`intel-ucode`, `qemu-guest-agent`, `nvme-cli`,
`util-linux-tools`) are listed in both `cluster/cluster_nodes.tf` and
`guests/guest_talos_image.tf`. Both layers output `talos_schematic_id`;
compare them before an upgrade, or it silently drops the extensions.

**Machine config contract.** `talos_config_contract` stays at `v1.13`: from
v1.14 Talos splits install/network/proxy/apiServer into separate documents,
which the v1alpha1 patches in `cluster_talos.tf` collide with. Raise it only
together with rewriting the patches.

**Cilium.** Helm release in the cluster layer. Its values are hashed into a
pod annotation so a values-only change actually rolls the pods.

## Gotchas

- **`talosctl upgrade --preserve` on a single control plane.** Without it the
  upgrade wipes `EPHEMERAL` and removes the node from etcd -- the whole
  cluster.
- **The VIP comes up only once etcd has a leader.** On one node "etcd
  unhealthy" and "`k8s.<lab_domain>` answers nothing" are the same event; use
  the Talos API on the node address.
- **Bumping `talos_version` does not replace the VM.**
  `guests/guest_vm_talos_cp_1.tf` has `ignore_changes = [disk[0].import_from]`,
  so a new image is ignored; a deliberate rebuild is `tofu taint`.
- **`talosctl` must be on the node's minor** -- an older client rejects a newer
  node.
- **Nodes resolve via `10.212.4.1`**, not `10.212.2.1` (k8s deny policy), and
  pin `k8s.<lab_domain>` in `extraHostEntries` so bringup needs no DNS.
- **`10.212.4.200` is stated four times** (cluster pool, network DNS record and
  table, platform). Nothing checks; a missed edit is a name that resolves to
  nothing.
- **Gateway API CRDs are pinned to what Cilium needs** (`cluster_gateway_api.tf`).
  Bump them together. Upstream's `safe-upgrades` policy refuses downgrades
  below v1.5.
- **Talos has no SSH.** Logs and files go through `talosctl logs`,
  `talosctl read`, `talosctl dashboard`.

## What breaks without it

Every workload: all apps, Pocket ID (so SSO falls back to break-glass
everywhere), OpenBao, Zot, Prometheus and Alertmanager. Alerts stop too --
the external `Watchdog` heartbeat noticing the silence is the only signal
(see [Monitoring](../monitoring.md)). Proxmox, the NAS, PBS, the VPN and Home
Assistant are unaffected.
