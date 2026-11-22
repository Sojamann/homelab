# Immich

## What it's for

The household's photos and videos: phones back up to it, a shared timeline,
albums, faces, search by content ("dog on the beach"), duplicates. Immich owns
the originals -- the primary copy once a phone deletes its own. Using it is
upstream: [Immich docs](https://docs.immich.app).

## Access

- **URL:** `https://photos.<app_domain>`. LAN and tailnet; not public, so
  share links only open there too, and phones back up at home or while
  Tailscale is connected. See [Networking](../networking.md).
- **Login:** redirected straight to Pocket ID; the password form is off. The
  first login creates the account. Who may log in is the Pocket ID client's
  allowed groups, `admins` + `household`. The mobile app logs in the same way
  (server URL `https://photos.<app_domain>`, then *Login with Pocket ID*).
- **Admins** are whoever carries the claim `immich_role: admin` -- a custom
  claim on Pocket ID's `admins` group. Synced on every login, so removing it
  demotes. No admin sign-up form (`IMMICH_ALLOW_SETUP=false`).
- **Break-glass** (Pocket ID down): turn password login on and set the
  admin's password. The config file is read-only, so the first command is
  undone on the next start:
  ```sh
  kubectl -n immich exec deploy/immich-server -- immich-admin enable-password-login
  kubectl -n immich exec -it deploy/immich-server -- immich-admin reset-admin-password
  ```
  Log in at `https://photos.<app_domain>/auth/login?autoLaunch=0` with the
  admin's email and that password.

## Where it runs

Namespace `immich`: Deployments `immich-server`, `immich-machine-learning`
(CPU, capped at 2 cores) and `immich-valkey` (job queue), CNPG `Cluster`
`immich-db` (Postgres + VectorChord). Flux Kustomization `immich`. Wiring:
[Build guide: Immich](../build/flux/docs/immich.md).

## Data

| Volume | What | Storage | State? |
|--|--|--|--|
| `immich-data` -> `/data` | `library/` originals, `upload/`, `profile/`; `thumbs/`, `encoded-video/` | static PV on `slow/k8s-csi/immich`, `Retain` | **yes** -- thumbs and video regenerate |
| `immich-db-1` (CNPG) | users, albums, faces, search vectors, every asset's path | `fast`, 5Gi | **yes** |

`immich-data` is made by hand: `slow/k8s-csi/immich`, owned by uid 1000 --
see [machines/truenas.md](../build/machines/truenas.md). The 500Gi capacity is
a label, not enforced; no per-user quota.

Originals are laid out by the storage template,
`library/<user>/<year>/<year>-<month>-<day>/<file>`, `<user>` being the
Pocket ID username at first login. Readable on the NAS without Immich.

The db and the files belong together: the db holds every file's path and
checksum. Their snapshots are seconds apart, not atomic, so a restore can
leave a handful of untracked or missing files.

Not state: the Pocket ID client (OpenBao), the config file (git), Valkey's
queue, the ML model cache.

## Backup & restore

Both in the [ZFS snapshots](../backups.md#zfs-snapshots), 24 hourly + 30
daily, at the same minute; nothing off-box.

- **Files:** on `slow/k8s-csi`. Deleted photos also sit in Immich's trash for
  30 days.
- **Db** (`immich-db-1`): its zvol, replicated to `slow/fast-replica`.
  Crash-consistent: postgres replays its WAL on start. Immich's own nightly
  dumps are off.

**Restore.** Untested. Pick one snapshot name for both. Stop everything
first -- the db by hibernating its `Cluster`:

```sh
flux suspend kustomization immich
kubectl -n immich scale deploy/immich-server --replicas 0
kubectl -n immich annotate cluster immich-db cnpg.io/hibernation=on
```

1. **Db:** step 2 of the generic [`fast` restore](../backups.md#zfs-snapshots)
   for `immich-db-1`.
2. **Files:** the generic [`bulk` restore](../backups.md#zfs-snapshots) of
   `immich/`, keeping uid 1000. Skip when only the db was lost.
3. **Up:**
   ```sh
   kubectl -n immich annotate cluster immich-db cnpg.io/hibernation-
   flux resume kustomization immich
   ```
4. **Reconcile:** *Administration -> Maintenance* runs the integrity checks:
   untracked files are uploads newer than the db snapshot (re-upload them from
   the phone), missing ones were deleted after it. Then *Queues* -> run
   *Missing* for thumbnails and encoded video.

**Verify.**

```sh
kubectl -n immich rollout status deploy/immich-server
kubectl -n immich get cluster immich-db   # STATUS "Cluster in healthy state"
```

Then log in through Pocket ID: the timeline is there and an old original
opens at full size.

## Admin

**What git owns:** all of *Administration -> Settings*, which the UI shows
read-only. The config file is `config.yaml` in the app's directory, rendered
with the OIDC client by an `ExternalSecret`. Keys not in it keep Immich's
defaults. It sets: Pocket ID login only (auto-launch, auto-register, role and
storage label from claims), the storage template, Immich's db dumps off, the
version check off (Renovate's job), every ML job at concurrency 1.

The server reads it at start only. After a change has synced:

```sh
kubectl -n immich rollout restart deploy/immich-server
```

**Updates.** Image tags pinned in `server.yaml` and `machine-learning.yaml`;
Renovate bumps both in one PR (see [Maintenance](../maintenance.md)). The
server runs db migrations on start, before it turns Ready.

- **Read the release notes** before merging a major: Immich's breaking
  changes land there, sometimes with manual steps.
- **There is no rollback.** The way back from a bad migration is a restore.
- **Postgres + VectorChord**: `imageName` in `database.yaml`,
  `<postgres>-<vectorchord>`. Immich updates the extension and reindexes on
  start; it supports Postgres `>= 14, < 20`. A Postgres major is an offline
  in-place upgrade by CNPG -- the last hourly snapshot is the way back.

**First import** (and every big upload after): face detection and smart search
run on CPU, one job at a time -- hours to days for tens of thousands of
photos. *Administration -> Queues* shows them.

### Not enabled

- **Hardware acceleration.** No GPU in the cluster; ML and transcoding are CPU.
- **External libraries.** Immich owns its photos; nothing is mounted read-only
  from elsewhere.
- **Metrics.** None of its own; pod, PVC and CNPG alerts are the cluster's.

## Gotchas

- **Never edit, move or delete under `library/` on the NAS.** Immich does not
  notice; the integrity checks then report missing files or checksum
  mismatches.
- **The storage label is set once**, at first login, from the Pocket ID
  username. Renaming someone in Pocket ID keeps their old folder.
- **Accounts are keyed to Pocket ID's user id**; an existing account with the
  same email is linked on first SSO login.
- **One server pod, `Recreate`**: two versions must never migrate the db at
  once.
- **ML models download on first use** after every ML pod restart (~1GB); the
  first smart search after that is slow.
