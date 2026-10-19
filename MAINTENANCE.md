# Maintenance Documentation

## NAS
- check for updates
- check on storage health (scrub + SMART results)
- check on growth of datasets
- check snapshot/replication tasks ran, occasionally test-restore a file
- apps (`machines/truenas/apps/`): after merging a Renovate bump, edit the app
  in TrueNAS and set the new tag -- nothing applies it automatically

## Proxmox
- check for updates (`apt update && apt full-upgrade`), reboot on new kernel
- check backup jobs succeeded

## Talos Linux - Maintenance Doc
- check github releases for breaking/relevant changes
- minor versions: upgrade only to the next adjacent one (patches are fine)
- control-plane nodes first, one at a time, then workers
- kubernetes is upgraded separately, check support matrix first
- update the version in the guests layer (no changes are expected) just do drag it along
- bump `talosctl` in mise.toml to the new minor -- an older client rejects a newer node

```sh
# 1. db snapshot beforehand
talosctl etcd snapshot ./db.snapshot

# 2. select node to update
NODE='talos-cp-1.<lab domain>'

# 3. get current server version
talosctl -n "$NODE" version --short

# 4. verify schematic ids of the stages match and grab it,
#    since the new version must be deployed with the same one
SCHEMATIC="$(mise run cluster output -raw talos_schematic_id)"
[ "$SCHEMATIC" = "$(mise run guests output -raw talos_schematic_id)" ] \
    && echo match || echo MISMATCH

# 5. upgrade (in this example 1.13.11)
talosctl -n "$NODE" upgrade \
    --image factory.talos.dev/nocloud-installer/"$SCHEMATIC":v1.13.11

# 6. verify before moving to the next node
talosctl -n "$NODE" health
talosctl -n "$NODE" version --short

# 7. once all nodes are done: kubernetes upgrade
talosctl -n "$NODE" upgrade-k8s --to <k8s version>

# 8. only now record it: merge the Renovate PRs (cluster + guests), then
#    apply -- the plan should show the installer image and nothing that rolls
mise run cluster plan
```

## K8s
- check the Talos support matrix -- the running Talos version must support the target k8s
- read the k8s changelog "Urgent Upgrade Notes" + removed/deprecated APIs
- check deprecated API usage before upgrading (`kubectl get --raw /metrics | grep apiserver_requested_deprecated_apis`)
- check helm charts/controllers (cilium, flux, CSI drivers, etc.) support the new version
- minor versions: one at a time (no skipping), patches are fine
- after the upgrade: bump `kubernetes_version` in `cluster/cluster_nodes.tf` and `kubectl` in mise.toml
  (kubectl supports +/-1 minor skew), then `mise run cluster plan` -- should be a no-op on the nodes

```sh
# 1. db snapshot beforehand
talosctl etcd snapshot ./db.snapshot

# 2. pick any one control-plane node -- unlike the Talos upgrade this is
#    cluster-wide, the node is only the entry point, run it once
NODE='talos-cp-1.<lab domain>'

# 3. dry run shows what changes (images, removed APIs)
talosctl -n "$NODE" upgrade-k8s --to <version> --dry-run

# 4. upgrade (rolls control plane, then kubelets on all nodes)
talosctl -n "$NODE" upgrade-k8s --to <version>

# 5. verify
kubectl get nodes -o wide
talosctl -n "$NODE" health
```
