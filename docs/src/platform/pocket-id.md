# Pocket ID

## What it's for

The lab's OIDC provider, passkeys only. An extra way in, not the only one:
every app that uses it keeps its own admin login as break-glass, so Pocket ID
being down locks nobody out.

## Access

- **URL:** `https://login.<app_domain>`. LAN and tailnet; not public.
- **Login:** passkey. New users get a one-time login link and enroll one.
- **Admin UI:** the same app, signed in as an admin user.
- **Break-glass** (your own admin passkey lost):
  ```sh
  kubectl -n pocket-id exec deploy/pocket-id -- /app/pocket-id one-time-access-token <username>
  ```
  Works despite the distroless image: the binary is called directly.

## Where it runs

Namespace `pocket-id`, one Deployment (`Recreate`, uid 1000), Service `:1411`,
HTTPRoute `login.<app_domain>`. In `flux/infrastructure/controllers/pocket-id/`,
so its Flux Kustomization is `infrastructure`; the backup is in
`infrastructure/configs/pocket-id/`.
Wiring: [Build guide: Pocket ID](../build/flux/docs/pocket-id.md).

## Data

One `fast` PVC, `pocket-id-state` (1Gi), at `/app/data`: `pocket-id.db`
(SQLite, WAL) -- users, passkeys, groups, clients, signing keys -- and uploads.

**The encryption key** encrypts the signing keys in the database. Generated in
`platform_secrets.tf`, delivered from `kv/pocket-id/app`. The tofu state is
its only backup; without it the database is unreadable.

## Backup & restore

[VolSync](../backups.md#volsync), nightly `00:45` UTC, retain daily 14,
weekly 8, monthly 6. The key: [Secrets repo](../backups.md#secrets-repo).

**Restore.** The generic [VolSync restore](../backups.md#volsync), with:

```sh
NS=pocket-id KS=infrastructure DEPLOY=pocket-id PVC=pocket-id-state MOVER_UID=1000
```

Suspending `infrastructure` suspends every controller in that tier for the
duration -- resume it promptly.

**Verify.**

```sh
kubectl -n pocket-id rollout status deploy/pocket-id
kubectl -n pocket-id logs deploy/pocket-id | tail
```

Then log in with a passkey; in the admin UI every user and client is listed;
an SSO login to Grafana works (proves the signing keys decrypted).

**Without a backup:** every passkey enrolled again and every client
re-registered; `/setup` creates the first admin again.

## Admin

**First start.** `/setup` creates the first admin -- whoever opens it first.
Do it right after the first deploy.

**Users.** No signups, no SMTP. Created in the admin UI, then a one-time login
link per person. A lost passkey: a new link.

| Group | Meaning |
|--|--|
| `admins` | admin in the apps that map it |
| `household` | everyone else |

**Clients.** Registered by hand in the admin UI. The secret goes to OpenBao
only where the app reads OIDC settings from config: vault ->
`platform_secrets.tf` -> `kv/<ns>/<app>` -> `ExternalSecret`. A lost client
secret costs a re-registration, not access.

| Client | Groups | Configured in | Break-glass |
|--|--|--|--|
| Grafana | `admins`, `household` | [Monitoring](../monitoring.md) | admin form |
| OpenBao | `admins` | `platform_openbao.tf`, see [OpenBao](openbao.md) | root token |
| Proxmox | `admins` | by hand, see [Proxmox](proxmox.md) | `root@pam` |
| PBS | `admins` | by hand, see [PBS](pbs.md) | `root@pam` |

TrueNAS and Vaultwarden do not use it.

**Updates.** Image tag pinned in `server.yaml`; Renovate proposes bumps.

## Gotchas

- **`APP_URL` is load-bearing.** Passkeys are bound to
  `https://login.<app_domain>`; changing it orphans every one.
- **One pod, `Recreate`** -- SQLite, RWO. A rollout is seconds of downtime.
- **`TRUST_PROXY=true`** only affects the client IP in the audit log.
- **The backup lives in `configs/`, not beside the app**: the app is in the
  same tier as the VolSync chart, and a CR cannot be applied in the same pass
  as the chart that defines its kind.

## What breaks without it

SSO logins to Grafana, OpenBao, Proxmox and PBS -- each falls back to its
break-glass login (table above). Nothing else; apps without SSO are
unaffected.
