# Kassenbuch

## What it's for

Single-user Kassenbuch (cash book) for the Verein: entries, Belege
(receipts), exports. Built in a private repo.

## Access

- **URL:** `https://kassenbuch.<app_domain>`
- **Reachability:** LAN and tailnet, like everything behind the gateway. Not
  public. See [Networking](../networking.md).
- **Login:** one password; the plaintext lives in the password managers. No
  users, no SSO.

## Where it runs

Namespace `kassenbuch`, one Deployment, Flux Kustomization `kassenbuch`.
Image `registry.<app_domain>/kassenbuch` from [Zot](../platform/zot.md).
Wiring: [Build guide: Kassenbuch](../build/flux/docs/kassenbuch.md).

## Data

One `bulk` PVC, `kassenbuch-data` (10Gi, a label -- NFS directory, not
enforced), mounted at `/data`:

| Path | What | State? |
|--|--|--|
| `kassenbuch.db` (+ `-wal`) | the books (SQLite, WAL) | **yes** |
| `belege/` | receipts | **yes** |
| `exports/` | generated exports | **yes** |

These are records with a retention duty (ten years), so they sit on the
mirror and in the NAS snapshots rather than on the unmirrored `fast` NVMe.

Not state: the password hash (OpenBao, from `secrets/vault.yml` via tofu)
and the manifests.

## Backup & restore

Covered by [ZFS snapshots](../backups.md#zfs-snapshots) on `slow/k8s-csi`:
24 hourly + 30 daily. Not by VolSync. A ZFS snapshot is atomic, so db and
`-wal` are caught together.

**Restore.** The generic [ZFS restore](../backups.md#zfs-snapshots) of a
`bulk` PVC. Find its directory:

```sh
kubectl get pv $(kubectl -n kassenbuch get pvc kassenbuch-data -o jsonpath='{.spec.volumeName}') \
  -o jsonpath='{.spec.csi.volumeAttributes.share}'
```

Then:

```sh
flux suspend kustomization kassenbuch
kubectl -n kassenbuch scale deploy/kassenbuch --replicas=0
# on the NAS: copy from .zfs/snapshot/<snap>/<pvc-dir>/ back into /mnt/slow/k8s-csi/<pvc-dir>/
flux resume kustomization kassenbuch
```

**Verify.**

```sh
kubectl -n kassenbuch rollout status deploy/kassenbuch
kubectl -n kassenbuch logs deploy/kassenbuch | tail
```

Then log in, check the latest entry is the one you expect, and open a recent
Beleg.

## Admin

**Password.** The app reads `KASSENBUCH_PASSWORD_HASH` (argon2). The hash
sits in `secrets/vault.yml` as `kassenbuch_password_hash`, from where
`platform_secrets.tf` writes it to OpenBao at `kv/kassenbuch/app`.

Set or rotate:

```sh
docker run --rm -it registry.<app_domain>/kassenbuch:<tag> node scripts/hash-password.js
ansible-vault edit secrets/vault.yml      # kassenbuch_password_hash: <the hash> (unquoted)
mise run platform apply
kubectl -n kassenbuch annotate externalsecret kassenbuch force-sync=$(date +%s) --overwrite
kubectl -n kassenbuch rollout restart deploy/kassenbuch   # env is read at start
```

Then commit with `mise run save "kassenbuch: rotate password"`.

**Updates.** The tag is pinned. A release is a `v*` tag in the app repo (CI
pushes `<version>`) followed by a bump of `image:` in
`apps/kassenbuch/server.yaml`. Migrations run on start, so a bump is not
undone by reverting the tag -- the way back is a
[restore](#backup--restore). Zot allows anonymous pulls, so there is no pull
secret.

## Gotchas

- **Never scale past one replica.** SQLite on NFS holds only because there is
  one pod on one node over NFSv4.1 with its own locking. `Recreate` for the
  same reason.
- **Large uploads need `timeout 0s`** on the HTTPRoute -- Envoy's 15s default
  cuts off large Beleg uploads and zip imports.
- **`ORIGIN` is load-bearing.** The session cookie is Secure and form actions
  are CSRF-checked against `https://kassenbuch.<app_domain>`.
- **No health endpoint;** the probes hit `/login`.
