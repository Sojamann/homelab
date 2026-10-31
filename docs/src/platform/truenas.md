# TrueNAS

## What it's for

The NAS: every byte of state in the lab that is not on a VM disk. Storage for
the cluster (`fast` over NVMe-oF, `bulk` over NFS), the household's SMB shares
and Time Machine, and two apps of its own: **Garage** (S3, the target of every
backup) and **node-exporter** (metrics). Configured by hand in the UI, and
stays that way.

## Access

- **UI:** `https://nas.<lab_domain>`. Trusted and tailnet (admins); also
  reachable from k8s, because the UI shares a listener with the API the CSI
  driver calls.
- **Login:** `admin`, a local sudo user. No SSO: TrueNAS has no OIDC login.
- **Shell:** `ssh admin@nas.<lab_domain>` on Trusted, or UI *System* -> *Shell*.
- **Break-glass:** the built-in `truenas_admin`. Both passwords are in the
  password managers.
- **Garage CLI**, in a NAS shell:
  ```sh
  alias garage='docker exec ix-garage-garage-1 /garage'
  garage status
  ```
  Admin API `https://s3.<lab_domain>:3903`, `garage_admin_token`. From k8s
  only `/metrics` answers.

## Where it runs

Bare metal: UGREEN NASync DXP4800 GT, TrueNAS on the onboard eMMC.

| Interface | Address | For |
|--|--|--|
| Trusted | `10.212.2.150` | UI, SMB, SSH, Garage S3 + admin |
| k8s (VLAN 40) | `10.212.4.150`, no gateway | API, NVMe-oF `:4420`, NFS, Garage S3, node-exporter `:9100` |

Build: [Build guide: TrueNAS](../build/machines/truenas.md). The apps'
compose files: `machines/truenas/apps/garage/compose.yaml`,
`machines/truenas/apps/node-exporter/compose.yaml`.

## Data

| Pool | Disks | Holds |
|--|--|--|
| `fast` | 1x 500G NVMe, **no redundancy**, encrypted | `fast` PVCs (zvols), owned by democratic-csi |
| `slow` | 2x 4TB HDD mirror, encrypted | everything below |

| Dataset | What | Consumer |
|--|--|--|
| `slow/k8s-csi` | one directory per `bulk` PV, plus static `syncthing/` | NFS, csi-driver-nfs |
| `slow/garage/{meta,data}` | Garage LMDB and blocks, quota 1T | Garage |
| `slow/ha-backups` | Home Assistant's own backups | SMB, user `ha-backup` |
| `slow/node-exporter` | textfile metrics, rewritten every minute | node-exporter |
| `slow/users/<name>/files` | a person's share | SMB |
| `slow/users/<name>/time-machine` | one Mac's backups | SMB, TM preset |

Classes, PVC paths and the CSI side: [Storage](../storage.md).

| Bucket | Quota | Consumer |
|--|--|--|
| `proxmox-backups` | 300G | [PBS](pbs.md) |
| `k8s-backups` | 50G | [VolSync](../backups.md#volsync) |

Not state: the apps' containers (compose files in git), the certificate
(re-orderable).

## Backup & restore

Datasets: [ZFS snapshots](../backups.md#zfs-snapshots). Garage keeps its own
metadata snapshot every 6h (`metadata_auto_snapshot_interval`), same dataset.
**The NAS itself, and its configuration, are not backed up** -- users,
shares, tasks, certificates, apps. See
[Not covered](../backups.md#not-covered). A dead boot disk (eMMC) with the
pools intact: reinstall TrueNAS, import `fast` and `slow`, unlock them with
the pool passphrase from the password managers, then redo the configuration
from [Build guide: TrueNAS](../build/machines/truenas.md). A dead NAS, pools
included, is a rebuild from the same guide with every backup gone.

**One bucket back** without rolling back the others: `zfs clone` a
`slow/garage` snapshot and copy out, never `zfs rollback` (it hits every
tenant).

**Verify** after anything on the NAS:

```sh
curl -s http://10.212.4.150:9100/metrics | grep -E '^(nas_zpool|node_zfs_zpool_state)'   # every pool, state="online" 1
mise run s3 volsync ls s3://k8s-backups/          # Garage answers with a key
kubectl get pvc -A                                # all Bound
```

## Admin

**Users.** Local only, by hand. A person is one unit: user, own group,
`slow/users/<name>` dataset, SMB share -- same name, created and removed
together. Keep `builtin_administrators` to `admin` and the built-in. ACLs and
share settings: [Build guide: TrueNAS](../build/machines/truenas.md#creating-users).

**democratic-csi's API key.** Hangs off user `democratic-csi` with the
`FULL_ADMIN` privilege -- anything narrower gets `403` from the REST API.
Rotate: new key in *Credentials* -> *API Keys* (shown once), into
`truenas_api_key` in `secrets/vault.yml`, `mise run platform apply`, revoke the
old one. No expiry set; an expired key shows as PVCs stuck `Pending`.
[Build guide](../build/machines/truenas.md#api-key-for-democratic-csi).

**Certificate.** TrueNAS's ACME, one CSR with four SANs: `nas`, `nas-k8s`,
`s3`, `s3-k8s` (all `.<lab_domain>`). SANs are fixed per CSR -- a new name is
a new CSR and order. Caddy does not watch the files: a weekly root cron runs
`caddy reload --force`.

**A new Garage consumer.**

```sh
garage bucket create <name>
garage bucket set-quotas <name> --max-size <size>
garage key create <name>                          # shown once
garage bucket allow --read --write <name> --key <name>
```

Never `--owner`. Into `secrets/vault.yml` as `garage_<name>_key_id` /
`garage_<name>_secret_key` (what `mise run s3 <name> ...` reads); a k8s
consumer gets it through OpenBao. Clients use region `lab`, path-style,
`https://s3[-k8s].<lab_domain>:3900`.

**Removing an app** that had a VolSync backup: delete its `k8s-backups`
prefix -- [VolSync, *Removing an app*](../backups.md#volsync).

**node-exporter.** A custom app plus a root cron every minute that writes
`zpool.prom` (pool size/alloc/free) into `slow/node-exporter` -- node-exporter
cannot see pool size. SMART is not exported. Alerts: `NasDown`,
`NasPoolNotOnline`, `NasPoolFull` (>80%), `GarageDown`. See
[Monitoring](../monitoring.md).

**Updates.** TrueNAS: by hand in the UI. Apps: Renovate bumps the tag in the
compose file; then edit the app in TrueNAS and set the new tag -- nothing
applies it. See [Maintenance](../maintenance.md).

**Health.** Scrub tasks weekly with a 30-day threshold, both pools. SMART tests
are **not set up**. On `fast` a scrub can only report: an error there means
buying the second NVMe.

## Gotchas

- **Disable the BIOS watchdog** (`CTRL+F12`) before installing: UGOS pets it,
  TrueNAS does not, the box reboots every few minutes.
- **`mmcblk0boot0/1` show up as two unassigned SSDs.** The eMMC's hardware
  boot partitions; never add them to a pool.
- **NVMe-oF port: edit, never recreate.** democratic-csi attaches to a fixed
  port id (`truenas_nvmeof_port_id` in `platform_democratic_csi.tf`); a new
  port is a new id, and volumes then provision but never attach.
- **Nothing hand-made on `fast`**: no datasets, no snapshot task, no apps pool.
  A snapshot the driver does not know blocks the zvol destroy behind a PVC.
- **NFS maps root to root.** Squashed, the driver's and the kubelet's `chown`
  fail as a pod that mounts and cannot write. Reachability is the only guard.
- **Grow `slow` with a second mirror vdev**, never by widening one. Mirror
  `fast` with *Extend* / `zpool attach`, never `zpool add`.
- **The Trusted interface first**: the k8s interface has no gateway and no
  nameserver; configure it second, from the Trusted address, or you lock
  yourself out.

## What breaks without it

Everything with state. NAS down: every `fast` and `bulk` PVC hangs (Vaultwarden,
Pocket ID, OpenBao, Syncthing, Zot, ...), PBS and VolSync backups fail, Home
Assistant backups fail, SMB and Time Machine are gone, NAS metrics stop. VMs on
titan's `local` keep running. Garage alone down: no new backups and no
restores; `GarageDown` fires.
