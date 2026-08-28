# VolumeSnapshot, which Kubernetes does not ship.
#
# The `VolumeSnapshot` CRDs and the controller that acts on them are an
# out-of-tree component: kubernetes-csi/external-snapshotter. Neither
# Kubernetes nor Talos installs them, and without them `VolumeSnapshot` is not
# a kind the apiserver knows -- democratic-csi's snapshotter sidecar starts and
# finds nothing to watch, and the VolumeSnapshotClass it renders cannot be
# created at all.
#
# It is here rather than inside the storage component because the CRDs are
# cluster-scoped and shared: a second CSI driver would use the same ones.

locals {
  # Chart 5.2.0 -> external-snapshotter v8.6.0.
  snapshot_controller_version = "5.2.0"
}

resource "helm_release" "snapshot_controller" {
  name       = "snapshot-controller"
  repository = "https://piraeus.io/helm-charts/"
  chart      = "snapshot-controller"
  version    = local.snapshot_controller_version

  namespace        = "snapshot-controller"
  create_namespace = true

  values = [yamlencode({
    installCRDs = true

    controller = {
      # Raise this alongside the second control plane.
      replicaCount = 1
    }

    webhook = { enabled = false }
  })]

  lifecycle {
    precondition {
      condition     = fileexists(local.kubeconfig)
      error_message = "no secrets/kubeconfig -- run `mise run cluster apply` first."
    }
  }
}
