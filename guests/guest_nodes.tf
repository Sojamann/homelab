# description of the trough opentofu used proxmox nodes
locals {
  # Must match `cluster_primary` in
  # machine-config/inventory/group_vars/proxmox.yml, which is where the
  # once-per-cluster ansible tasks run.
  cluster_primary = "titan"

  nodes = toset([
    "titan",
  ])

  image_datastore = "local"
  guest_datastore = "local"

  # the proxmox endpoint (can be any of the nodes)
  proxmox_endpoint = "https://${local.cluster_primary}.${var.lab_domain}:8006/"
}
