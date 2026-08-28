# The second CSI driver: a directory per PV on the NAS, over NFS.
locals {
  csi_nfs_version = "4.13.4" # chart == appVersion

  csi_nfs_share = "/mnt/slow/k8s-csi"
}

# The node plugin mounts the host and /dev and runs privileged, which Talos's
# `baseline` enforcement rejects everywhere but kube-system. Same label, same
# reason, as the democratic-csi namespace.
resource "kubectl_manifest" "csi_nfs_namespace" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Namespace"
    metadata = {
      name   = "csi-driver-nfs"
      labels = { "pod-security.kubernetes.io/enforce" = "privileged" }
    }
  })
}

resource "helm_release" "csi_driver_nfs" {
  name       = "csi-driver-nfs"
  repository = "https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts"
  chart      = "csi-driver-nfs"
  version    = local.csi_nfs_version
  namespace  = "csi-driver-nfs"

  depends_on = [kubectl_manifest.csi_nfs_namespace]

  values = [yamlencode({
    controller = {
      # One node. Raise alongside the second control plane.
      replicas = 1

      # Off. This driver's snapshots are tarballs written into the share --
      # inside the dataset the NAS is already snapshotting, so they would cost
      # a second full copy and then be snapshotted themselves. `bulk` is
      # protected by the ZFS task on `slow/k8s-csi`, not by VolumeSnapshot.
      enableSnapshotter = false
    }

    # Not the bundled one: platform_snapshot_controller.tf already installs it,
    # cluster-wide and shared with democratic-csi.
    externalSnapshotter = { enabled = false }

    storageClass = {
      create = true
      name   = "bulk"

      parameters = {
        server = local.nas_address
        share  = local.csi_nfs_share
      }

      # in case of acidental deletion of the pvc use restore data using
      # the snapshots taken via snapshot tasks on the NAS
      reclaimPolicy = "Delete"

      # Immediate, unlike `fast`: an NFS export has no topology to wait for.
      volumeBindingMode = "Immediate"

      # v4.1 only -- the export offers nothing else. `hard` so a NAS reboot
      # blocks IO until it returns instead of handing pods an EIO.
      mountOptions = ["nfsvers=4.1", "hard"]
    }
  })]

  lifecycle {
    precondition {
      condition     = fileexists(local.kubeconfig)
      error_message = "no secrets/kubeconfig -- run `mise run cluster apply` first."
    }
  }
}

output "storage_bulk" {
  description = "The NFS half"
  value = {
    storage_class = "bulk"
    backend       = "${local.nas_address}:${local.csi_nfs_share} -- one directory per PV"
  }
}
