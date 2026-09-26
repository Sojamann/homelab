locals {
  # `.162`, the third of the `.160+` permanent guests.
  pbs_vm_id = 162
  pbs_ip    = "10.212.2.162"
  pbs_mac   = "BC:24:11:00:01:62"
}

resource "proxmox_virtual_environment_vm" "pbs" {
  node_name = local.cluster_primary
  vm_id     = local.pbs_vm_id
  name      = "pbs"
  tags      = ["terraform", "pbs"]

  description = <<-EOT
    Proxmox Backup Server. This layer builds the VM and attaches the install
    media; the installer, the datastore on the NAS and the cluster's storage
    entry are all done by hand -- see guests/README.md.
  EOT

  operating_system { type = "l26" }

  cpu {
    cores = 2
    type  = "host"
  }

  # PBS keeps its chunk index in memory during garbage collection and verify,
  # which is the only thing here that wants more than a Debian box would.
  memory {
    dedicated = 4096
  }

  scsi_hardware = "virtio-scsi-single"

  disk {
    datastore_id = local.guest_datastore
    interface    = "scsi0"
    size         = 20
    file_format  = "qcow2"
    iothread     = true
    discard      = "on"
    ssd          = true
  }

  # `interface` spelled out because `boot_order` below names it.
  cdrom {
    file_id   = proxmox_download_file.images["${local.cluster_primary}/pbs"].id
    interface = "ide3"
  }

  # Disk first, so this is a one-liner rather than a step in the runbook: the
  # empty disk falls through to the ISO on the first boot, and the installed
  # system wins on every boot after. The media stays attached on purpose --
  # detaching it is drift, and bumping the ISO version only swaps a file the
  # installed guest has long since stopped reading.
  boot_order = ["scsi0", "ide3"]

  network_device {
    bridge      = "vmbr0"
    model       = "virtio"
    mac_address = local.pbs_mac
  }

  agent { enabled = false }

  started = true
  on_boot = true

  stop_on_destroy = true
}

resource "unifi_dns_record" "pbs" {
  name   = "pbs.${var.lab_domain}"
  type   = "A"
  record = local.pbs_ip

  ttl = 0 # auto
}

output "pbs" {
  description = "The backup server. Its address is set in the installer, not here."
  value = {
    node  = local.cluster_primary
    vm_id = proxmox_virtual_environment_vm.pbs.vm_id
    ip    = local.pbs_ip
    fqdn  = unifi_dns_record.pbs.name
    url   = "https://${unifi_dns_record.pbs.name}:8007"
  }
}
