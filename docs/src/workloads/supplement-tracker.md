# Supplement tracker

## What it's for

The household's supplement plan, daily ticks and nutrient overview. Built in
the private repo `supplement-tracker`.

## Access

- **URL:** `https://supplements.<app_domain>`
- **Reachability:** LAN and tailnet, like everything behind the gateway. Not
  public. See [Networking](../networking.md).
- **Login:** none. Reachability is the only guard.

## Where it runs

Namespace `supplement-tracker`, one Deployment, Flux Kustomization
`supplement-tracker`. Image `registry.<app_domain>/supplement-tracker` from
[Zot](../platform/zot.md).
Wiring: [Build guide: Supplement tracker](../build/flux/docs/supplement-tracker.md).

## Data

One `bulk` PVC, `supplement-tracker-data` (1Gi, a label -- NFS directory, not
enforced), mounted at `/data`. It holds only `supplements.db` (+ `-wal`,
SQLite, WAL): the plan and the intake history. **State.**

Not state: the manifests. No secrets.

## Backup & restore

Covered by [ZFS snapshots](../backups.md#zfs-snapshots) on `slow/k8s-csi`:
24 hourly + 30 daily. Not by VolSync. The app has no export, so this is the
only backup. A ZFS snapshot is atomic, so db and `-wal` are caught together.

**Restore.** The generic [ZFS restore](../backups.md#zfs-snapshots) of a
`bulk` PVC. Find its directory:

```sh
kubectl get pv $(kubectl -n supplement-tracker get pvc supplement-tracker-data -o jsonpath='{.spec.volumeName}') \
  -o jsonpath='{.spec.csi.volumeAttributes.share}'
```

Then:

```sh
flux suspend kustomization supplement-tracker
kubectl -n supplement-tracker scale deploy/supplement-tracker --replicas=0
# on the NAS: copy from .zfs/snapshot/<snap>/<pvc-dir>/ back into /mnt/slow/k8s-csi/<pvc-dir>/
flux resume kustomization supplement-tracker
```

**Verify.**

```sh
kubectl -n supplement-tracker rollout status deploy/supplement-tracker   # /healthz runs a query
```

Then open the page: the plan is there and the last ticks are the ones you
expect.

## Admin

**Config.** Only `ORIGIN`, the public URL that form actions are CSRF-checked
against. No secrets, so no ExternalSecret.

**Updates.** The tag is pinned. A release is a `v*` tag in the app repo,
`mise run release` there, then `mise run image supplement-tracker <version>`
here, which pushes it to Zot and bumps `image:` in
`apps/supplement-tracker/server.yaml`. Migrations run on start, so a bump is
not undone by reverting the tag -- the way back is a
[restore](#backup--restore). Zot allows anonymous pulls, so there is no pull
secret.

## Gotchas

- **Never scale past one replica.** SQLite on NFS holds only because there is
  one pod on one node over NFSv4.1 with its own locking. `Recreate` for the
  same reason.
- **`ORIGIN` must match the URL**, or every form post fails the CSRF check.
