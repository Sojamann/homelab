# AFFiNE

## What it's for

Docs, whiteboards and databases for the household, on trial against
[Memos](memos.md): one of the two goes once a winner is clear. Using it is
upstream: [AFFiNE docs](https://docs.affine.pro).

## Access

- **URL:** `https://affine.<app_domain>`. LAN and tailnet; not public. See
  [Networking](../networking.md).
- **Login:** *Continue with OIDC* (Pocket ID). The first login creates the
  account, **linked by email**. Who may log in is the Pocket ID client's
  allowed groups, `admins` + `household`. Signup by email is off.
- **Break-glass:** the admin made in the first-visit setup
  (`/admin`), email + password, kept in the password managers. Nothing in
  OpenBao or tofu knows it.

## Where it runs

Namespace `affine`: Deployment `affine`, Deployment `valkey`, CNPG `Cluster`
`affine-pg`, CronJob `postgres-dump`. Flux Kustomization `affine`.
Wiring: [Build guide: AFFiNE](../build/flux/docs/affine.md).

## Data

| Volume | What | Storage | State? |
|--|--|--|--|
| `affine-pg-1` (CNPG) | postgres: docs, users, workspaces, settings | `fast`, 5Gi | **yes** |
| `affine-storage` -> `/home/node/.affine/storage` | blobs: attachments, images, avatars | static PV on `slow/k8s-csi/affine`, `Retain` | **yes** |
| `postgres-dump` | last night's `pg_dump -Fc` | `fast`, 5Gi | staging copy |
| Valkey | sessions, queue, cache | `emptyDir` | no |

`affine-storage` is not a `bulk` PVC: a deleted PVC, namespace or app leaves
the directory, and a rebuild re-binds it by name. The directory is made by
hand (owned by uid 1000) -- see
[machines/truenas.md](../build/machines/truenas.md). The 10Gi capacity is a
label, not enforced.

The db names each blob, so a db restored to an older night misses newer
blobs' rows; the blobs are then unreferenced, not lost.

Not state: the signing key and Pocket ID client (OpenBao, `kv/affine/app`;
the key is generated in `platform_secrets.tf` and lives in tofu state), the
config (`apps/affine/secret.yaml`, git), the db password (CNPG generates it,
and a restore brings a new one).

## Backup & restore

- **Database:** a `pg_dump -Fc` at `00:45` UTC (`dump.yaml`) onto
  `postgres-dump`, which [VolSync](../backups.md#volsync) backs up at `01:30`,
  retain daily 14, weekly 8, monthly 6. The `Cluster`'s own PVC is not backed
  up.
- **Blobs:** [ZFS snapshots](../backups.md#zfs-snapshots) on
  `slow/k8s-csi`, 24 hourly + 30 daily. Not in VolSync.

**Restore the database.** Untested end to end.

1. **Pick the dump.** Last night's is still on `postgres-dump`. Anything
   older, or a lost PVC: the generic [VolSync restore](../backups.md#volsync)
   over `postgres-dump` (`restoreAsOf` for a point in time), with
   ```sh
   NS=affine KS=affine DEPLOY=affine PVC=postgres-dump MOVER_UID=70
   ```
   Suspend `affine` anyway, or the CronJob overwrites the dump at `00:45`.
2. **Stop the app:** `kubectl -n affine scale deploy/affine --replicas=0`.
3. **Restore into the `Cluster`**, as the app role (it owns everything in
   the db), from a pod that mounts the dump. `--single-transaction`: it lands
   whole or not at all.
   ```sh
   kubectl -n affine run restore --image=docker.io/library/postgres:17.11-alpine --restart=Never \
     --overrides='{"spec":{"volumes":[{"name":"d","persistentVolumeClaim":{"claimName":"postgres-dump","readOnly":true}}],
       "containers":[{"name":"restore","image":"docker.io/library/postgres:17.11-alpine","command":["sleep","3600"],
       "env":[{"name":"PGHOST","value":"affine-pg-rw"},{"name":"PGDATABASE","value":"affine"},
         {"name":"PGUSER","valueFrom":{"secretKeyRef":{"name":"affine-pg-app","key":"username"}}},
         {"name":"PGPASSWORD","valueFrom":{"secretKeyRef":{"name":"affine-pg-app","key":"password"}}}],
       "volumeMounts":[{"name":"d","mountPath":"/dump","readOnly":true}]}]}}'
   kubectl -n affine exec restore -- \
     pg_restore --clean --if-exists --no-owner --single-transaction -d affine /dump/postgres.dump
   kubectl -n affine delete pod restore
   ```
4. **Start the app:** scale to 1; the migration initContainer finds the
   schema current. Resume `affine`.

On a fresh `Cluster` (rebuild, or the CNPG PVC lost): Flux recreates it
empty, with the extensions; restore as above. The dump holds no roles, and
`--no-owner` makes the app role the owner.

- **Blobs:** the NAS snapshots, `.zfs/snapshot/<name>/affine/` under
  `/mnt/slow/k8s-csi`. Scale to 0, copy back, scale up.

**Verify.**

```sh
kubectl -n affine rollout status deploy/affine
kubectl get clusters.postgresql.cnpg.io -n affine     # affine-pg healthy
kubectl -n affine get cronjob postgres-dump           # LAST SCHEDULE within a day
```

Then log in through Pocket ID: your workspace is there, and an older doc's
image loads. `AffineDumpStale` stays quiet after the next night's dump.

## Admin

**First deploy.**

1. In Pocket ID: *Administration -> OIDC Clients -> Add*. Name `AFFiNE`,
   callback URL `https://affine.<app_domain>/oauth/callback`, allowed groups
   `admins`, `household`.
2. Client id and secret into `secrets/vault.yml` as `affine_oidc_client_id` /
   `affine_oidc_client_secret`, then `mise run platform init` (the `tls`
   provider is new) and `mise run platform apply`.
3. Make `/mnt/slow/k8s-csi/affine` on the NAS (see
   [machines/truenas.md](../build/machines/truenas.md)).
4. Merge; Flux deploys.
5. Open `https://affine.<app_domain>/admin` and create the admin account
   **first** -- until then anyone who reaches the URL can. Use an email no
   Pocket ID user has, or that user's SSO login lands on the admin.

**Users.** Each Pocket ID user needs an email, **marked verified** in Pocket
ID (*Users -> edit*): with no SMTP nobody can verify by mail, and AFFiNE
refuses a login whose `email_verified` is false.

**What git owns** (`apps/affine/secret.yaml`'s `config.json`, read at start):

- the Pocket ID provider
- email signup off, signup through SSO on
- no guest demo workspaces; AI off

The admin panel (*Settings*) can change these too, into the db. Change them
in git instead. After changing the file:
`kubectl -n affine rollout restart deploy/affine` (ESO refreshes hourly;
force with `kubectl -n affine annotate es affine-config force-sync=$(date +%s) --overwrite`).

**Updates.** Image tag pinned in `server.yaml`, both containers; Renovate
proposes bumps (see [Maintenance](../maintenance.md)). The initContainer
migrates before the new server starts. The postgres image in `database.yaml`
and the dump's in `dump.yaml` track the same major (17): Renovate bumps them
in one `affine postgres` PR, and holds a major for approval on the dependency
dashboard -- merging it is a CNPG in-place major upgrade (see
[Maintenance](../maintenance.md#renovate)).

### Not enabled

- **SMTP.** No mail anywhere in the lab: no magic links, no emailed invites
  (share links work).
- **AI** (`copilot`). Needs a provider key; pgvector is already there.
- **Search indexer** (Manticore). Search runs client-side.
- **Metrics.** AFFiNE exposes none worth scraping; `/info` is the probe.

## Ending the trial {#ending-the-trial}

One of AFFiNE and [Memos](memos.md) goes. Data does not migrate between them
-- move what you keep by hand (AFFiNE imports Markdown).

**AFFiNE wins, and takes `notes.`** -- delete Memos first (below): the
hostname can be on only one route.

1. `apps/affine/route.yaml`: hostnames `notes.${app_domain}` **and**
   `affine.${app_domain}` for a while, so old links keep working.
   `secret.yaml`: `externalUrl` to `https://notes.${app_domain}`.
2. Pocket ID client `AFFiNE`: callback `https://notes.<app_domain>/oauth/callback`
   (Pocket ID accepts several; keep the old one until step 1's second
   hostname goes).
3. `apps/glance/glance.yml`: the bookmark's URL. Docs: this page, the
   [Workloads](index.md) table.
4. Restart the Deployment (the config is read at start).

What it invalidates: **everyone logs in again** (the session cookie is per
host); **share and invite links** already sent point at `affine.` -- they
work while it is still on the route; **AFFiNE desktop/mobile apps** connected
to `affine.` add the new server and sign in again. Nothing else: accounts
(linked by email), docs, blobs, the signing key and DNS/TLS (a wildcard)
are untouched.

**Deleting the loser.** Either app:

1. `flux/apps/<app>/`, `flux/apps/<app>.yaml`, its line in
   `apps/kustomization.yaml`, its Glance bookmark, `flux/docs/<app>.md`.
   Flux prunes the namespace. AFFiNE: also the two `apps/affine/**` rules in
   `flux/renovate.json`.
2. `platform/`: its `vault_kv_secret_v2` (and `random_password` /
   `tls_private_key`), its `*_oidc_client_*` variables, their line in
   `scripts/tofu.sh` and the `platform/README.md` table; then `mise run
   platform apply`. AFFiNE: drop the `tls` provider from `versions.tf` too if
   nothing else uses it. Remove the keys from `secrets/vault.yml`.
3. Pocket ID: delete its OIDC client.
4. Its restic repository on Garage:
   ```sh
   mise run s3 volsync rm --recursive s3://k8s-backups/<app>/
   ```
   (`memos/memos-data` or `affine/postgres-dump`).
5. The static PV is `Retain`: delete the PV, then on the NAS
   `/mnt/slow/k8s-csi/memos` or `/mnt/slow/k8s-csi/affine`.
6. Docs: its workload page and every row naming it -- `grep -ri <app> docs/src
   machines`. AFFiNE: [CloudNativePG](../platform/cloudnative-pg.md) goes back
   to having no `Cluster`.

## Gotchas

- **Accounts are linked by email.** Changing a user's email in Pocket ID
  gives them a new, empty account.
- **Losing `kv/affine/app`'s `private-key`** (a new tofu state) logs everyone
  out and loses what AFFiNE encrypted with it.
- **Deleting the app** leaves its restic repository and NAS directory --
  see [Ending the trial](#ending-the-trial).
- **One pod, `Recreate`.** One migrator at a time.
