# Maintenance

What to check, how updates arrive, and how to upgrade the pieces that do not
update themselves. Most of the lab tells you when something is wrong
([Monitoring](monitoring.md)); the items here are what nothing alerts on.

## Updates: Renovate {#renovate}

[Renovate](https://docs.renovatebot.com) opens a PR per available update, both
in this repo and in `flux/` -- each repo has its own `renovate.json`. The PR
is the notification; the "Dependency Dashboard" issue lists everything
outstanding.

| Repo | Merging means |
|--|--|
| homelab (this one) | the pin changes only -- applying it is still `mise run <layer>` |
| homelab-apps (`flux/`) | deploying: Flux reconciles `main` |

- A release is proposed once it is **3 days old** (immediately where the
  registry has no release date, as with ghcr.io charts).
- The **`flux` submodule pointer** is the exception: Renovate commits it
  straight to `main` whenever homelab-apps moves, since Flux reads that repo
  directly and the pointer is only a record. The `secrets` pointer is never
  touched -- it moves only through `mise run save`.
- **Tofu providers and modules** are batched into one `terraform` PR, opened
  Monday mornings.
- **Talos and Kubernetes** get one PR per minor, since they upgrade one minor
  at a time (see below).
- **Images in our own Zot registry** are skipped; `mise run image` pushes and
  bumps those (see [Zot](platform/zot.md)).

Versions held in tofu `locals` are invisible to Renovate unless annotated on
the line above:

```hcl
# renovate: datasource=helm depName=cilium registryUrl=https://helm.cilium.io/
cilium_version = "1.20.3"
```

Datasources in use: `helm`, `docker` (OCI charts), `github-releases`. Add
`extractVersion=^v(?<version>.+)$` when upstream tags carry a `v` the pin does
not.

GitHub Actions are pinned by commit SHA with the tag in a comment; Renovate
bumps both. A push to `main` (a merged PR, a flux pointer bump) rebuilds this
site via `.github/workflows/docs.yml`; a broken link fails it.

Not covered by Renovate: TrueNAS itself and Proxmox packages (below), Home
Assistant (updates itself from its UI), PBS and the VPN VM (apt by hand, like Proxmox), and
`restic`, which is not pinned at all.

## Checklist

### NAS {#nas}

- check for updates
- check on storage health (scrub + SMART results -- SMART tests are not set up
  yet, see [Storage](storage.md#admin))
- check on growth of datasets (`NasPoolFull` warns at 80%)
- check snapshot tasks ran (*Data Protection* -> *Periodic Snapshot Tasks*),
  occasionally test-restore a file ([ZFS snapshots](backups.md#zfs-snapshots))
- apps (`machines/truenas/apps/`): after merging a Renovate bump, edit the app
  in TrueNAS and set the new tag -- nothing applies it automatically

### Backups {#backups}

- VolSync: `kubectl get replicationsource -A` -- every LAST SYNC within a
  day; the `VolSyncBackupFailing` alert is the same check, pushed
- Garage: `k8s-backups` well under its 50G quota
  (`mise run s3 volsync ls --summarize --human-readable --recursive s3://k8s-backups/`)
- PBS: PBS -> *Datastore* -> `proxmox-backups` -> *Content*: last snapshot per
  VM from last night, verify state OK. Nothing alerts on a failed job.
- Home Assistant: *Settings* -> *System* -> *Backups* shows a recent one.
- `git -C secrets status -sb` -- nothing "ahead" (not pushed is not backed up)
- after removing an app for good, delete its `k8s-backups/<ns>/<pvc>/` prefix
  -- see [VolSync, *Removing an app*](backups.md#volsync)

### Proxmox {#proxmox}

- check for updates (`apt update && apt full-upgrade`), reboot on new kernel
  (`mise run machine-config` does a `dist-upgrade` too, and re-applies the
  subscription-nag patch an upgrade reverts)
- check backup jobs succeeded
- same for the PBS and VPN VMs

### Certificates

Nothing watches renewals. Once in a while:

```sh
kubectl -n gateway get certificate wildcard-app      # the app. wildcard
```

and check the expiry in a browser on the Proxmox, PBS and TrueNAS UIs. See
[Networking, *cert-manager*](networking.md#cert-manager).

### Yearly: re-drill restores {#drill}

Once a year, actually restore something per route and update its **Last
verified** date on [Backups & restore](backups.md):

- [ZFS snapshots](backups.md#zfs-snapshots) -- copy a file back out of
  `.zfs/snapshot`
- [PBS](backups.md#pbs) -- restore a VM to a spare id, boot it, delete it
- [Home Assistant's own backups](backups.md#ha-backups) -- the key still
  decrypts the newest one
- [VolSync](backups.md#volsync) -- the drill in a throwaway namespace, or one
  real app into a scratch PVC
- [Secrets repo](backups.md#secrets-repo) -- a fresh clone with only
  `.vault-pass` gets to `mise run cluster plan`
- [etcd snapshots](backups.md#etcd-snapshots) -- at least that one can be
  taken
- [Recover from zero](recover-from-zero.md) -- reread it against what the lab
  is now

Every route whose date says *never* is the first in line.

## Talos upgrades {#talos}

- check GitHub releases for breaking/relevant changes
- minor versions: upgrade only to the next adjacent one (patches are fine)
- control-plane nodes first, one at a time, then workers
- Kubernetes is upgraded separately, check the support matrix first
- bump `talos_version` in the guests layer too (no changes are expected, it
  only swaps the downloaded image -- just drag it along)
- bump `talosctl` in `mise.toml` to the new minor -- an older client rejects a
  newer node

**`--preserve` is mandatory on a single control plane.** Without it the
upgrade wipes `EPHEMERAL` and removes the node from etcd -- which on one node
is the whole cluster. See [Talos / Kubernetes](platform/talos.md).

```sh
# 1. etcd snapshot beforehand (plaintext of every Secret: keep it out of git;
#    the repo-root ./db.snapshot is gitignored)
talosctl -n talos-cp-1.<lab_domain> etcd snapshot ./db.snapshot

# 2. select node to update
NODE='talos-cp-1.<lab_domain>'

# 3. get current server version
talosctl -n "$NODE" version --short

# 4. verify schematic ids of the stages match and grab it,
#    since the new version must be deployed with the same one
SCHEMATIC="$(mise run cluster output -raw talos_schematic_id)"
[ "$SCHEMATIC" = "$(mise run guests output -raw talos_schematic_id)" ] \
    && echo match || echo MISMATCH

# 5. upgrade (in this example 1.13.11)
talosctl -n "$NODE" upgrade --preserve \
    --image factory.talos.dev/nocloud-installer/"$SCHEMATIC":v1.13.11

# 6. verify before moving to the next node
talosctl -n "$NODE" health
talosctl -n "$NODE" version --short

# 7. once all nodes are done: kubernetes upgrade (below)

# 8. only now record it: merge the Renovate PRs (cluster + guests), then
#    apply -- the plan should show the installer image and nothing that rolls
mise run cluster plan
```

## Kubernetes upgrades {#kubernetes}

- check the Talos support matrix -- the running Talos version must support the
  target Kubernetes
- read the Kubernetes changelog "Urgent Upgrade Notes" + removed/deprecated
  APIs
- check deprecated API usage before upgrading
  (`kubectl get --raw /metrics | grep apiserver_requested_deprecated_apis`)
- check Helm charts/controllers (Cilium, Flux, CSI drivers, etc.) support the
  new version
- minor versions: one at a time (no skipping), patches are fine
- after the upgrade: bump `kubernetes_version` in `cluster/cluster_nodes.tf`
  and `kubectl` in `mise.toml` (kubectl supports +/-1 minor skew), then
  `mise run cluster plan` -- should be a no-op on the nodes

```sh
# 1. etcd snapshot beforehand
talosctl -n talos-cp-1.<lab_domain> etcd snapshot ./db.snapshot

# 2. pick any one control-plane node -- unlike the Talos upgrade this is
#    cluster-wide, the node is only the entry point, run it once
NODE='talos-cp-1.<lab_domain>'

# 3. dry run shows what changes (images, removed APIs)
talosctl -n "$NODE" upgrade-k8s --to <version> --dry-run

# 4. upgrade (rolls control plane, then kubelets on all nodes)
talosctl -n "$NODE" upgrade-k8s --to <version>

# 5. verify
kubectl get nodes -o wide
talosctl -n "$NODE" health
```

## Other upgrades

- **Flux** is pinned twice: the flux-operator chart and
  `distribution.version` in the FluxInstance. Bump both together, then
  `mise run platform apply`. See [Flux](platform/flux.md).
- **Gateway API CRDs and Cilium** are pinned against each other -- see
  [Talos / Kubernetes](platform/talos.md).
- **DHS's `pg_dump` image** tracks the DHS server's postgres major. Bump both
  together -- see [DHS](workloads/dhs.md).
- **App images with migrations** (Vaultwarden, Pocket ID, ...) are not undone
  by reverting the tag; the way back is a restore. Check the app's page before
  merging a major.
