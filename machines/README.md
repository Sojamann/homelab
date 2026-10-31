# Machines (manual)

Physical hardware, brought to the point where automation can take over: an OS
installed, storage laid out, reachable over SSH with a key.

Manual on purpose. Pool topology and install-time disk layout are
once-per-machine decisions that are destructive to converge on, and an
automation tool has no dry run for them worth trusting. This layer repeats
every time hardware is added -- unlike [bootstrap](../bootstrap/README.md),
which happens once.

How the machines are used and restored: [Proxmox](../docs/src/platform/proxmox.md),
[TrueNAS](../docs/src/platform/truenas.md), [Storage](../docs/src/storage.md).

Assumes [network](../network/README.md) is in place. A machine takes a static
address from a VLAN that has to already exist.

## Order

1. **[TrueNAS](./truenas.md)** -- pools, datasets and shares on the NAS. Before
   the nodes, because where guest disks live is a decision the Proxmox install
   bakes in, and moving them afterwards is a migration rather than a setting.
2. **[Proxmox](./proxmox.md)** -- per node: install, SSH key, cluster
   membership. Repeat for each machine you add.

## Done when

For every node:

- `ssh root@<name>.<lab_domain> true` succeeds from your workstation
- `pvecm status` reports `Quorate: Yes`
- the node is uncommented in `machine-config/inventory/hosts.yml`
- `secrets/vault.yml` holds `truenas_api_key`, once the NAS exists

machine-config asserts these, so getting them wrong is loud rather than subtle.

## Devices

OS installed and ready to be used for its function.

| Name      | IP           | Device      | Function     |
|-----------|--------------|-------------|--------------|
| nas       | 10.212.2.150 | UGREEN NAS  | NAS          |
| nas       | 10.212.4.150 | (same box)  | storage, k8s VLAN |
| Titan     | 10.212.2.151 | ?           | Proxmox Host |
| Enceladus | 10.212.2.152 |             | reserved     |
| Mimas     | 10.212.2.153 |             | reserved     |
| Rhea      | 10.212.2.154 |             | reserved     |
| Iapetus   | 10.212.2.155 |             | reserved     |
| Dione     | 10.212.2.156 | ASUS Laptop | reserved     |

Reserved names do not exist yet; they stay commented out in
`machine-config/inventory/hosts.yml`.

> names derived from saturn's moons

This table is for people: it records what the hardware is and what it is for.
`machine-config/inventory/hosts.yml` carries the machine-facing half for
ansible, `network/unifi_dns.tf` carries the address again as an `A` record,
`guests/guest_nodes.tf` names the nodes that store guest disks, and
`flux/infrastructure/configs/proxmox/scrape.yaml` lists it as a scrape target.
None of them generates the others, so a new machine gets added in each one that
applies.
