# Bootstrap (manual)

The chicken-and-egg layer. Everything here has to exist before any automation
can run, and every piece of it is either in someone else's UI or needs a
credential that deliberately does not live in this repo.

This happens once in the lab's lifetime. Adding a machine later does not come
back here -- that is [machines](../machines/README.md).

## Order

1. **UniFi controller.** Gateway and switches racked, powered, adopted, an
   admin account created. The default LAN is enough; the real topology is
   [network](../network/README.md)'s job, and it needs a controller to talk to
   before it can build anything. While you are in there, create the API key it
   authenticates with -- *Control Plane -> Admins & Users*, on a limited admin
   with local access only. It is shown exactly once.
2. **[Cloudflare](./cloudflare.md)** -- the zone and a scoped API token.
   machine-config orders a certificate on its first run and fails without it.
3. **[Workstation](./workstation.md)** -- toolchain and SSH reachability. Every
   later layer runs from here, not from the machines.

## Done when

- the UniFi controller is reachable from your workstation
- `secrets/vault.yml` exists and holds every key the layers below want:

  | Key                          | Wanted by       | Notes                          |
  |------------------------------|-----------------|--------------------------------|
  | `zone`                       | every layer     | the DNS zone, no `lab.` prefix |
  | `acme_email`                 | machine-config  | certificate registration       |
  | `cloudflare_api_token`       | machine-config, platform | DNS-01, scoped to the one zone |
  | `terraform_state_passphrase` | network         | 16+ chars, see below           |
  | `unifi_api_key`              | network         | from step 1                    |
  | `wifi_trusted_ssid`          | network         | the name, see below            |
  | `wifi_iot_ssid`              | network         | the name, see below            |
  | `wifi_trusted_passphrase`    | network         | PSK                            |
  | `wifi_iot_passphrase`        | network         | PSK                            |

  `zone` is not a secret in the usual sense -- it is here because it is the one
  deployment-specific value, and one hiding place beats two.
  `*_ssid` values are in here due to SSIDs being able to leak locations

`mise run network` refuses to start until every key it needs is present, and
says which one is missing rather than failing inside tofu.

## Secrets

`secrets/vault.yml` is an ansible-vault file shared by every layer; the
password lives in the gitignored `secrets/.vault-pass`. Start from
`secrets.example.yml`:

```sh
cp secrets.example.yml secrets/vault.yml
$EDITOR secrets/vault.yml
ansible-vault encrypt secrets/vault.yml
```

`terraform_state_passphrase` is the one entry with no second copy anywhere.
The network layer's state is committed to this repo encrypted with it, so
losing it makes that state unreadable in git history as well as in the working
tree, and the only recovery is to rebuild state from the controller by hand.
Keep it in a password manager too. It is also exactly as strong as the vault
password protecting it.

Nothing outside this file is a credential. There are no passwords in the repo,
SSH is key-only, and cluster formation stays manual precisely because `pvecm`
wants root@pam's password.
