# installing: Flux Operator + Flux Instance
locals {
  flux_operator_version = "0.59.0" # chart == operator
  flux_version          = "2.9.5"  # the distribution it installs

  # Public, so no `pullSecret`. The repo is a submodule at ../flux.
  flux_sync_name = "homelab-apps"
  flux_sync_url  = "https://github.com/Sojamann/homelab-apps.git"
  flux_sync_ref  = "refs/heads/main"
  flux_sync_path = "clusters/lab"
}

resource "helm_release" "flux_operator" {
  name       = "flux-operator"
  repository = "oci://ghcr.io/controlplaneio-fluxcd/charts"
  chart      = "flux-operator"
  version    = local.flux_operator_version

  namespace        = "flux-system"
  create_namespace = true

  lifecycle {
    precondition {
      condition     = fileexists(local.kubeconfig)
      error_message = "no secrets/kubeconfig -- run `mise run cluster apply` first."
    }
  }
}

# Environment specific (+non exposed) cluster configuration sippets
#
# Manifests reference `${lab_domain}` and a Kustomization substitutes it at
# reconcile time via `postBuild.substituteFrom`.
#
# Anything the public apps repo needs and may not hold. The two domains, and
# the Telegram chat id -- which is no credential (the bot token in OpenBao is),
# but names a private group and so stays out of a public repo. `acme_email`
# left with the issuer that wanted it, which is this layer's now.
resource "kubectl_manifest" "flux_cluster_vars" {
  depends_on = [helm_release.flux_operator]

  sensitive_fields = [
    "stringData.lab_domain",
    "stringData.app_domain",
    "stringData.telegram_chat_id",
  ]

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Secret"
    metadata = {
      name      = "cluster-vars"
      namespace = "flux-system"
    }
    stringData = {
      lab_domain       = var.lab_domain
      app_domain       = var.app_domain
      telegram_chat_id = var.telegram_chat_id
    }
  })
}

# FluxInstance.
# The CRD rejects anything but `flux`, and it must sit in the operator's own namespace.
resource "kubectl_manifest" "flux_instance" {
  depends_on = [helm_release.flux_operator]

  yaml_body = yamlencode({
    apiVersion = "fluxcd.controlplane.io/v1"
    kind       = "FluxInstance"
    metadata = {
      name      = "flux"
      namespace = "flux-system"
    }
    spec = {
      distribution = {
        version  = local.flux_version
        registry = "ghcr.io/fluxcd"
      }

      # default set minus 'automation' (it commits tags back)
      components = [
        "source-controller",
        "kustomize-controller",
        "helm-controller",
        "notification-controller",
      ]

      cluster = {
        type = "kubernetes"
        # One node. Raise alongside the second control plane.
        size          = "small"
        networkPolicy = true
      }

      # `spec.storage` is deliberately unset, leaving source-controller on an
      # emptyDir. A PVC here would make Flux depend on democratic-csi -- and
      # the point of Flux is to still work when something else does not.

      sync = {
        kind = "GitRepository"

        # Names the GitRepository *and* the root Kustomization, and is
        # immutable. Left to default it would be "flux-system", which reads
        # like a namespace in every `sourceRef` in the apps repo.
        name     = local.flux_sync_name
        url      = local.flux_sync_url
        ref      = local.flux_sync_ref
        path     = local.flux_sync_path
        interval = "1m"
      }
    }
  })
}

output "gitops" {
  description = "What reconciles this cluster"
  value = {
    flux      = "${local.flux_version} (operator ${local.flux_operator_version})"
    source    = "${local.flux_sync_url} ${local.flux_sync_ref} -- ${local.flux_sync_path}"
    variables = "Secret/cluster-vars in flux-system"
  }
}
