locals {
  # `.161`, the second of the `.160+` permanent guests. Unlike every other
  # guest here the address is *not* written into the VM by this layer -- Home
  # Assistant OS ignores cloud-init entirely, so it is set once by hand at the
  # console and this local only drives the id, the MAC and the DNS record. It
  # is the one address in this repo that a guest could disagree with.
  home_assistant_vm_id = 161
  home_assistant_ip    = "10.212.2.161"
  home_assistant_mac   = "BC:24:11:00:01:61"
}

resource "proxmox_virtual_environment_vm" "home_assistant" {
  node_name = local.cluster_primary
  vm_id     = local.home_assistant_vm_id
  name      = "home-assistant"
  tags      = ["terraform", "home-assistant"]

  description = <<-EOT
    Managed by the guests layer, and nothing else. Home Assistant OS is an
    appliance: it updates itself, and its configuration lives in the VM rather
    than in this repo -- see the trade-offs in guests/README.md.
  EOT

  operating_system { type = "l26" }

  # The first guest here that is not SeaBIOS: Home Assistant OS boots UEFI
  # only. `pre_enrolled_keys = false` is the secure-boot switch -- the image is
  # unsigned, and with keys enrolled it does not boot at all.
  bios    = "ovmf"
  machine = "q35"

  efi_disk {
    datastore_id      = local.guest_datastore
    file_format       = "raw"
    type              = "4m"
    pre_enrolled_keys = false
  }

  # Home Assistant is idle-bound, not CPU-bound -- nothing here resembles
  # netbird's per-flow WireGuard argument for its cores.
  cpu {
    cores = 2
    type  = "host"
  }

  memory {
    dedicated = 6144
  }

  scsi_hardware = "virtio-scsi-single"

  disk {
    datastore_id = local.guest_datastore
    interface    = "scsi0"

    # `file_id` rather than `import_from`, because the image is decompressed on
    # the way in and Proxmox will not import one of those -- see
    # guest_images.tf. Home Assistant OS grows its data partition to fill
    # whatever it is given on first boot, and Proxmox can grow this disk
    # online, so 32 is a floor rather than a guess.
    file_id     = proxmox_download_file.images["${local.cluster_primary}/haos"].id
    size        = 32
    file_format = "qcow2"
    iothread    = true
    discard     = "on"
    ssd         = true
  }

  # No `initialization` block on purpose. Home Assistant OS reads no cloud-init
  # of any kind, so a cloud-init drive here would be a disk nothing ever looks
  # at -- and, worse, a place where an address could be written that the guest
  # does not use. Address, DNS and hostname are set at the console instead.

  network_device {
    bridge      = "vmbr0"
    model       = "virtio"
    mac_address = local.home_assistant_mac
  }

  # Shipped in the image, so this holds create open until the appliance is
  # actually answering.
  agent { enabled = true }

  started = true
  on_boot = true

  stop_on_destroy = true

  # This is the guest that cannot be rebuilt. Home Assistant OS updates itself
  # in place, so the image above is install media and nothing more -- but
  # bumping its version mints a new file, which would change `file_id`, replace
  # the disk, and take every pairing, automation and Matter credential with it.
  # There are no backups yet (see the `+backup` todo), so that is not a
  # recoverable mistake.
  #
  # Breaking the link means a version bump re-downloads the image and leaves
  # this VM alone -- which is correct, because a running appliance has long
  # since stopped resembling the image it was born from. A deliberate rebuild
  # is `tofu taint`.
  lifecycle {
    ignore_changes = [disk[0].file_id]
  }
}

resource "unifi_dns_record" "home_assistant" {
  name   = "ha.${var.lab_domain}"
  type   = "A"
  record = local.home_assistant_ip

  ttl = 0 # auto
}

output "home_assistant" {
  description = "The Home Assistant appliance. Its address is set at the console, not here."
  value = {
    node  = local.cluster_primary
    vm_id = proxmox_virtual_environment_vm.home_assistant.vm_id
    ip    = local.home_assistant_ip
    fqdn  = unifi_dns_record.home_assistant.name
    url   = "http://${unifi_dns_record.home_assistant.name}:8123"
  }
}
