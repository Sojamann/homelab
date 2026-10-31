# Home Assistant

## What it's for

Home automation: devices, pairings, automations, Matter credentials. Home
Assistant OS as an appliance -- it updates itself, and its configuration
lives in the VM, not in this repo. Using it is upstream:
[Home Assistant docs](https://www.home-assistant.io/docs/).

## Access

- **URL:** `http://ha.<lab_domain>:8123` -- straight to the VM, not through
  the gateway, no TLS from the lab.
- **Reachability:** LAN (Trusted) and tailnet: `group:family` gets tcp 8123
  on `10.212.2.161`, `group:admin` the whole Trusted route. Not public. From
  the k8s VLAN only Prometheus's narrow allow (`metrics-allow-home-assistant`).
  See [Networking](../networking.md).
- **Login:** Home Assistant's own users, credentials in the password
  managers. No SSO is configured from this repo.
- **Console:** Proxmox UI, VM 161 -> *Console* (the HA OS CLI).

## Where it runs

VM 161 `home-assistant` on titan, `10.212.2.161`, MAC `BC:24:11:00:01:61`,
2 cores, 6 GiB, 32G disk on `local`, UEFI (OVMF, q35). Defined in
`guests/guest_vm_home_assistant.tf`, with the DNS record `ha.<lab_domain>`.
Wiring: [Build guide: Guests](../build/guests/README.md).

## Data

Everything that matters is state, and all of it is inside the VM's disk:
configuration, integrations, device pairings, automations, history, Matter
credentials. Nothing in the repo can rebuild it -- this is the guest that
cannot be rebuilt.

Not state: the VM's shape (tofu), the address record, the install image.

## Backup & restore

Two routes, independent of each other:

- [PBS](../backups.md#pbs) -- the whole VM, `23:00` daily, keep last 3,
  daily 7, weekly 4, monthly 6.
- [Home Assistant's own backups](../backups.md#ha-backups) -- to
  `slow/ha-backups` over SMB, scheduled and encrypted in the appliance,
  plus 14 daily ZFS snapshots of the share. Survives losing PBS.

**Which to use.**

- VM broken, disk gone, or a bad update: the [PBS VM restore](../backups.md#pbs)
  of VM 161. After a dead node, PBS comes back first, then this VM from it.
- A bad config change in a running instance: an HA backup, *Settings* ->
  *System* -> *Backups* -> pick -> *Restore*.
- PBS gone too: a fresh VM plus an HA backup:
  1. `mise run guests apply -target=proxmox_virtual_environment_vm.home_assistant`
     -- a new VM from the pinned image.
  2. At the console, set the address `10.212.2.161/24` (gateway `10.212.2.1`)
     and hostname by hand; HA OS reads no cloud-init.
  3. Copy the newest `.tar` off the `ha-backups` share, choose *Upload backup*
     at onboarding, give the backup encryption key.

**Verify.**

```sh
qm status 161          # on titan
qm agent 161 ping      # the guest agent answers
curl -s -o /dev/null -w '%{http_code}\n' http://ha.<lab_domain>:8123/
```

Then log in: integrations load without errors, devices report state, a known
automation fires. After a PBS restore the backup is up to a day old -- check
*Settings* -> *System* -> *Backups* still lists the share as a location.

## Admin

**Updates.** In the appliance (*Settings* -> *System* -> *Updates*), not in
this repo. Take an HA backup first. The image in `guests/guest_images.tf`
(`haos`) is install media only: the VM ignores changes to its `file_id`, so
bumping the image version re-downloads it and leaves the running VM alone.

**Deliberate rebuild:** `tofu taint` the VM, then restore an HA backup as
above. Never by bumping the image without the `ignore_changes` -- that would
replace the disk and take every pairing, automation and Matter credential
with it.

**Address.** Set once by hand at the console. The local in the `.tf` drives
only the id, the MAC and the DNS record -- the one address in this repo that a
guest could disagree with. The tailnet policy (`network/tailscale_policy.tf`)
and the firewall allow (`network/unifi_firewall.tf`) hard-code `10.212.2.161`
too; changing it means changing all three.

**Disk.** HA OS grows its data partition to fill the disk on first boot, and
Proxmox can grow it online, so 32G is a floor. To grow: raise `size` in the
`.tf`, `mise run guests apply`.

**HA backups.** Schedule, retention and the encryption key live in the
appliance (*Settings* -> *System* -> *Backups*). The share is reached as the
NAS service account `ha-backup`. The encryption key's second copy is in the
password managers.

**Metrics.** The firewall allows k8s Prometheus to scrape `:8123`
(`/api/prometheus`, filtered to HA's own health metrics, guarded by a token).
The scrape config itself is not in the apps repo yet -- see
[Monitoring](../monitoring.md).

## Gotchas

- **Secure boot must stay off** (`pre_enrolled_keys = false`): the image is
  unsigned, and with keys enrolled it does not boot at all.
- **No cloud-init drive, on purpose.** It would be a place to write an address
  the guest never uses.
- **The upstream image has no checksum**, so the download is not verified.
- **Without the HA backup encryption key, the HA backups are unreadable.**
- **Restoring from PBS loses up to a day**; an HA backup may be older or
  newer than the PBS one -- compare dates before picking.
