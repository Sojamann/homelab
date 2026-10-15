# Maintenance Documentation

## NAS
- check for updates
- check on storage health (scrub + SMART results)
- check on growth of datasets
- check snapshot/replication tasks ran, occasionally test-restore a file

## Proxmox
- check for updates (`apt update && apt full-upgrade`), reboot on new kernel
- check backup jobs succeeded

## Talos Linux - Maintenance Doc
- check github releases for breaking/relevant changes
- minor versions: upgrade only to the next adjacent one (patches are fine)
- control-plane nodes first, one at a time, then workers
- kubernetes is upgraded separately, check support matrix first

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
```
