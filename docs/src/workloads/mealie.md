# Mealie

## What it's for

The household's recipes, meal plan and shopping list. Recipes come in by URL
(Mealie scrapes the page) or by hand. Using it is upstream:
[Mealie docs](https://docs.mealie.io).

## Access

- **URL:** `https://recipes.<app_domain>`. LAN and tailnet; not public. See
  [Networking](../networking.md).
- **Login:** straight to Pocket ID (auto-redirect). The first login creates
  the account, matched by **email** -- each user needs a verified email in
  Pocket ID, or Mealie refuses the login. Who may log in is the Pocket ID
  client's allowed groups, `admins` + `household`; `admins` are admins here
  too, re-read every login. Sessions last about a week (remember-me).
- **No break-glass account.** The default admin is deleted at first deploy,
  and the password form is hidden.

### Getting in without Pocket ID {#break-glass}

The form is hidden, but the API still takes passwords. Give your own account
a local password, then log in through a password-enabled pod:

```sh
kubectl -n mealie exec -it deploy/mealie -- \
  python /app/mealie/scripts/change_password.py
# your email; answer `y` to "change your authentication method back to local"
flux suspend ks mealie        # else Flux reverts the env within 10m
kubectl -n mealie set env deploy/mealie ALLOW_PASSWORD_LOGIN=true
```

Log in at `https://recipes.<app_domain>/login?direct=1` (skips the redirect).
When Pocket ID is back, `flux resume ks mealie` reverts the env; your next
SSO login re-links the account by email.

Lost admin rights (e.g. removed from `admins` by mistake):
`python /app/mealie/scripts/make_admin.py` the same way.

## Where it runs

Namespace `mealie`, one Deployment, Flux Kustomization `mealie`.
Wiring: [Build guide: Mealie](../build/flux/docs/mealie.md).

## Data

| Volume | What | Storage | State? |
|--|--|--|--|
| `mealie-data` -> `/app/data` | `mealie.db` (SQLite): recipes, users, households, meal plans, lists; `recipes/` images; `.secret` + `.session_secret` (token signing) | `fast`, 5Gi | **yes** |

Losing the two secret files only logs everyone out. `backups/` holds Mealie's
own zips -- none are scheduled; a manual one is swept into restic with the
rest, so delete it when done.

Not state: the Pocket ID client (OpenBao) and the settings (env in
`apps/mealie/server.yaml`).

## Backup & restore

- **Everything:** [VolSync](../backups.md#volsync), nightly `01:30` UTC,
  retain daily 14, weekly 8, monthly 6.

**Restore.** The generic [VolSync restore](../backups.md#volsync), with:

```sh
NS=mealie KS=mealie DEPLOY=mealie PVC=mealie-data MOVER_UID=1000
```

**Verify.**

```sh
kubectl -n mealie rollout status deploy/mealie
kubectl -n mealie logs deploy/mealie | grep -iE 'error|oidc'
```

Then log in through Pocket ID: the recipes are there, and an older recipe's
image loads.

## Admin

**First deploy.**

1. In Pocket ID: *Administration -> OIDC Clients -> Add*. Name `Mealie`,
   callback URL `https://recipes.<app_domain>/login`, allowed groups
   `admins`, `household`. Check each of those users has an email, marked
   verified.
2. Client id and secret into `secrets/vault.yml` as `mealie_oidc_client_id` /
   `mealie_oidc_client_secret`, then `mise run platform apply`.
3. Merge; Flux deploys.
4. Log in through Pocket ID as a member of `admins`. A setup wizard opens --
   Mealie shows it to admins while its seeded user exists. Skip it (*already
   set up, bring me to the homepage*): its account step edits *your* SSO
   user, and a changed email breaks the link.
5. In *Admin -> Users*, delete `changeme@example.com` -- Mealie seeds it with
   the password `MyPassword`, and the API accepts it until it is gone. The
   wizard goes with it.

**Adding another household** (say, parents: shared recipes, their own meal
plan and shopping list):

1. A Pocket ID group (`parents`), added to the client's allowed groups.
2. They log in once; Mealie puts every SSO signup in group `Home`, household
   `Family` -- it cannot map Pocket ID groups to households.
3. *Admin -> Households -> Create* `Parents`, then *Admin -> Users*: move them
   into it.

**What git owns** (env in `server.yaml`): base URL, Pocket ID, auto-redirect,
remember-me, `admins` -> admin, signup through SSO only, password form
hidden, `TZ=Europe/Berlin` (meal-plan "today", daily jobs). Everything else
-- households, labels, each user's settings -- is the UI's, in the db.

**Updates.** Image tag pinned in `server.yaml`; Renovate proposes bumps (see
[Maintenance](../maintenance.md)). Migrations run on start; read the release
notes for a major.

### Not enabled

- **Metrics and alerts.** Mealie exposes no metrics.
- **SMTP.** The lab has none; with SSO, password-reset and invite mails have
  nothing to do.
- **AI features** (import from a photo, ingredient parsing through an
  OpenAI-compatible API). They would need a key in OpenBao and send recipes
  out. Adding it: a property in `kv/mealie/app` and `OPENAI_*` env.
- **Mealie's own backups.** Not scheduled upstream; VolSync covers the volume.

## Gotchas

- **Changing a user's email in Pocket ID gives them a new, empty account**
  here: email is the SSO link key. Change it in both, or not at all.
- **No verified email, no login.** Mealie checks `email_verified`.
- **One pod, `Recreate`.** SQLite has one writer and the data volume is RWO.
