# Guests

Terraform (OpenTofu) owns what runs *on* the hosts; [machine-config](../machine-config/README.md)
owns the hosts themselves. This layer builds the core infrastructure guests.

It stops at the VM -- for Home Assistant it stops rather earlier than that;
see the trade-offs. A Talos guest boots into maintenance mode with an address
and no configuration; [cluster](../cluster/README.md) turns it into a cluster
member. No cluster secret is written here.

How the guests are used and restored: [Proxmox](../docs/src/platform/proxmox.md),
[PBS](../docs/src/platform/pbs.md), [VPN](../docs/src/platform/vpn.md),
[Home Assistant](../docs/src/workloads/home-assistant.md),
[Talos](../docs/src/platform/talos.md).

## Running

```sh
mise run guests plan
mise run guests apply
```

Arguments are forwarded to `tofu`, so `console`, `state list` and friends work
the same way. `init` runs automatically on first use.

## Credentials

Read out of the ansible vault by `scripts/tofu.sh` and exported, so nothing is
configured in a provider block or written to disk in cleartext:

| Variable               | Source                      | For                       |
|------------------------|-----------------------------|---------------------------|
| `PROXMOX_VE_API_TOKEN` | `secrets/proxmox-token.yml` | the node's API            |
| `UNIFI_API_KEY`        | `secrets/vault.yml`         | the guests' DNS records   |
| `TF_VAR_lab_domain`    | `secrets/vault.yml`         | endpoint and record names |
| `TF_VAR_terraform_state_passphrase` | `secrets/vault.yml` | this layer's encrypted state |

Plus **your own ssh-agent**: the provider scps cloud-init snippets, which the
upload API refuses, so an apply needs a loaded key `root@<node>` accepts
(`ssh-add -l`). Not a vault credential on purpose -- nothing extra to rotate,
and node access is already the bar for changing this layer.

If `secrets/proxmox-token.yml` is missing, rerun `mise run machine-config`:
Proxmox shows a token's secret once, so the role mints a new one. The UniFi key
is the [network](../network/README.md) layer's.

## DNS

A guest's `A` record lives in the guest's own file, through the same UniFi
provider the [network](../network/README.md) layer uses -- so adding a guest is
one file in one layer, and the record and the VM read the same local.

The split is by what owns the thing, not by kind of record: the network layer
keeps the names for what this layer does not build, the machines and the NAS.
Both write the same zone, so a name must exist in exactly one of them.

## SSH

`guest_ssh_key.tf` generates one ed25519 key for the whole layer. A guest's
cloud-init snippet authorises the public half; the private half is
written to `secrets/guests-ssh-key` (0600, gitignored) for ansible and for you:

```sh
ssh -i secrets/guests-ssh-key ubuntu@vpn.<lab_domain>
```

## Current contents

| ID   | IP           | DNS                         | Purpose                   |
|------|--------------|-----------------------------|---------------------------|
| 160  | 10.212.2.160 | `vpn.<lab_domain>`          | tailscale subnet router   |
| 161  | 10.212.2.161 | `ha.<lab_domain>`           | Home Assistant OS         |
| 162  | 10.212.2.162 | `pbs.<lab_domain>`          | Proxmox Backup Server     |
| 4010 | 10.212.4.10  | `talos-cp-1.<lab_domain>`   | k8s control plane, VLAN 40 |


## Known trade-offs

- **Guest ids and MACs are derived from the address.** `10.212.2.160` gives VM
  `160` and MAC `BC:24:11:00:01:60`, so a guest id, an address and a MAC all
  answer the same question. It is a convention, not a mechanism, and nothing
  enforces it.

  Guests now live in two `/24`s, which the host octet alone cannot tell apart,
  so the third octet leads the id and takes byte five of the MAC:
  `10.212.4.10` is VM `4010` and `BC:24:11:00:04:10`. vpn stays `160`,
  grandfathered. The cluster layer relies on this to read a Talos node's
  address back out of its vm id, which is the first time the convention is
  load-bearing rather than a convenience.

- **A Talos guest is tagged, and the tags are an interface.** `talos` plus
  `talos-controlplane` or `talos-worker` is how the cluster layer finds its
  nodes -- it does not keep a list. Mistyping a tag produces a VM that no
  cluster ever configures, and no error anywhere.
- **Home Assistant is an appliance, and the exception to most of this.** It is
  configured by hand afterwards since no cloud-init mechanism exists.
- **PBS is installed by hand, and deliberately so.** It ships no cloud image,
  so this layer attaches the ISO to an empty disk and stops.
- **Every image is downloaded to every node.** `local` is cluster-wide in name
  but per-node in content, and a guest can only boot from an image its own node
  holds -- so the downloads are keyed `<node>/<image>`. Wasted disk on nodes
  that never use an image, in exchange for placing a guest anywhere without
  waiting on a download.

## Backups

Building PBS. How it works, schedules and restores:
[PBS on Garage](../docs/src/backups.md#pbs).

1. **Install.** Console on VM 162: address `10.212.2.162/24`, gateway
   `10.212.2.1`, hostname `pbs.<lab_domain>`, onto `scsi0` (20G, the OS).
2. **Cache disk.** `scsi1` (8G) is the S3 datastore's local cache:
   *Administration* -> *Storage / Disks* -> *Directory* -> *Create*, ext4,
   name `pbs-cache`, *Add as Datastore* off -- mounts at
   `/mnt/datastore/pbs-cache`. PBS fills whatever it gets, so the disk is the
   limit. Grow in `guest_vm_pbs.tf`, then `growpart` + `resize2fs`.
3. **Datastore.** The backups live in Garage, bucket `proxmox-backups` -- see
   [machines/truenas.md](../machines/truenas.md#s3-garage). *Configuration* ->
   *S3 Endpoints* -> *Add*: id `garage`, `s3.<lab_domain>`, port `3900`,
   region `lab`, path-style, key `garage_pbs_*` from the vault. Then *Add
   Datastore*: type S3, name `proxmox-backups`, endpoint `garage`, bucket
   `proxmox-backups`, cache path from step 2.
4. **Token.** User `backup@pbs`, token `backup@pbs!lab`, permission
   **DatastoreBackup** on `/datastore/proxmox-backups`
5. **Storage entry.** *Datacenter* -> *Storage* -> *Add* -> *Proxmox Backup
   Server*, once for the whole cluster, namespace `lab`. Create the namespace
   first (*Content* -> *Add Namespace*): the token can't.
6. **Job.** *Datacenter* -> *Backup*, mode *snapshot*, notify on failure,
   fleecing on if guest disks sit on slow storage.
   **Exclude VM 162 from the job**: it cannot restore itself, and it would be
   backing up its own chunk store.
7. **Pocket ID login.** In Pocket ID, add client `pbs`: confidential, PKCE
   off, callback `https://pbs.<lab_domain>:8007`, allowed group `admins`.
   Then on PBS:
   ```sh
   proxmox-backup-manager openid create pocket-id \
     --issuer-url https://login.<app_domain> \
     --client-id <id> --client-key <secret> \
     --username-claim preferred_username --autocreate 0
   proxmox-backup-manager user create <name>@pocket-id
   proxmox-backup-manager acl update / Admin --auth-id <name>@pocket-id
   ```
   PBS's realm can't map groups, so each admin is created by hand and
   autocreate stays off. `root@pam` stays as break-glass.

**Moving an existing datastore** (how the iSCSI one, `pbs`, was retired):

1. Create the new one (steps 2-4), token ACL on it too.
2. On the new store: add namespace `lab`, then *Sync Jobs* -> *Add Pull*,
   source *Local* `pbs`, local
   owner `backup@pbs!lab` -- else the token can't extend the synced groups.
3. New PVE storage entry for it, then point the job at it. Today's entry has
   no encryption key. If one is ever set, the new entry needs the **same key**
   (copy `/etc/pve/priv/storage/<old>.enc` to `<new>.enc`) -- else no dedup,
   and the synced backups don't restore.
4. Recreate prune/GC/verify on the new store, they're per datastore.
5. Restore test, then remove the old storage entry, then the old datastore.

Job, prune, GC and verify schedules (the order matters):
[PBS on Garage](../docs/src/backups.md#pbs). Prune runs on root + full depth.

## VPN

VM 160 is the tailscale subnet router and exit node. The tailnet's policy and
DNS are the [network](../network/README.md) layer ([policy](../docs/src/networking.md#tailscale))'s; the guest only
joins it, by hand:

1. **Auth key.** Admin console -> *Settings -> Keys*: one-off, pre-approved,
   tag `tag:lab-router`. Tagged, so the node's key never expires; the routes
   and the exit node approve themselves through the policy's `autoApprovers`.
2. **Install and join** on the guest:

   ```sh
   sudo hostnamectl set-hostname vpn   # cloud-init set it once, from the old name
   curl -fsSL https://tailscale.com/install.sh | sh
   printf 'net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.forwarding = 1\n' \
     | sudo tee /etc/sysctl.d/99-tailscale.conf && sudo sysctl --system
   sudo tailscale up --auth-key=tskey-auth-... \
     --advertise-tags=tag:lab-router \
     --advertise-routes=10.212.2.0/24,10.212.4.0/24 \
     --advertise-exit-node \
     --accept-dns=false
   ```

Why `--accept-dns=false`, and why never `--snat-subnet-routes=false`:
[VPN VM](../docs/src/platform/vpn.md#gotchas).
