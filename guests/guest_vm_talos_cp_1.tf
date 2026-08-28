locals {
  # VLAN-ID 40 + 4th ip octet (DO NOT CHANGE)
  # -> tightly coupled to cluster/ stage's inference of IPs

  # `.10` of the k8s network. Control planes are `.10-.12`, workers `.13-.19`,
  talos_cp_1_vm_id = 4010
  talos_cp_1_ip    = "10.212.4.10"
  talos_cp_1_mac   = "BC:24:11:00:04:10"
}

resource "proxmox_virtual_environment_vm" "talos_cp_1" {
  node_name = local.cluster_primary
  vm_id     = local.talos_cp_1_vm_id
  name      = "talos-cp-1"
  tags      = ["terraform", "talos", "talos-controlplane"]

  description = <<-EOT
    Managed by the guests layer, configured by the cluster layer. Talos from
    the image factory; this layer leaves it in maintenance mode.
  EOT

  operating_system { type = "l26" }

  cpu {
    cores = 4
    type  = "host"
  }

  memory {
    dedicated = 16384 # 16 GB
    floating  = 0
  }

  scsi_hardware = "virtio-scsi-single"

  disk {
    datastore_id = local.guest_datastore
    interface    = "scsi0"
    import_from  = proxmox_download_file.images["${local.cluster_primary}/talos-nocloud"].id
    size         = 40
    file_format  = "qcow2"
    iothread     = true
    discard      = "on"
    ssd          = true
  }

  initialization {
    datastore_id = local.guest_datastore

    ip_config {
      ipv4 {
        address = "${local.talos_cp_1_ip}/24"
        gateway = "10.212.4.1"
      }
    }
    dns {
      servers = ["10.212.4.1"]
      domain  = var.lab_domain
    }
  }

  network_device {
    bridge      = "vmbr0"
    model       = "virtio"
    vlan_id     = 40
    mac_address = local.talos_cp_1_mac
  }

  # The qemu-guest-agent extension is in the image, but Talos starts extension
  # services once the machine is configured -- and this layer leaves the node
  # unconfigured. So it is not certain the agent answers here, and if it does
  # not, create waits for it and fails.
  #
  # Left on to find out. If an apply hangs on "waiting for agent", set this to
  # false: the node still boots, and readiness is the cluster layer's business
  # anyway.
  agent { enabled = true }

  started = true
  on_boot = true

  # Otherwise a destroy fails on a running VM.
  stop_on_destroy = true
}

resource "unifi_dns_record" "talos_cp_1" {
  name   = "talos-cp-1.${var.lab_domain}"
  type   = "A"
  record = local.talos_cp_1_ip

  ttl = 0 # auto
}

output "talos_cp_1" {
  description = "The first Talos node, in maintenance mode until the cluster layer runs"
  value = {
    node  = local.cluster_primary
    vm_id = proxmox_virtual_environment_vm.talos_cp_1.vm_id
    ip    = local.talos_cp_1_ip
    fqdn  = unifi_dns_record.talos_cp_1.name
    talos = "talosctl --talosconfig secrets/talosconfig -n ${unifi_dns_record.talos_cp_1.name} version"
  }
}
