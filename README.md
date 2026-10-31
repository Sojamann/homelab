# HOMELAB

Infrastructure as code for a home lab: network, Proxmox, TrueNAS, a Talos
cluster and the workloads on it.

Docs: <https://sojamann.github.io/homelab/> -- topic pages (how it works,
how to restore it) plus the build guide below, published from `main` by
`.github/workflows/docs.yml`. Build them locally:

```sh
mise run docs           # serve with live reload
mise run docs build     # write docs/book/ and check its links
```

## Stages

Set of stages executed in order where each stage depends on the preceding ones

| Layer                                        | Tool      | Owns                                          |
|----------------------------------------------|-----------|-----------------------------------------------|
| [bootstrap](./bootstrap/README.md)           | by hand   | Controller, workstation, Cloudflare zone      |
| [network](./network/README.md)               | OpenTofu  | VLANs, DHCP pools, DNS records, firewall, wifi |
| [machines](./machines/README.md)             | by hand   | OS installs, ZFS pools, SSH keys, PVE cluster |
| [machine-config](./machine-config/README.md) | Ansible   | Host state                                    |
| [guests](./guests/README.md)                 | OpenTofu  | VMs and containers                            |
| [cluster](./cluster/README.md)               | OpenTofu  | Talos, Kubernetes, the CNI                    |
| [platform](./platform/README.md)             | OpenTofu  | Storage, GitOps, and what else workloads assume |
| [flux](./flux/README.md)                     | Flux      | The workloads themselves                      |

## Working with it

```sh
mise run network plan     # args are forwarded to tofu
mise run machine-config
mise run guests plan
mise run cluster plan
mise run platform plan
mise run save "<msg>"     # commit secrets/ (state) and this repo together
mise run s3 volsync ls s3://k8s-backups/   # aws s3 against Garage, key from the vault
```

Updates arrive as Renovate PRs, see
[Maintenance](docs/src/maintenance.md#renovate); the vault and the other
files in `secrets/` are described in [Access & secrets](docs/src/access.md#vault).
