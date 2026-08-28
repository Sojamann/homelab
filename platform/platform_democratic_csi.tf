# Persistent volumes, as zvols on the NAS shared over NVMe/TCP.
locals {
  democratic_csi_version = "0.15.1" # chart; appVersion 1.0

  # Both are the NAS's second interface, in the k8s network, so neither path
  # crosses the router. `nas-k8s` is the same box as `nas`.
  #
  # One is a name and one an address, deliberately:
  #
  #   the API is HTTPS against the NAS's ACME certificate, so it must be a name
  #     that certificate carries -- `nas` and `nas-k8s` are both SANs on it.
  #     `allowInsecure` stays false; a TLS error is a missing SAN, and the fix
  #     is the certificate, not the driver.
  #
  #   the data path is `nvme connect`, which does no TLS and runs on the volume
  #     attach path. A name there would put DNS between a pod and its disk for
  #     no benefit.
  nas_api_host = "nas-k8s.${var.lab_domain}"
  nas_address  = "10.212.4.150"

  # The numeric id of the NVMe-oF port (TCP, 10.212.4.150:4420) created by hand
  truenas_nvmeof_port_id = 1

  # Neither is created by hand: the driver creates both, and `fast/k8s-csi`
  # above them, with `create_ancestors` on the first PVC. Their properties are
  # therefore whatever they inherit from the pool root, which is where
  # machines/truenas.md sets atime and compression.
  csi_dataset_volumes   = "fast/k8s-csi/vols"
  csi_dataset_snapshots = "fast/k8s-csi/snaps"
}

# The driver's node plugin mounts the host, /dev and the host network. Talos
# runs PodSecurity admission with `enforce: baseline` for everything outside
# kube-system, which rejects all three -- so the namespace needs the privileged
# label, explicitly and visibly, rather than inheriting kube-system's built-in
# exemption by hiding in it.
resource "kubectl_manifest" "democratic_csi_namespace" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Namespace"
    metadata = {
      name = "democratic-csi"
      labels = {
        "pod-security.kubernetes.io/enforce" = "privileged"
      }
    }
  })
}

resource "helm_release" "democratic_csi" {
  name       = "democratic-csi"
  repository = "https://democratic-csi.github.io/charts/"
  chart      = "democratic-csi"
  version    = local.democratic_csi_version
  namespace  = "democratic-csi"

  # The chart renders a VolumeSnapshotClass, which is not a kind that exists
  # until the snapshot controller's CRDs are in.
  depends_on = [
    kubectl_manifest.democratic_csi_namespace,
    helm_release.snapshot_controller,
  ]

  values = [yamlencode({
    # Cluster-unique, and it is what the StorageClass provisioner name and the
    # kubelet's socket path are both derived from. Changing it later orphans
    # every existing PV.
    csiDriver = { name = "org.democratic-csi.nvmeof" }

    controller = {
      # One node. Raise alongside the second control plane.
      replicaCount = 1
    }

    driver = {
      config = {
        driver = "freenas-api-nvmeof"

        # The `freenas-api-*` drivers are flagged EXPERIMENTAL upstream. Taken
        # knowingly: the alternative, `freenas-nvmeof`, does the same work over
        # ssh with a sudo-capable account on the NAS, which is a much larger
        # thing to hand a cluster than a scoped API key.
        httpConnection = {
          protocol      = "https"
          host          = local.nas_api_host
          port          = 443
          allowInsecure = false
          apiVersion    = 2
          # apiKey arrives via set_sensitive below.
        }

        zfs = {
          datasetParentName                  = local.csi_dataset_volumes
          detachedSnapshotsDatasetParentName = local.csi_dataset_snapshots
          zvolBlocksize                      = "16K" # (driver default)
          zvolEnableReservation              = true  # disable over-subscribing storage
        }

        nvmeof = {
          transports = ["tcp://${local.nas_address}:4420"]

          # Subsystem NQNs are per-volume and must be unique on the target.
          # One cluster, so a prefix is enough to tell CSI subsystems apart
          # from anything created by hand.
          namePrefix = "csi-"

          ports = [local.truenas_nvmeof_port_id]
        }
      }
    }

    storageClasses = [{
      name                 = "fast"
      annotations          = {}
      defaultClass         = true
      allowVolumeExpansion = true
      reclaimPolicy        = "Delete"
      volumeBindingMode    = "WaitForFirstConsumer"


      parameters = {
        fsType = "ext4"

        # Restore-time behaviour, and the reason it is not the default.
        #
        # Restoring from a snapshot normally means `zfs clone`, and a clone
        # pins its origin snapshot, which pins the source zvol. Snapshot PVC-A,
        # restore it as PVC-B, and deleting PVC-A then fails with "filesystem
        # has dependent clones" until PVC-B is gone
        #
        # `true` makes the restore a send/recv into an independent zvol
        # instead. It is slow and costs the volume's full size, which is the
        # right place to pay: restores are rare, snapshots are not.
        detachedVolumesFromSnapshots = "true"
      }

      # Nothing authenticates this path -- no CHAP equivalent, no TLS. What
      # stands in for it is reachability: the listener binds only the NAS's k8s
      # address, and a policy stops the other networks routing to it.
      secrets = {}
    }]

    volumeSnapshotClasses = [{
      name           = "fast"
      deletionPolicy = "Delete"

      parameters = {
        # Snapshot-time behaviour, and the counterpart to the storage class
        # parameter above.
        #
        # `false` is a plain `zfs snapshot`: instant and cheap. 
        # this is not a backup as it lives inside the source zvol.
        #
        # `fast/k8s-csi/snaps` therefore stays empty in normal operation. It
        # is required configuration regardless, and it is where a snapshot
        # taken with a detached class would land.
        detachedSnapshots = "false"
      }

      secrets = {}
    }]
  })]

  # Out of `values` on purpose: `values` is a plain string in state and in
  # every plan diff. This one is redacted in both.
  set_sensitive = [{
    name  = "driver.config.httpConnection.apiKey"
    value = var.truenas_api_key
  }]
}

output "storage" {
  description = "What this layer gave the cluster"
  value = {
    storage_class        = "fast (default)"
    volume_snapshotclass = "fast"
    backend              = "${local.nas_api_host} -- zvols in ${local.csi_dataset_volumes}, NVMe/TCP on ${local.nas_address}:4420"
  }
}
