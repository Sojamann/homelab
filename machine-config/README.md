# Machine Config

Ansible configures the machines. The [guests](../guests/README.md) layer then
builds on top: **Ansible owns host state, Terraform owns what runs on the
hosts.**

Assumes [machines](../machines/README.md) is complete: the node is installed,
reachable over SSH with a key, and already a member of a quorate cluster.

## Running it

```sh
mise run machine-config
mise run machine-config -- --limit mimas
```

`inventory/` is a plain, committed ansible inventory. Machines that do not
exist yet stay commented out in `hosts.yml`.

### Secrets

`secrets/vault.yml` is an ansible-vault file shared by every stage; the
password lives in the gitignored `secrets/.vault-pass`. Start from
`secrets.example.yml`:

```sh
cp secrets.example.yml secrets/vault.yml
$EDITOR secrets/vault.yml
ansible-vault encrypt secrets/vault.yml
```

`secrets/proxmox-token.yml` is written by the playbook and holds the guests
API token secret, vault-encrypted. It is committed, so a fresh clone still has
the value.

## What the proxmox role does

| Step | Notes |
|------|-------|
| Assert cluster membership | Fails loudly if a node was never joined |
| Disable enterprise repos | `pve-enterprise` **and** `ceph`, set `Enabled: no` rather than deleted -- an upgrade can recreate the file |
| Add `pve-no-subscription` | deb822, since PVE 9 is Debian 13 |
| `dist-upgrade` | `apt upgrade` would hold back PVE updates and half-upgrade the node |
| Remove the subscription nag | Reapplied every run; every `pve-manager` upgrade reverts it |
| VLAN-aware `vmbr0` | Required for VMs tagged onto VLAN 40 (k8s); the default bridge silently drops tags |
| Per-host NIC quirks | `ethtool` settings that work around driver bugs, applied by a systemd unit bound to the device. Empty unless a host sets `nic_quirks` -- see [known hardware quirks](#known-hardware-quirks) |
| Single-pool storage | `local` holds guest disks, ISOs, templates, backups and cloud-init snippets; an unused `local-lvm` is removed. The disk itself is never repartitioned -- see [machines](../machines/proxmox.md) |
| ACME certificate | Proxmox's built-in client, DNS-01 via Cloudflare. **Proxmox owns renewal** -- nothing here watches it |
| API user + token | The identity guests uses; secret captured into the vault |
| Metrics exporters | `prometheus-node-exporter` from apt, `pve-exporter` from PyPI in `/opt/pve-exporter` -- Debian does not package it. Both bind the host address; the exporter's `PVEAuditor` token stays in `/etc/prometheus/pve.yml` on the host. Scraped from the cluster, see [flux/docs/monitoring.md](../flux/docs/monitoring.md) |

Anything in `/etc/pve` is replicated cluster-wide, so those steps (ACME
account, DNS plugin, API user/token) run **once**, against `cluster_primary`.

## Reboots

A host reboots automatically only on its **first** run, tracked by
`/etc/lab/.stage1-initialized` on the host itself. Re-running the playbook
after adding a new machine therefore reboots only the new machine. An
already-initialised host reports a pending reboot instead:

```sh
mise run machine-config -- -e reboot_ok=true
```

## Known hardware quirks

| Host | Quirk |
|------|-------|
| titan | Onboard Intel I219 (`e1000e`) wedges its TX DMA engine under TSO/GSO and EEE, taking the host off the network with the link still up. The driver never resets the adapter, so only a power cycle recovers it. `nic_quirks` disables all three. **Unproven** -- still under observation |

## Known trade-offs

- Tasks shell out to `pveum` / `pvenode` / `pvesh` rather than using API
  modules: there is no module coverage for ACME, apt repos or `pvecm`, so the
  collection would have bought idempotency for one task in exchange for a
  Python dependency and a bootstrap paradox (an API token to create the API
  token). Idempotency is hand-guarded instead.
- There is no verification play. A silently failed certificate renewal or a
  nag patch reverted by an upgrade will not announce itself.
- Per-node certificates publish node hostnames to public Certificate
  Transparency logs.
