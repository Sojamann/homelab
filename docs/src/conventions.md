# Conventions

## Placeholders

Both repos are public, so no domain is written anywhere. The pages use
placeholders; the real values live in `secrets/vault.yml`.

| Placeholder | Means | Real value from |
|--|--|--|
| `<zone>` | the DNS zone, e.g. `example.com` | vault key `zone` |
| `<lab_domain>` | `lab.<zone>`: physical hosts, VMs, the NAS | derived from `zone` by `scripts/tofu.sh` |
| `<app_domain>` | `app.<zone>`: everything behind the cluster's gateway | derived from `zone` by `scripts/tofu.sh` |
| `<tailnet>` | the tailnet's MagicDNS suffix, e.g. `tail1234.ts.net` | vault key `tailnet_domain` |

`zone` is the one deployment-specific value: every name in the lab is built
from it. It sits in the vault not because it is secret but so that there is
one hiding place.

How each tool gets the value:

| Where | Written as | Filled by |
|--|--|--|
| tofu layers | `var.lab_domain`, `var.app_domain`, `var.tailnet_domain` | `scripts/tofu.sh` exports `TF_VAR_*` from the vault |
| `flux/` manifests | `${lab_domain}`, `${app_domain}`, `${tailnet_domain}`, `${telegram_chat_id}` | Flux `postBuild` substitution from `Secret/cluster-vars` in `flux-system`, written by the platform layer |
| `mise run s3`, `mise run image` | -- | read `zone` from the vault directly |

To see a real value (it never goes into a committed file):

```sh
. scripts/lib.sh
vault_require secrets/vault.yml zone
kubectl -n flux-system get secret cluster-vars -o jsonpath='{.data.app_domain}' | base64 -d
```

Other placeholders are what they say: `<ns>`, `<pvc>`, `<name>`, `<id>`,
`<tag>`, `<version>`.

## Written out

- **IP addresses** -- they are private and stable, and an address in a page is
  faster than a lookup mid-outage.
- **Guest ids encode the address.** `10.212.2.160` is VM `160`,
  `10.212.4.10` is VM `4010` (third octet leads once it is not `2`). The MAC
  follows: `BC:24:11:00:01:60`, `BC:24:11:00:04:10`. A convention, nothing
  enforces it -- but the cluster layer relies on it.
- **Hostnames** are Saturn's moons: titan, enceladus, mimas, rhea, iapetus,
  dione.

## Vault keys

- One file, `secrets/vault.yml`; `secrets.example.yml` is the public template
  with a comment per key. The full list of keys and what wants each is there.
- **Values unquoted.** `scripts/lib.sh` reads each line raw, so quotes and
  trailing comments become part of the value.
- Garage keys are `garage_<name>_key_id` / `garage_<name>_secret_key`, which
  is what `mise run s3 <name>` reads.
- Pocket ID clients configured from tofu: `<app>_oidc_client_id` /
  `<app>_oidc_client_secret`.

## OpenBao paths

`kv/<namespace>/<app>[/<key>]`, all written from one file,
`platform/platform_secrets.tf`. See [Access & secrets](access.md#openbao).

## Alert rules

Every rule the lab adds carries the label `origin: lab`, which the ~134 rules
the chart ships do not: `origin="lab"` in Alertmanager, `label:origin=lab` in
Grafana. See [Monitoring](monitoring.md).

## Commits

A change touching `flux/` or `secrets/` is committed with
`mise run save "<msg>"` -- it commits the submodules first, then this repo,
and notes the parent commit on the submodule's. See
[Access & secrets](access.md#committing-across-both-repos).

## On these pages

- Repo files are named in backticks, relative to the repo root (`flux/...`
  for the apps repo).
- Commands run from the repo root: `mise` sets `KUBECONFIG` and `TALOSCONFIG`
  to `secrets/kubeconfig` and `secrets/talosconfig`.
- **Last verified** dates on restore procedures say when they were last
  actually run.
