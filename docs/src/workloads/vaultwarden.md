# Vaultwarden

## What it's for

The household's password manager. Bitwarden-compatible server: the official
Bitwarden apps and browser extensions talk to it. How to use them is
upstream: [Bitwarden help](https://bitwarden.com/help/).

## Access

- **URL:** `https://passwords.<app_domain>` -- set as the *server URL* in each
  client (*self-hosted*).
- **Reachability:** LAN and tailnet, like everything behind the gateway. Not
  public. See [Networking](../networking.md).
- **Login:** email + master password, then a passkey as 2FA. No SSO.
- **Admin:** `https://passwords.<app_domain>/admin`, with the admin token
  (plaintext in the password managers -- see [Admin token](#admin-token)).

## Where it runs

Namespace `vaultwarden`, one Deployment, Flux Kustomization `vaultwarden`.
Wiring: [Build guide: Vaultwarden](../build/flux/docs/vaultwarden.md).

## Data

One `fast` PVC, `vaultwarden-data` (1Gi), mounted at `/data`:

| Path | What | State? |
|--|--|--|
| `db.sqlite3` (+ `-wal`, `-shm`) | users, vault items (client-side encrypted), orgs | **yes** |
| `rsa_key.pem` | signs login tokens; lost = every session logged out | **yes** |
| `attachments/`, `sends/` | file attachments, Sends | **yes** -- only in the backup |
| `config.json` | settings saved in `/admin`; overrides env | **yes** |
| `icon_cache/` | website icons | no, refetched |

Not state: the admin token hash (OpenBao, from `secrets/vault.yml` via
tofu) and everything in the manifests.

1Gi is plenty for the db and icons; attachments are what grows.
`KubePersistentVolumeFillingUp` warns first. To grow, raise the request in
`storage.yaml` -- `fast` allows expansion.

## Backup & restore

Covered by [VolSync](../backups.md#volsync): nightly `00:15` UTC, retain
daily 14, weekly 8, monthly 6. Not by ZFS snapshots (`fast` has none). The
vault items also survive in every logged-in client's offline cache;
attachments and Sends only in the backup.

**Restore.** The generic [VolSync restore](../backups.md#volsync), with:

```sh
NS=vaultwarden KS=vaultwarden DEPLOY=vaultwarden PVC=vaultwarden-data MOVER_UID=1000
```

Before restoring an **older** snapshot over a working instance, export the
vault from a client that still has the newer items: the next sync replaces every client's cache with the restored
server state, and anything newer is gone from all of them.

**Verify.**

```sh
kubectl -n vaultwarden rollout status deploy/vaultwarden
kubectl -n vaultwarden logs deploy/vaultwarden | tail
```

Then in a browser: log in to the web vault, open a recent item and an
attachment; in `/admin` -> *Users*, every account is listed with its last
activity. A client that was logged in before the restore should sync
without asking for the master password again -- if it does ask,
`rsa_key.pem` did not come back.

## Admin

**Accounts.** No signups and no SMTP (`SIGNUPS_ALLOWED=false`,
`INVITATIONS_ALLOWED=true`), so an account exists only for an email you
invited.

To add someone: `/admin` -> *Users* -> *Invite user* with their email. No
mail goes out; tell them to register at the login page with exactly that
address. They set a master password and enroll a passkey as 2FA: *Settings*
-> *Security* -> *Two-step login* -> *FIDO2 WebAuthn*.

**The master password is the vault's encryption key.** Forgotten, that vault
is gone: `/admin` can delete the account, never open it. Lost 2FA: the
user's recovery code, or `/admin` -> *Users* -> *Remove all 2FA*.

### Admin token {#admin-token}

`/admin` takes the plaintext; the app reads only its argon2id hash from
`ADMIN_TOKEN`. The plaintext lives in the other password managers -- not only in
Vaultwarden itself, or a broken Vaultwarden locks out its own recovery. The hash sits in
`secrets/vault.yml` as `vaultwarden_admin_token_hash`, from where
`platform_secrets.tf` writes it to OpenBao at `kv/vaultwarden/app`.

Set or rotate:

```sh
docker run --rm -it docker.io/vaultwarden/server:<tag> /vaultwarden hash
ansible-vault edit secrets/vault.yml      # vaultwarden_admin_token_hash: $argon2id$... (unquoted)
mise run platform apply
kubectl -n vaultwarden annotate externalsecret vaultwarden force-sync=$(date +%s) --overwrite
kubectl -n vaultwarden rollout restart deploy/vaultwarden   # env is read at start
```

Then commit with `mise run save "vaultwarden: rotate admin token"`.

### Not enabled

- **SSO via Pocket ID.** With password login kept as break-glass it adds
  convenience, not security. Later: a Pocket ID client, `SSO_ENABLED`,
  `SSO_AUTHORITY=https://login.<app_domain>`, the client id/secret through
  OpenBao.
- **Mobile push.** Phones sync on open and periodically instead. Later:
  installation id/key from `bitwarden.com/host`, `PUSH_ENABLED`.

### Updates

The image tag is pinned in `server.yaml`; Renovate proposes bumps (see
[Maintenance](../maintenance.md)). Database migrations run on start, so a
bump is not undone by reverting the tag -- the way back is a
[restore](#backup--restore).

## Gotchas

- **`DOMAIN` is load-bearing.** WebAuthn credentials are bound to
  `https://passwords.<app_domain>`; changing it orphans every user's passkey
  2FA.
- **Settings saved in `/admin` win over env.** They land in
  `/data/config.json`; changing the same setting in `server.yaml` then does
  nothing. Remove it from `config.json` (or reset it in `/admin`) first.
- **One pod, `Recreate`.** SQLite has one writer and the volume is RWO, so a
  rollout is a few seconds of downtime. Clients keep working offline.
- **Large uploads need `timeout 0s`** on the HTTPRoute. Envoy's 15s default
  cuts off big attachments.
- **Login rate limits see the real IP** only because `IP_HEADER` is
  `X-Forwarded-For`, which Envoy appends.
