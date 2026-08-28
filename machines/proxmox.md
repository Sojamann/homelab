# Proxmox Setup (manual)

Per node, once. Everything after this is [machine-config](../machine-config/README.md).
Set up [truenas](./truenas.md) first -- bulk storage comes over NFS from the NAS.

1. **Install Proxmox VE 9** from the ISO. Static IP from the physical range
   (`10.212.2.151-159`), root password. Under *Options* on the disk screen:

   - **`maxvz=0`** 
   - **`maxroot` = disk size**. 

   `maxvz=0` only skips the LVM-thin pool -- it does not hand the space
   to root, which otherwise keeps its default quarter of the disk and strands
   the rest unallocated in the `pve` volume group (on a 128 GB node: ~32 GB
   root, ~80 GB thin pool, unmovable). Everything -- guest disks as qcow2,
   ISOs, templates, backups -- then lives on `local`, configured by
   machine-config.

2. **Authorise your SSH key** -- the only credential the automation ever uses:
   ```sh
   ssh-copy-id root@10.212.2.<n>
   ```
   Instant `No route to host` means your workstation, not the node -- see
   [workstation](../bootstrap/workstation.md).

3. **Join the cluster.** Manual because `pvecm` authenticates with root@pam's
   *password*, which deliberately does not live in the repo.

   **Once for the whole lab**, on dione only -- never again on any other node,
   or you get two separate one-node clusters:
   ```sh
   pvecm create lab
   ```
   Worth doing while dione is alone: a single-node cluster is quorate.

   **On every other node**, only while it still has no VMs (joining overwrites
   parts of its config):
   ```sh
   pvecm add 10.212.2.151    # the leader
   ```

   > At exactly two nodes quorum needs both up. Get to three reasonably soon.

4. Uncomment the node in `machine-config/inventory/hosts.yml`, add an `A`
   record in `network/unifi_dns.tf`, and add it to `guests/guest_nodes.tf` if it
   is to store guest disks.
