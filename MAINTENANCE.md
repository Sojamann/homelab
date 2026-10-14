# Maintenance Documentation

## Talos Linux - Maintenance Doc
- check github releases for breaking/relevant changes
- upgrade only to the next adjacent version

```sh
# 1. db snapshot beforehand
talosctl etcd snapshot ./db.snapshot

# 2. select node to update
NODE='talos-cp-1.<lab domain>'

# 3. get current server version
talosctl -n "$NODE" version --short

# 4. verify current schematics id of the stages match and grab
#    is since the new version must be deployed with the same one
mise run cluster output -raw talos_schematic_id
mise run guests output -raw talos_schematic_id
SCHEMATIC="$(mise run cluster output -raw talos_schematic_id)"

# 5. upgrade (in this example 1.13.11)
talosctl -n "$NODE" upgrade --preserve \
    --image factory.talos.dev/nocloud-installer/"$SCHEMATIC":v1.13.11
```
