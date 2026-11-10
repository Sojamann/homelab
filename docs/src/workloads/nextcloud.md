# Nextcloud

## What it's for

The household's files in a browser and on phones: upload, share links,
desktop and mobile sync. Files only -- no calendar, contacts or photos. It
replaces nothing: SMB shares and Syncthing stay as they are, and Nextcloud's
files are its own. Using it is upstream:
[Nextcloud user manual](https://docs.nextcloud.com/server/latest/user_manual/en/).

## Access

- **URL:** `https://files.<app_domain>`. LAN and tailnet; not public, so share
  links only open there too. See [Networking](../networking.md).
- **Login:** redirected straight to Pocket ID. The first login creates the
  account. Who may log in is the Pocket ID client's allowed groups, `admins` +
  `household`. Desktop and mobile apps log in through the browser (Login Flow
  v2), so SSO works there too.
- **Break-glass:** user `admin` at `https://files.<app_domain>/login?direct=1`,
  password from OpenBao (`kv/nextcloud/app`, generated in
  `platform_secrets.tf`):
  ```sh
  kubectl -n nextcloud get secret nextcloud -o jsonpath='{.data.NEXTCLOUD_ADMIN_PASSWORD}' | base64 -d
  ```
  Read at install only; afterwards the password lives in Nextcloud's db.

## Where it runs

Namespace `nextcloud`: Deployment `nextcloud`, CronJobs `nextcloud-cron`
(background jobs, every 5 minutes) and `db-dump`, CNPG `Cluster`
`nextcloud-db`. Flux Kustomization `nextcloud`.
Wiring: [Build guide: Nextcloud](../build/flux/docs/nextcloud.md).

## Data

| Volume | What | Storage | State? |
|--|--|--|--|
| `nextcloud-data` -> `/var/www/html/data` | everyone's files, trash, versions | static PV on `slow/k8s-csi/nextcloud`, `Retain` | **yes** |
| `nextcloud-html` -> `/var/www/html` | code, `config.php` (instance id, secret, salt), installed apps | `fast`, 5Gi | **yes** -- `secret` decrypts stored app values |
| `nextcloud-db-1` (CNPG) | users, shares, the file cache, app settings | `fast`, 5Gi | **yes** |
| `db-dump` | last night's `pg_dump -Fc` | `fast`, 5Gi | staging copy |

`nextcloud-data` is made by hand: `slow/k8s-csi/nextcloud`, owned by uid 33,
mode `0770` -- see [machines/truenas.md](../build/machines/truenas.md). The
500Gi capacity is a label, not enforced; no per-user quota.

The db and the files belong together: the db's file cache indexes the
directory. They are backed up at different times, so a restore ends with a
rescan.

Not state: the admin password and Pocket ID client (OpenBao), `lab.config.php`
and the start hook (git).

## Backup & restore

- **Files:** [ZFS snapshots](../backups.md#zfs-snapshots) on `slow/k8s-csi`,
  24 hourly + 30 daily. Not in VolSync, nothing off-box. Deleted files also
  sit in Nextcloud's trash bin, older versions under *Versions*.
- **Db:** `db-dump` at `01:15` UTC, then [VolSync](../backups.md#volsync) at
  `01:45`, retain daily 14, weekly 8, monthly 6.
- **`nextcloud-html`:** VolSync at `02:00`, same retention.

**Restore.** Untested. Stop everything first:

```sh
flux suspend kustomization nextcloud
kubectl -n nextcloud scale deploy/nextcloud --replicas 0
kubectl -n nextcloud patch cronjob nextcloud-cron db-dump -p '{"spec":{"suspend":true}}'
```

1. **`nextcloud-html`:** the generic [VolSync restore](../backups.md#volsync),
   with
   ```sh
   NS=nextcloud KS=nextcloud DEPLOY=nextcloud PVC=nextcloud-html MOVER_UID=33
   ```
2. **The db.** Get the dump: last night's is on `db-dump` (copy it out as in
   [DHS](dhs.md#backup--restore), step 2, with `claimName: db-dump`); older
   ones with restic [without the cluster](../backups.md#volsync)
   (`NS=nextcloud PVC=db-dump`). Then, into the running instance:
   ```sh
   kubectl -n nextcloud exec -i nextcloud-db-1 -- \
     pg_restore -U postgres -d nextcloud --clean --if-exists --no-owner \
     --role=nextcloud --single-transaction < nextcloud.dump
   ```
   A fresh `Cluster` is fine: the dump holds no roles, CNPG creates
   `nextcloud`, and `lab.config.php` reads the new password from env.
3. **Files:** the NAS snapshots, `.zfs/snapshot/<name>/nextcloud/` under
   `/mnt/slow/k8s-csi`. Copy back as uid 33. Skip when only the db was lost.
4. **Up, then reconcile the db with the files:**
   ```sh
   flux resume kustomization nextcloud   # scales up; `suspend` is not Flux's field
   kubectl -n nextcloud patch cronjob nextcloud-cron db-dump -p '{"spec":{"suspend":false}}'
   occ() { kubectl -n nextcloud exec deploy/nextcloud -- php occ "$@"; }
   occ maintenance:mode --on
   occ files:scan --all
   occ maintenance:data-fingerprint      # sync clients re-check instead of trusting old state
   occ maintenance:mode --off
   ```

**Verify.**

```sh
kubectl -n nextcloud rollout status deploy/nextcloud
kubectl -n nextcloud exec deploy/nextcloud -- php occ status
kubectl -n nextcloud get cluster nextcloud-db   # STATUS "Cluster in healthy state"
```

Then log in through Pocket ID: your files are there and an older one opens.
*Administration settings -> Overview* shows no errors.

## Admin

**What git owns:**

- `server.yaml` env: trusted domain, proxy, db connection, the admin's
  install-time password
- `config/lab.config.php`, copied into `config/` on every start: db from env, no skeleton files, phone region DE,
  maintenance window from 01:00 UTC, log to stderr, local remote servers
  allowed (Pocket ID resolves to the gateway's private address)
- `config/lab-hook.sh`, on every start: background jobs on cron, default apps
  other than files turned off (activity, dashboard, photos, ...), `user_oidc`
  installed, provider `Pocket ID` written from env, Pocket ID the only login

Changes in the UI to any of these are undone on the next start. Everything
else -- sharing settings, users -- is the UI's, in the db.

**Making someone admin.** Pocket ID groups are not mapped. Log in as `admin`
(break-glass), *Users*, add the person to group `admin`.

**Updates.** Image tag pinned in `server.yaml` and `cron.yaml`; Renovate
proposes bumps (see [Maintenance](../maintenance.md)). The image runs
`occ upgrade` on start, before the pod turns Ready.

- **Majors one at a time**, never skipped: Renovate opens one PR per major.
  Merge, wait for the rollout, check *Administration settings -> Overview*,
  then the next.
- **There is no rollback.** The way back from a bad upgrade is a restore.
- **`user_oidc`** is from the app store, not pinned: update it in *Apps* or
  with `occ app:update --all`.
- **Postgres**: `imageName` in `database.yaml` and the image in `dump.yaml`
  move together in one Renovate PR. A major is an offline in-place upgrade by
  CNPG -- take a fresh dump first.

### Not enabled

- **Calendar, contacts, photos, office.** Files only, by decision.
- **Redis.** Not needed at this size; add it for locking if the db's file
  locks show up as slow.
- **Metrics.** Only `NextcloudDumpStale` (warning, no successful dump in 26h);
  pod and PVC alerts are the chart's.

## Gotchas

- **The data directory must be `0770`, owner 33.** Otherwise Nextcloud
  refuses to start with a permissions error.
- **`/login?direct=1`** is the only way to the password form; plain `/login`
  goes straight to Pocket ID.
- **Accounts are keyed to Pocket ID's user id**, not the username: renaming
  someone in Pocket ID keeps their files.
- **Files put into `slow/k8s-csi/nextcloud` on the NAS are invisible** until
  `occ files:scan --all`.
- **One pod, `Recreate`.** The html volume is RWO, and two versions must
  never run `occ upgrade` at once.
