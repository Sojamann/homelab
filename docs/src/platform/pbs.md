# Proxmox Backup Server

## What it's for

Backs up every VM except itself, nightly, into Garage on the NAS.
Incremental, deduplicated, per-VM and per-file restore. How the route works,
its schedule and its restore steps: [Backups: PBS](../backups.md#pbs).

## Access

- **UI:** `https://pbs.<lab_domain>:8007`. Trusted and tailnet (admins).
- **Login:** realm `pocket-id`. No group mapping: each admin is a user
  `<name>@pocket-id` created by hand, autocreate off.
- **Break-glass:** `root@pam` in the UI, or the VM 162 console in Proxmox.
  Its password is in the password managers.
- **No SSH key** from the guests layer: PBS is installed from the ISO, not
  cloud-init.

## Where it runs

VM 162 on titan, `10.212.2.162`, 2 cores, 4G (GC and verify hold the chunk
index in memory). `guests/guest_vm_pbs.tf` builds the empty VM with the ISO
attached; everything inside is by hand.
Build: [Build guide: Guests, *Backups*](../build/guests/README.md#backups).

## Data

| What | Where | State? |
|--|--|--|
| OS + PBS config: datastore, S3 endpoint, users, token, realm, jobs | `scsi0`, 20G | **yes**, and backed up nowhere |
| S3 datastore cache `pbs-cache` | `scsi1`, 8G, `/mnt/datastore/pbs-cache` | no, a cache |
| The backups | Garage bucket `proxmox-backups`, quota 300G | **yes** |

## Backup & restore

PBS is **excluded from its own job**: it cannot restore itself, and it would
back up its own chunk store. A dead PBS VM is rebuilt by hand onto the
existing bucket: the dead-node steps in [Backups: PBS](../backups.md#pbs),
steps 2-3.

**Verify.** *Datastore* -> `proxmox-backups` -> *Content* lists every VM with
its last snapshot; on titan `pvesm list pbs-s3 | tail`. Then restore one
small VM's file via *File Restore*.

## Admin

**Adding an admin.** Pocket ID's `pbs` client allows `admins`; PBS still needs
the user:

```sh
proxmox-backup-manager user create <name>@pocket-id
proxmox-backup-manager acl update / Admin --auth-id <name>@pocket-id
```

**Credentials.**

| What | Where |
|--|--|
| PBS -> Garage | key `garage_pbs_key_id` / `garage_pbs_secret_key` in `secrets/vault.yml` |
| PVE -> PBS | token `backup@pbs!lab`, *DatastoreBackup* on `/datastore/proxmox-backups`; on titan in `/etc/pve/priv/storage/pbs-s3.pw` |
| Pocket ID client `pbs` | entered into the realm by hand; not in the vault |

**Growing the cache.** Raise `scsi1` in `guest_vm_pbs.tf`, `mise run guests
apply`, then `growpart` + `resize2fs` in the guest.

**Moving the datastore** (e.g. another bucket):
[Build guide: Guests](../build/guests/README.md#backups), *Moving an existing
datastore*. Prune, GC and verify are per datastore and must be recreated.

**Updates.** By hand: the PBS UI's *Updates* or `apt full-upgrade`. Nothing
automates them.

## Gotchas

- **The cache fills whatever it gets.** The disk size is the only limit.
- **Create namespace `lab` before the PVE storage entry** -- the token cannot.
- **A synced group keeps its owner.** Pull-sync with local owner
  `backup@pbs!lab`, or the token cannot add to it.
- **Job order matters**: prune after the backup it counts, GC last. See the
  schedule in [Backups: PBS](../backups.md#pbs).
- **Not client-side encrypted.** The Garage key reads every VM disk.

## What breaks without it

No new VM backups and no VM restores. The VMs run on. The failed 23:00 job
reaches Telegram only through PVE's own notification, set up in the UI, not in
this repo (see [Backups: PBS](../backups.md#pbs), *Health check*).
