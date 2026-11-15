# Memos

## What it's for

Note taking for the household, on trial -- if it sticks, other notes may
move here. Each person has their own notes; sharing is per memo. Using it is
upstream: [Memos docs](https://usememos.com/docs).

## Access

- **URL:** `https://notes.<app_domain>`. LAN and tailnet; not public. See
  [Networking](../networking.md).
- **Login:** *Sign in with Pocket ID*. The first login creates the account
  (username = Pocket ID username). Who may log in is the Pocket ID client's
  allowed groups, `admins` + `household`.
- **Break-glass:** user `admin`, password from OpenBao (`kv/memos/app`,
  generated in `platform_secrets.tf`). Password login is off for everyone
  else; admins keep it.
  ```sh
  kubectl -n memos get secret memos -o jsonpath='{.data.ADMIN_PASSWORD}' | base64 -d
  ```

## Where it runs

Namespace `memos`, one Deployment, Flux Kustomization `memos`.
Wiring: [Build guide: Memos](../build/flux/docs/memos.md).

## Data

| Volume | What | Storage | State? |
|--|--|--|--|
| `memos-data` -> `/var/opt/memos` | `memos_prod.db` (SQLite): notes, users, settings, each attachment's path | `fast`, 1Gi | **yes** |
| `memos-assets` -> `/var/opt/memos/assets` | attachment files | static PV on `slow/k8s-csi/memos`, `Retain` | **yes** |

`memos-assets` is not a `bulk` PVC: a deleted PVC, namespace or app leaves
the directory, and a rebuild re-binds it by name. The directory is made by
hand (owned by uid 1000) -- see
[machines/truenas.md](../build/machines/truenas.md). The 5Gi capacity is a
label, not enforced.

The two belong together: the db names each file under `assets/`, so a db
restored to an older night misses newer files' rows, and a file without a row
is invisible.

Not state: the admin password and Pocket ID client (OpenBao), and the
instance settings (`instance.json`, git).

## Backup & restore

- **Notes (db):** [ZFS snapshots](../backups.md#zfs-snapshots) of its zvol,
  24 hourly + 30 daily, replicated to `slow/fast-replica`.
- **Attachments:** [ZFS snapshots](../backups.md#zfs-snapshots) on
  `slow/k8s-csi`, same schedule, same minute: db and attachments restore to
  points seconds apart.

**Restore.**

- **The db:** the generic [`fast` restore](../backups.md#zfs-snapshots), with:
  ```sh
  NS=memos KS=memos DEPLOY=memos PVC=memos-data
  ```
- **Attachments:** the generic [`bulk` restore](../backups.md#zfs-snapshots)
  of `memos/`, from the same snapshot name as the db.

**Verify.**

```sh
kubectl -n memos rollout status deploy/memos
kubectl -n memos logs deploy/memos | grep -i config
```

Then log in through Pocket ID: your notes are there, and an older note's
attachment opens.

## Admin

**What git owns** (`apps/memos/instance.json`, applied on every start; the
admin UI refuses changes to it):

- the Pocket ID identity provider
- access private; registration open (only via SSO), password auth off
- usernames locked (the SSO link key); weeks start Monday
- attachments to local storage, `assets/{timestamp}_{uuid}_{filename}`
- user `admin`, role admin -- the password is sent on create only. To push a
  rotated one, bump `writeOnlyVersion` in `instance.json`

Everything else -- other settings, each user's profile -- is the UI's, in the
db.

**Making someone admin.** Their SSO account is a normal user; promote it in
*Settings -> Members* as `admin`.

**Updates.** Image tag pinned in `server.yaml`; Renovate proposes bumps (see
[Maintenance](../maintenance.md)). Memos' config file schema is part of its
API; a release that renames a field fails startup loudly rather than drifting.

### Not enabled

- **Metrics and alerts.** Memos exposes no metrics.
- **S3 attachments.** Local storage on the NAS is enough, and keeps one
  backup route per volume.

## Gotchas

- **Renaming a user in Pocket ID gives them a new, empty account** here: the
  username is also the SSO link key. Rename in both, or not at all. Renaming
  in Memos is off for that reason (`disallowChangeUsername`).
- **An invalid `instance.json` stops startup** (`config` in the logs).
- **One pod, `Recreate`.** SQLite has one writer and the data volume is RWO.
