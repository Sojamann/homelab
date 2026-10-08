locals {
  # First in the `.160+` range network/README.md reserves for permanent,
  # statically addressed guests. Written into the guest by cloud-init, so this
  # is the address rather than a note about one someone typed: the DNS record,
  # the guest and this local cannot disagree.
  vpn_ip = "10.212.2.160"

  # Chosen, not discovered, so a rebuilt guest keeps its identity on the
  # network. `BC:24:11` is Proxmox's OUI, which keeps it clear of real
  # hardware; the last byte is the host part of the address, so guests stay
  # distinct from each other by construction.
  vpn_mac = "BC:24:11:00:01:60"
}

resource "proxmox_virtual_environment_file" "vpn_cloud_init" {
  node_name    = local.cluster_primary
  datastore_id = local.guest_datastore
  content_type = "snippets"

  source_raw {
    # Still the old name: a new file would be a new `user_data_file_id`, and
    # that is a replacement of the VM, not an update.
    file_name = "netbird-cloud-init.yaml"

    # The login lives here and not in `user_account`, because `cicustom
    # user=` replaces the user-data Proxmox would have generated instead of
    # adding to it -- `ciuser` and `sshkeys` stay in the VM's config but are
    # never read once this snippet exists. Address and DNS are unaffected;
    # those travel as network-data, which is a separate channel.
    data = <<-EOT
      #cloud-config
      users:
        - name: ubuntu
          groups: [adm, sudo]
          shell: /bin/bash
          sudo: "ALL=(ALL) NOPASSWD:ALL"
          ssh_authorized_keys:
            - ${trimspace(tls_private_key.guests.public_key_openssh)}

      package_update: true
      packages:
        - qemu-guest-agent
      runcmd:
        - systemctl enable --now qemu-guest-agent
    EOT
  }
}

resource "proxmox_virtual_environment_vm" "vpn" {
  node_name = local.cluster_primary
  vm_id     = 160
  name      = "vpn"
  tags      = ["terraform", "vpn"]

  description = <<-EOT
    Managed by the guests layer. Ubuntu 24.04 from the cloud image; the
    tailscale subnet router and exit node, installed by hand -- see
    guests/README.md.
  EOT

  operating_system { type = "l26" }

  # Two cores, because WireGuard is CPU-bound per flow and every byte reaching
  # the lab from outside crosses this guest.
  cpu {
    cores = 2
    type  = "host"
  }

  memory {
    dedicated = 2048
  }

  scsi_hardware = "virtio-scsi-single"

  disk {
    datastore_id = local.guest_datastore
    interface    = "scsi0"
    import_from  = proxmox_download_file.images["${local.cluster_primary}/ubuntu-24.04-cloudimg"].id
    size         = 16
    file_format  = "qcow2"
    iothread     = true
    discard      = "on"
    ssd          = true
  }

  initialization {
    datastore_id = local.guest_datastore

    # This snippet becomes the guest's whole user-data -- see the comment on
    # the resource -- so the user and its key are defined there, not here.
    user_data_file_id = proxmox_virtual_environment_file.vpn_cloud_init.id

    ip_config {
      ipv4 {
        address = "${local.vpn_ip}/24"
        gateway = "10.212.2.1"
      }
    }

    dns {
      servers = ["10.212.2.1"]
      domain  = var.lab_domain
    }
  }

  network_device {
    bridge      = "vmbr0"
    model       = "virtio"
    mac_address = local.vpn_mac
  }

  # Installed by the snippet above, so this holds create open until cloud-init
  # has finished its first boot -- which is the point: the resource is not
  # done until the guest is actually answering.
  agent { enabled = true }

  started = true
  on_boot = true

  # Otherwise a destroy fails on a running VM.
  stop_on_destroy = true
}

resource "unifi_dns_record" "vpn" {
  name   = "vpn.${var.lab_domain}"
  type   = "A"
  record = local.vpn_ip

  ttl = 0 # auto
}

output "vpn" {
  description = "The tailscale subnet router, once tailscale is installed on it"
  value = {
    node  = local.cluster_primary
    vm_id = proxmox_virtual_environment_vm.vpn.vm_id
    ip    = local.vpn_ip
    fqdn  = unifi_dns_record.vpn.name
    ssh   = "ssh -i secrets/guests-ssh-key ubuntu@${unifi_dns_record.vpn.name}"
  }
}

moved {
  from = proxmox_virtual_environment_file.netbird_cloud_init
  to   = proxmox_virtual_environment_file.vpn_cloud_init
}

moved {
  from = proxmox_virtual_environment_vm.netbird
  to   = proxmox_virtual_environment_vm.vpn
}
