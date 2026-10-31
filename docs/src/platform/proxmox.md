# Proxmox

## What it's for

The hypervisor. Runs every VM in the lab: the Talos node, the VPN router,
PBS and Home Assistant. One node today, `titan`, in a Proxmox cluster named
`lab`. The NAS is not on it.

## Access

- **UI:** `https://titan.<lab_domain>:8006`. Trusted and tailnet (admins).
  See [Networking](../networking.md).
- **Login:** realm `pocket-id` (default), group `admins` -> `admins-pocket-id`
  -> *Administrator* on `/`. Users are autocreated at first login.
- **Shell:** `ssh root@10.212.2.151`, with your own key -- the only credential
  the automation uses.
- **API:** token `terraform@pve!provisioner` (role `TerraformProv`), in
  `secrets/proxmox-token.yml`. Used by the guests and cluster layers.
- **Break-glass:** `root@pam` in the UI, or the node's console. Its password
  deliberately is not in the repo; it is in the password managers.

## Where it runs

Bare metal: `titan`, `10.212.2.151`, Proxmox VE 9. `cluster_primary` in
`guests/guest_nodes.tf` and `machine-config/inventory/group_vars/proxmox.yml`.
Build: [Build guide: Proxmox](../build/machines/proxmox.md), host state
[Build guide: Machine config](../build/machine-config/README.md).

| VM | Guest |
|--|--|
| 160 | [VPN](vpn.md) |
| 161 | [Home Assistant](../workloads/home-assistant.md) |
| 162 | [PBS](pbs.md) |
| 4010 | [Talos](talos.md) `talos-cp-1` |

## Data

- **`local`** -- the one storage: guest disks (qcow2), ISOs, templates,
  cloud-init snippets. On the node's own disk, no redundancy. Installed with
  `maxvz=0` and `maxroot` = disk size, so there is no `local-lvm`.
- **`/etc/pve`** -- cluster config: storage entries (`pbs-s3`), the backup job,
  the `pocket-id` realm, ACME account and plugin, users and tokens.
  Replicated across nodes, of which there is one.
- **`/etc/prometheus/pve.yml`** -- pve-exporter's `PVEAuditor` token.

Not state: everything machine-config converges (repos, bridge, exporters,
NIC quirks), and the VMs themselves (PBS has them).

## Backup & restore

The host is **not backed up** -- see [Not covered](../backups.md#not-covered).
The VMs are, by [PBS](../backups.md#pbs).

**Dead node.** Reinstall, `mise run machine-config`, then PBS first and the
VMs from it: [PBS, *Dead node*](../backups.md#pbs). Not covered by those
steps: the `pocket-id` realm -- redo it as below.

**Verify.**

```sh
pvecm status            # Quorate: Yes
qm list                 # 160, 161, 162, 4010 running
pvesm status            # local and pbs-s3 active
```

## Admin

**Adding a node.** [Build guide: Proxmox](../build/machines/proxmox.md):
install, `ssh-copy-id`, `pvecm add`, then the node in
`machine-config/inventory/hosts.yml`, `network/unifi_dns.tf`,
`guests/guest_nodes.tf` (if it stores guests),
`flux/infrastructure/configs/proxmox/scrape.yaml`, and a callback on the
Pocket ID `proxmox` client. At two nodes quorum needs both; aim for three.

**Pocket ID realm.** Once per cluster, after machine-config. Client `proxmox`
in Pocket ID (confidential, PKCE off, one callback per node
`https://<node>.<lab_domain>:8006`, group `admins`); then the `pveum` commands
in [Build guide: Proxmox](../build/machines/proxmox.md#pocket-id-login).
Groups overwrite on login: leaving `admins` removes the rights next time.

**API token.** Proxmox shows a token's secret once. If
`secrets/proxmox-token.yml` is lost, `mise run machine-config` mints a new one
and re-encrypts the file.

**Certificate.** Proxmox's own ACME client, DNS-01 via the Cloudflare plugin,
set up by machine-config. Proxmox renews it; nothing watches it. The
Cloudflare token is the same one cert-manager uses -- rotating it is two places.

**Updates.** By hand: `apt full-upgrade`, or `mise run machine-config`,
which runs `dist-upgrade`; a reboot happens only on a
host's first run, otherwise `-e reboot_ok=true`. See
[Maintenance](../maintenance.md).

**Monitoring.** node-exporter `:9100` and pve-exporter `:9221` on the Trusted
address, scraped through `metrics-allow-proxmox`. Alerts:
`ProxmoxExporterDown`, `ProxmoxQuorumLost`, `ProxmoxStorageFull`,
`ProxmoxGuestDown`. See [Monitoring](../monitoring.md).

## Gotchas

- **`pvecm create` once for the whole lab, ever.** Running it on a second node
  makes two one-node clusters. A node joins only while it has no VMs.
- **The subscription nag comes back** with every `pve-manager` upgrade;
  machine-config removes it again on the next run.
- **titan's onboard NIC (`e1000e`) wedges** under TSO/GSO and EEE: host off the
  network, link still up, only a power cycle helps. `nic_quirks` disables all
  three; unproven, under observation.
- **`vmbr0` must be VLAN-aware**, or VMs tagged onto VLAN 40 (Talos) get no
  traffic. machine-config sets it.
- **Per-node certificates** publish the node names to public CT logs.
- **A guest boots only from an image on its own node**: every image is
  downloaded to every node.

## What breaks without it

Every VM: the cluster and every workload on it, remote access (VPN), VM
backups (PBS), Home Assistant. The NAS keeps serving: SMB, Time Machine,
Garage.
