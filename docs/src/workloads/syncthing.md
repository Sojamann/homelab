# Syncthing

## What it's for

The household's self-hosted cloud: an always-on syncthing peer every device
syncs with, so devices that are never online together still converge, and
every file has a copy on the NAS. One instance for everyone; the GUI is the
admin's. Using the clients is upstream:
[Syncthing docs](https://docs.syncthing.net/).

## Access

- **GUI:** `https://sync.<app_domain>`, user `admin`. Admin only.
- **Sync:** `tcp://sync.<app_domain>:22000` and `quic://sync.<app_domain>:22000`,
  on the Gateway's `syncthing` / `syncthing-quic` listeners.
- **Reachability:** LAN and tailnet. No global discovery, no relays, no NAT
  traversal. Away from home a device syncs over the tailnet; without it, once
  it is home. See [Networking](../networking.md).
- **Login:** GUI password from OpenBao (`kv/syncthing/app`, generated in
  `platform_secrets.tf`). No SSO:
  ```sh
  kubectl -n syncthing get secret syncthing -o jsonpath='{.data.gui-password}' | base64 -d
  ```

## Where it runs

Namespace `syncthing`, one Deployment, Flux Kustomization `syncthing`.
Wiring: [Build guide: Syncthing](../build/flux/docs/syncthing.md).

## Data

Two volumes, split by what SQLite tolerates:

| Volume | What | Storage | State? |
|--|--|--|--|
| `syncthing-data` -> `/data` | the files | static PV on `slow/k8s-csi/syncthing`, `Retain` | **yes** |
| `syncthing-config` -> `/var/syncthing/config` | device keys, `config.xml`, index db | `fast`, 2Gi | keys + `config.xml` **yes**; the db is rebuilt by a rescan |

`syncthing-data` is not a `bulk` PVC: a deleted PVC, namespace or app leaves
the directory, and a rebuild re-binds it by name. The directory is made by
hand (owned by uid 1000) -- see
[machines/truenas.md](../build/machines/truenas.md). The 1Ti capacity is a
label, not enforced.

The keys are the hub's device id: lost, every device has to be paired again.

Layout under `/data`, one syncthing folder per directory, so a phone can take
`documents` and leave `media` alone:

```
/data/
├── <person>/documents/
├── <person>/media/
└── shared/             both people's devices
```

Not state: the GUI password and API key (OpenBao) and the options git
re-applies on every start (see [Admin](#admin)).

## Backup & restore

- **Files:** [ZFS snapshots](../backups.md#zfs-snapshots) on `slow/k8s-csi`,
  24 hourly + 30 daily. Not in VolSync. Plus the 7-day trash can
  (`.stversions/`) in every folder, and every paired device.
- **Config + keys:** [VolSync](../backups.md#volsync), nightly `00:30` UTC,
  retain daily 14, weekly 8, monthly 6.

**Restore.**

- **A file deleted or overwritten in the last 7 days:** the folder's
  `.stversions/` on any device, or *Versions* in the hub's GUI.
- **Older, or many files:** the NAS snapshots,
  `.zfs/snapshot/<name>/syncthing/` under `/mnt/slow/k8s-csi`. Copy back into
  the directory; syncthing sends it out like any change.
- **Config or keys:** the generic [VolSync restore](../backups.md#volsync),
  with:
  ```sh
  NS=syncthing KS=syncthing DEPLOY=syncthing PVC=syncthing-config MOVER_UID=1000
  ```

**Verify.**

```sh
kubectl -n syncthing rollout status deploy/syncthing
kubectl -n syncthing logs deploy/syncthing | tail
```

In the GUI: *Actions* -> *Show ID* is the same device id as before (devices
connect without re-pairing), every folder reaches *Up to Date*, and every
device shows as connected once it is online.

## Admin

**What git owns.** The rest of the config is the GUI's, saved in
`config.xml` and backed up with it. Re-applied from `server.yaml` on every
start (init container + `postStart`), so changing these in the GUI does not
survive a restart:

- GUI user `admin`, password from OpenBao
- listen on `tcp://` and `quic://0.0.0.0:22000`; global and local discovery,
  relays, NAT traversal, usage reporting and crash reporting off
- new folders default to `/data/` and a 7-day trash can (`.stversions/`)

**Adding a device.** On the device, install syncthing, then add the hub as a
remote device:

- device id: the hub's, from the GUI (*Actions -> Show ID*)
- addresses: `tcp://sync.<app_domain>:22000, quic://sync.<app_domain>:22000`
  -- not `dynamic`, there is no discovery to find it

Accept the device in the hub's GUI, then share that person's folders with it.
On the device, accept the folders and pick where they live locally.

New folders: ignore pattern `(?d).DS_Store`.

**Hub folders stay *Send & Receive*.** The hub relays between devices that
are never online together, and a *Receive Only* hub would hold their changes
without passing them on. It would not shield devices either -- other devices'
changes, deletes included, still arrive. The trash can and NAS snapshots are
the undo. *Receive Only* + `ignoreDelete` is for an archive, e.g. a camera
roll.

**Clients.** Windows and macOS the official builds (or SyncTrayzor /
syncthing-macos, brew cask `syncthing-app`), Android Syncthing-Fork, iOS
Möbius Sync or Synctrain. iOS syncs only while the app runs; phones take
documents, not the camera roll.

**Alerts** (`monitoring.yaml`, scraped with the API key as bearer token; see
[Monitoring](../monitoring.md)):

| Alert | When |
|--|--|
| `SyncthingDown` (critical) | not scraped for 10m |
| `SyncthingFolderError` | a folder in error state for 1h |
| `SyncthingFolderOutOfSync` | the hub still needs data after 6h |
| `SyncthingDeviceUnseen` | a device not connected once in 7 days |

**Updates.** The image tag is pinned in `server.yaml` (`STNOUPGRADE=1`, no
self-upgrade); Renovate proposes bumps (see [Maintenance](../maintenance.md)).

### Not enabled

- **SSO via Pocket ID.** Syncthing has no OIDC; it would take an
  oauth2-proxy in front, passing a fixed basic-auth header upstream.
- **Camera roll upload.** Later, maybe Immich, which can import the synced
  folders as an external library.

## Gotchas

- **GUI changes to the git-owned options are undone on restart.** Change them
  in `server.yaml`.
- **`SyncthingDeviceUnseen` misses a device that never returns after a
  restart:** `syncthing_connections_active` appears only once a device
  connects after one.
- **The sync routes carry no hostname.** Syncthing's TLS sends no SNI, so any
  name on the Gateway's address reaches `:22000`.
- **One pod, `Recreate`.** SQLite has one writer and the config volume is RWO.
- **Memory grows with the number of files**, not their size; a first scan of a
  large folder hashes everything.
- **A `SyncthingFolderOutOfSync` during a large first sync is expected** --
  it can be legitimately behind for hours.
