locals {
  talos_version = "v1.13.10"

  # Extensions are baked into the image, so changing this list means a new
  # schematic, a new image and a `talosctl upgrade` onto it -- a reboot, and on
  # a one-node cluster, cluster downtime. It is not a runtime setting.
  #
  #   intel-ucode        -- microcode at boot. titan is Intel; an AMD node
  #                         needs siderolabs/amd-ucode instead, which is a
  #                         different schematic and so a different image.
  #   qemu-guest-agent   -- graceful shutdown from Proxmox, and the guest's
  #                         address in the UI.
  #   nvme-cli           -- democratic-csi over NVMe/TCP. The node plugin shells
  #                         out to it to attach a volume, so a PVC that never
  #                         mounts is the symptom of dropping it.
  #   util-linux-tools   -- the filesystem helpers CSI drivers shell out to.
  #
  # iscsi-tools is deliberately absent: the storage transport is NVMe/TCP.
  talos_extensions = [
    "siderolabs/intel-ucode",
    "siderolabs/qemu-guest-agent",
    "siderolabs/nvme-cli",
    "siderolabs/util-linux-tools",
  ]

  talos_disk_image_url = "https://factory.talos.dev/image/${talos_image_factory_schematic.talos.id}/${local.talos_version}/nocloud-amd64.qcow2"
}

resource "talos_image_factory_schematic" "talos" {
  schematic = yamlencode({
    customization = {
      systemExtensions = {
        officialExtensions = local.talos_extensions
      }
    }
  })
}

# The schematic id, so the cluster layer's copy of the extension list can be
# checked against this one by eye when either changes.
output "talos_schematic_id" {
  description = "Image factory schematic the Talos guests boot"
  value       = talos_image_factory_schematic.talos.id
}
