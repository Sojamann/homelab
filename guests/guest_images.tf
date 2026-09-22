# hand written list of images that is stored on *each* node unused images should
# be removed from this list.
#
# `content_type` decides what an entry can become: `vztmpl` is an LXC root
# filesystem, `import` a disk image a VM boots. Proxmox keeps them in separate
# namespaces on the same storage, so the same distribution needs one entry per
# kind.
#
# `iso` is the third, and only because of compression: a file Proxmox
# decompresses on the way in cannot be used with a disk's `import_from`, only
# with its `file_id`, and `file_id` reads out of the `iso` namespace. Upstream
# publishing a `.xz` is therefore the whole reason an entry is `iso` rather
# than `import` -- see the haos entry.
locals {
  images = {
    # Ubuntu names it `.img`, but the magic bytes are `QFI\xfb` -- it is a
    # qcow2. Renamed on the way in because `import` accepts only ova, ovf,
    # qcow2, raw and vmdk (`IMPORT_EXT_RE_1` in PVE/Storage.pm) and rejects
    # `.img` outright.
    "ubuntu-24.04-cloudimg" = {
      content_type            = "import"
      url                     = "https://cloud-images.ubuntu.com/releases/noble/release-20260826/ubuntu-24.04-server-cloudimg-amd64.img"
      file_name               = "ubuntu-24.04-server-cloudimg-amd64-20260826.qcow2"
      checksum                = "d0fe84bb5f80853425fa6be28e2c106f30104c3cfe8611933f2e65c9b63f0e30"
      checksum_algorithm      = "sha256"
      decompression_algorithm = null
      overwrite               = true
    }

    # Talos, built to order by the image factory -- see guest_talos_image.tf
    "talos-nocloud" = {
      content_type            = "import"
      url                     = local.talos_disk_image_url
      file_name               = "talos-${local.talos_version}-nocloud-amd64.qcow2"
      checksum                = null
      checksum_algorithm      = null
      decompression_algorithm = null
      overwrite               = true
    }

    # Home Assistant OS, which upstream ships only as `.qcow2.xz` -- no plain
    # qcow2 and no checksum of any kind, so this entry cannot verify what it
    # downloads. Proxmox has no xz support, but its zst decompression reads xz
    # archives, which is why the algorithm here does not match the extension.
    #
    # `.img` on the way in: the name has to survive Proxmox's extension check,
    # and the decompressed content is a qcow2 whatever it is called.
    #
    # `overwrite` off is not optional. The check compares the size the URL
    # reports against the size on disk -- compressed against decompressed here,
    # which can never match -- so leaving it on re-downloads 500MB on every
    # single apply.
    "haos" = {
      content_type            = "iso"
      url                     = "https://github.com/home-assistant/operating-system/releases/download/18.3/haos_ova-18.3.qcow2.xz"
      file_name               = "haos_ova-18.3.qcow2.img"
      checksum                = null
      checksum_algorithm      = null
      decompression_algorithm = "zst"
      overwrite               = false
    }
  }
}

# images are stored as "<node>/<image key>" e.g. "titan/ubuntu-24.04-cloudimg"
resource "proxmox_download_file" "images" {
  for_each = {
    for pair in setproduct(local.nodes, keys(local.images)) :
    "${pair[0]}/${pair[1]}" => { node = pair[0], image = local.images[pair[1]] }
  }

  node_name    = each.value.node
  datastore_id = local.image_datastore
  content_type = each.value.image.content_type

  url       = each.value.image.url
  file_name = each.value.image.file_name

  checksum           = each.value.image.checksum
  checksum_algorithm = each.value.image.checksum_algorithm

  decompression_algorithm = each.value.image.decompression_algorithm

  overwrite           = each.value.image.overwrite
  overwrite_unmanaged = true
}
