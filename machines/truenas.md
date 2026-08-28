# TrueNAS (manual)

The NAS. Done by hand in the UI and stays that way. Build it before the
Proxmox nodes: where guest disks live is baked in at node install.

## Hardware

`UGREEN NASync DXP4800 GT`, 4-bay, running TrueNAS instead of UGOS.

- 4 bays, 2 populated -- 2x 4TB HDD, one mirror vdev, 4TB usable
- 2 M.2 NVMe slots, 1 populated -- 500GB, no redundancy
- 2x 10GbE, **both in use** -- one per VLAN, not bonded: different networks,
  not more bandwidth, so no LACP
- Static `10.212.2.150` on Trusted, below the physical range `.151-.159` and
  above the DHCP pool which stops at `.149`
- Static `10.212.4.150` on k8s (VLAN 40) -- the storage interface. NVMe/TCP and
  the TrueNAS API both arrive here, so neither crosses the router

**Disable the watchdog in the BIOS first** (`CTRL+F12`). UGOS pets it from
userspace, TrueNAS does not -- the box reboots every few minutes, installer
included.

## First Setup

0. install TrueNAS with the installer
1. login to the web ui on the DHCP address (https!)
2. set the initial password for `truenas_admin`
3. run updates
4. *Network* -> *Interfaces* -> first interface: DHCP off, alias
   `10.212.2.150/24`, gateway `10.212.2.1`, nameserver `10.212.2.1`
   - **Test Changes** -> reconnect on `https://10.212.2.150` -> **Save Changes**
     there, within 60s, or it rolls back
   - if it comes up in `10.212.0.x`, the switch port is not in Trusted --
     fix the port profile (untagged VLAN 20) first
5. login to the web ui on the new ip
6. second interface: DHCP off, alias `10.212.4.150/24`, **no gateway and no
   nameserver** -- TrueNAS has one default route and it stays on Trusted;
   everything using this interface is on the same `/24`
   - switch port untagged VLAN 40
   - Test Changes and Save from the Trusted address. Doing this one second is
     what keeps it from locking you out
7. get a certificate for the domain: *Credentials* -> *Certificates*
   - add ACME DNS credentials
   - add a CSR, e.g. `lab-csr`, with **both names**: `nas.lab.<domain>` and
     `nas-k8s.lab.<domain>`. One certificate serves both interfaces, and
     democratic-csi verifies the second -- a missing SAN there is a driver that
     cannot talk to the NAS
   - on the CSR: order certificate
   - *System* -> *General* -> *GUI* -> set it as the UI certificate
8. login to the TrueNAS ui through the dns record
   - the `nas.lab.<domain>` and `nas-k8s.lab.<domain>` A records are written by
     [network](../network/README.md), not by hand
9. bind the services (below) -- everything but the API stays on Trusted
10. create an `admin` user with sudo, use it instead of `truenas_admin`
11. configure alert delivery, and **send a test alert**

## Creating Pools

| Pool   | Media | Layout           | Redundancy | Holds                      |
|--------|-------|------------------|------------|----------------------------|
| `fast` | NVMe  | stripe, width 1  | **none**   | k8s PVCs                   |
| `slow` | HDD   | mirror, 2x 4TB   | 1 disk     | backups, tofu state        |

Per pool, after creation:

```sh
zpool get ashift fast          # must be 12 -- verify, do not assume
zpool set autoexpand=on fast
zfs set atime=off fast
zfs set compression=lz4 fast
```

Infos:
- grow `slow` by adding a **second mirror vdev** (2 free bays, 8TB usable),
  never by widening one
- mirror `fast` later with `zpool attach` / UI *Extend*, **never** `zpool add`
- ~4TB usable on `slow`, stay under 80% -> ~3.2TB
- no quotas, no reservations, except `time-machine`

Scrub tasks -- both pools, *Data Protection* -> *Scrub Tasks*:

- schedule **weekly**, threshold **30 days** -> scrubs monthly, catches up if
  the box was off on the due day
- on `fast` a scrub can only report, not repair -- an error there means buy the
  second M.2 that week

SMART tests -- **not set up yet**. Intended: short weekly, long monthly, all
three drives.

## Creating Users

All local, no directory service. Created and removed by hand.

- `admin` -- daily driver for UI and shell, in `builtin_administrators`
- one user per person, each in its **own dedicated group**
- the user, the group, the `slow/users/<name>` dataset and the SMB share are
  one unit -- same name, created together

Rules:

- keep `builtin_administrators` to `admin` + the built-in, nothing else
- do daily work as your own user, not as `admin`

## Creating Datasets

```
slow/
├── k8s-csi/         the NFS share root, one subdirectory per PV
├── pbs-backups/     PBS datastore
├── users/<name>/files/          the SMB share root
└── users/<name>/time-machine/   (optional) one Mac
```

`atime=off` and `compression=lz4` inherit from the pool roots; `sync=standard`
everywhere by leaving it alone. Create structure only -- permissions come after.

Nothing on `fast` is created here. democratic-csi makes its own datasets on the
first PVC and owns them entirely -- see [platform](../platform/README.md). They
inherit the pool-root properties above, which is the only reason those matter
for `fast`. Nor is there a snapshot task on `fast`: the driver takes its own
through `VolumeSnapshot`, and a snapshot it does not know about blocks the zvol
destroy behind a PVC, which then sits in `Terminating`. A snapshot there would
protect against you anyway, not against the drive.

`slow/k8s-csi` is created here, and that asymmetry is the second CSI driver:
csi-driver-nfs has no API to the NAS and no concept of a dataset. It mounts one
export and `mkdir`s a directory per PV inside it, so the dataset is made once,
by hand, and every `bulk` volume lives within it.

| Dataset                     | recordsize | compr | Snapshots         | Share / consumer        |
|-----------------------------|------------|-------|-------------------|-------------------------|
| `k8s-csi`                   | 128K       | lz4   | hourly (24h retention) + daily (30d retention), **not** recursive | NFS, the `bulk` StorageClass |
| `pbs-backups`               | 1M         | lz4   | daily, **3d**     | PBS                     |
| `users`                     | 128K       | zstd  | hourly (24h retention) + daily (30d retention), recursive, exclude `users/*/time-machine` | -- (children only) |
| `users/<name>`              | 128K       | zstd  | via `users` task  | -- (children only)      |
| `users/<name>/files`        | 128K       | zstd  | via `users` task  | SMB, per person         |
| `users/<name>/time-machine` | 1M         | lz4   | **none**          | SMB, TM preset + quota  |

Why the "none"s and the short one:

- `time-machine` -- a ZFS snapshot pins the sparsebundle bands TM deletes, so
  it grows forever while TM thinks it is reclaiming. The recursive task on
  `slow/users` excludes it via the pattern `slow/users/*/time-machine`
  (*Exclude* field on the task).

One recursive task on `slow/users` covers every user, current and future --
no per-user task. Recursive means one snapshot **per dataset** (same name,
atomic), not one snapshot of the tree: each user rolls back and browses
`.zfs/snapshot` independently.
- `pbs-backups` -- same trap: snapshots pin chunks PBS GC wants to free.
- `k8s-csi` -- not recursive: the PVs under it are directories, not datasets,
  so one task on the one dataset is already every volume. And `lz4`, not the
  `zstd` the user datasets take -- PDFs and images are compressed already.

`k8s-csi` takes share type **Generic** (POSIX), owner `root:root`, not the SMB
preset -- nothing reaches it over SMB. Nothing below the root is set by hand:
the driver creates each PV directory and `chown`s it itself.

ACLs -- both `users` levels created with the **SMB preset**:

`slow/users` (owner `root:root`):

| Principal                | Permission   |
|--------------------------|--------------|
| `owner@`                 | Full Control |
| `group@`                 | Traverse     |
| `builtin_administrators` | Full Control |
| `everyone@`              | Traverse     |

`slow/users/<name>` and `.../files` (owner `<name>:<name>`):

| Principal                | Permission   |
|--------------------------|--------------|
| `owner@`                 | Full Control |
| `builtin_administrators` | Full Control |

The parent's `everyone@ Traverse` lets users walk through without `ls`; the
child has no `everyone@` at all, so the walk stops there. A new child dataset
does **not** inherit the parent ACL -- set it on `files` explicitly and verify.

## Shares and Services

**Service bind addresses** -- the k8s VLAN is untrusted and this box has an
interface in it, so nothing listens there without a reason. GUI addresses are
in *System* -> *General* -> *GUI*, the rest on each service:

| Service | Binds                                 | Why                          |
|---------|---------------------------------------|------------------------------|
| Web UI  | `10.212.2.150` **and** `10.212.4.150` | the API the CSI driver calls |
| SMB     | `10.212.2.150`                        | people, who are on Trusted   |
| SSH     | `10.212.2.150`                        | same                         |
| NVMe-oF | `10.212.4.150`                        | the cluster, nothing else    |
| NFS     | `10.212.4.150`                        | the cluster, nothing else    |

The UI is the uncomfortable row: TrueNAS serves it and the API on one listener
and cannot split them, so the login page is reachable from k8s. Taken
knowingly -- the driver already holds a `FULL_ADMIN` key, so the API surface is
not new. What scopes it is the dedicated user and that the key is revocable.

**NVMe-oF** -- service on, one port: transport *TCP*, `10.212.4.150`, port
`4420`.
- **bound to the k8s address only** -- half the access control on a protocol
  with no authentication. The other half is `nvmeof-deny-cross-vlan` in
  [network](../network/README.md): Trusted can still route into the k8s VLAN
  even when the listener does not answer on Trusted
- create **no** subsystems and **no** namespaces; democratic-csi owns them
- ports are the exception -- the driver only attaches to existing port IDs.
  Read the numeric **ID** (not port) and put it in `truenas_nvmeof_port_id` in
  [platform/platform_democratic_csi.tf](../platform/platform_democratic_csi.tf).
- to move the listener later, **edit the port, do not recreate it** -- a `PUT`
  keeps the id, a recreate hands you a new one and the symptom is volumes that
  provision fine and never attach:
  ```
  curl -sX PUT -H "Authorization: Bearer $TRUENAS_API_KEY" \
    -H 'Content-Type: application/json' -d '{"addr_traddr": "10.212.4.150"}' \
    https://nas.lab.<domain>/api/v2.0/nvmet/port/id/1
  ```
  Anything currently attached drops when the address moves.
  ```
  curl -sH "Authorization: Bearer $TRUENAS_API_KEY" \
    https://nas.lab.<domain>/api/v2.0/nvmet/port
  ```
- needs TrueNAS **25.10+**. iSCSI stays off.

**SMB** -- one share per `users/<name>/files`.
- leave the **share ACL at default** -- effective access is the intersection of
  share and filesystem ACL; the dataset stays the single source of truth
- Purpose: **default share parameters**, except `time-machine`, which takes the
  Time Machine preset (macOS needs what it sets)
- Access Based Share Enumeration **on**, Browsable **on**
- Read Only off, Hosts Allow/Deny empty, Apple encoding off, Audit off

**NFS** -- one export, and only ever one: the share csi-driver-nfs subdivides.

- service bound to `10.212.4.150` only, same half of the access control as
  NVMe-oF
- **NFSv4 on**, v3 ownership model off -- v4 is what the driver mounts
  (`nfsvers=4.1`), and v3 would be a second, weaker way in

| Field                | Value               | Why                            |
|----------------------|---------------------|--------------------------------|
| Path                 | `/mnt/slow/k8s-csi` |                                |
| Networks             | `10.212.4.0/24`     | the k8s VLAN, nothing else     |
| Hosts                | empty               | Networks already scopes it     |
| Maproot User / Group | `root` / `root`     | `no_root_squash` -- see below  |
| Read Only            | off                 |                                |

Maproot root is the uncomfortable field. Two client-side operations run as
root: the driver `chown`ing each PV directory, and the kubelet `chown`ing the
mount root for `fsGroup`. Squashed, both fail as a volume that mounts cleanly
and a pod that cannot write.

So anything that can mount this is root on it, and what scopes that is
reachability -- the same trade as NVMe-oF, one protocol over. The difference is
what is behind it: documents here, VM disks there.

### API key for democratic-csi

A key inherits the privileges of the user it hangs off, so it gets its own.

1. *Credentials* -> *Users*: create `democratic-csi`, own group, no home
   dataset, shell `nologin`, no password. Not `admin` -- a dedicated user keeps
   the blast radius scoped, revocable and auditable.
2. Grant the roles. *Credentials* -> *Groups* -> **Privileges** -> *Add*:
   - Name: `democratic-csi`
   - Local Groups: `democratic-csi`
   - Roles: **`FULL_ADMIN`** (shown as *Full Admin*)
   - Web Shell / ssh access: off

   Full admin is the only option, not a shortcut. TrueNAS gates its REST API --
   the only API democratic-csi speaks -- on a privilege allowlist that only
   `FULL_ADMIN` produces (`middlewared/role.py`: *"Only non-stig FULL_ADMIN
   privilege can access REST endpoints"*). Anything narrower returns `403` on
   every call while looking correct in the UI. What still scopes this key is
   the dedicated user, no shell, no UI access and its own revocation.

3. *Credentials* -> *API Keys* -> **Add**, bound to that user. **Copy it now**
   -- it is shown once and cannot be read back.
4. Store as `truenas_api_key` in `secrets/vault.yml` (`ansible-vault edit`).
5. Verify, which also gets you the port **ID** for `nvmeof.ports`:
   ```
   curl -sH "Authorization: Bearer $TRUENAS_API_KEY" \
     https://nas.lab.<domain>/api/v2.0/nvmet/port
   ```
   `403` means the privilege is not `FULL_ADMIN`

No expiry unless the rotation is tracked somewhere: an expired key surfaces as
PVCs stuck in `Pending`.

Firewall paths from k8s: **none**. The two data paths and the API all land on
`10.212.4.150`, in the cluster's own network, so none of them crosses a zone
pair -- NFS adds a third listener there and still no rule.
`10.212.4.0/24` is default-deny outbound with no exceptions. The one policy
that touches this is `nvmeof-deny-cross-vlan`, keeping the other four networks
away from `10.212.4.150:4420` -- see [network](../network/README.md).

## Backup Layers

1. **ZFS snapshots** -- undo, same pool. Survives a mistake and nothing else.
2. **PBS on `slow/pbs-backups`** -- per-VM, per-file restore. Survives a dead
   guest, node or NVMe. The PBS VM itself lives on node-local `local`.
3. **Offsite (B2)** -- survives losing the NAS. **Not built.** `users/` goes
   first when it is.

Until 2 exists, `fast` has no restore path. Until 3 exists, one fire takes the
guests and every backup of them.
