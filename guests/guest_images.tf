# hand written list of images that is stored on *each* node unused images should
# be removed from this list.
#
# `content_type` decides what an entry can become: `vztmpl` is an LXC root
# filesystem, `import` a disk image a VM boots. Proxmox keeps them in separate
# namespaces on the same storage, so the same distribution needs one entry per
# kind.
locals {
  images = {
    # Ubuntu names it `.img`, but the magic bytes are `QFI\xfb` -- it is a
    # qcow2. Renamed on the way in because `import` accepts only ova, ovf,
    # qcow2, raw and vmdk (`IMPORT_EXT_RE_1` in PVE/Storage.pm) and rejects
    # `.img` outright.
    "ubuntu-24.04-cloudimg" = {
      content_type       = "import"
      url                = "https://cloud-images.ubuntu.com/releases/noble/release-20260826/ubuntu-24.04-server-cloudimg-amd64.img"
      file_name          = "ubuntu-24.04-server-cloudimg-amd64-20260826.qcow2"
      checksum           = "d0fe84bb5f80853425fa6be28e2c106f30104c3cfe8611933f2e65c9b63f0e30"
      checksum_algorithm = "sha256"
    }

    # Talos, built to order by the image factory -- see guest_talos_image.tf
    "talos-nocloud" = {
      content_type       = "import"
      url                = local.talos_disk_image_url
      file_name          = "talos-${local.talos_version}-nocloud-amd64.qcow2"
      checksum           = null
      checksum_algorithm = null
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

  overwrite_unmanaged = true
}
