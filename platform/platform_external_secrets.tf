# What turns a path in OpenBao into a Secret a workload can mount.
locals {
  external_secrets_version = "2.10.0" # chart == appVersion v2.10.0
}

resource "helm_release" "external_secrets" {
  name       = local.eso_service_account
  repository = "https://charts.external-secrets.io"
  chart      = "external-secrets"
  version    = local.external_secrets_version

  namespace        = local.eso_namespace
  create_namespace = true

  values = [yamlencode({
    # Raise all three alongside the second control plane.
    replicaCount   = 1
    webhook        = { replicaCount = 1 }
    certController = { replicaCount = 1 }

    # One direction only. The policy in OpenBao grants `read` and nothing
    # else, so a push already fails there -- this removes the kind that would
    # attempt it, so the answer is "no such resource" rather than a 403.
    #
    # `status.capabilities` on the store will still say ReadWrite: ESO derives
    # that from the provider type, not from what the token can do.
    processPushSecret        = false
    processClusterPushSecret = false

    crds = {
      createPushSecret        = false
      createClusterPushSecret = false
    }
  })]
}

# The one store, and the only thing in the cluster that talks to OpenBao.
#
# No credential: ESO presents the ServiceAccount token mounted in its own pod
# -- which is what omitting `serviceAccountRef` means -- and OpenBao asks the
# apiserver whether it is real. The role it maps to is bound to this
# ServiceAccount in this namespace, in platform_openbao.tf.
resource "kubectl_manifest" "openbao_secret_store" {
  depends_on = [
    helm_release.external_secrets,
    vault_kubernetes_auth_backend_role.external_secrets,
  ]

  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1"
    kind       = "ClusterSecretStore"
    metadata   = { name = "openbao" }
    spec = {
      provider = {
        vault = {
          server  = "http://openbao-active.${local.openbao_namespace}.svc:8200"
          path    = vault_mount.kv.path
          version = "v2"

          auth = {
            kubernetes = {
              mountPath = vault_auth_backend.kubernetes.path
              role      = vault_kubernetes_auth_backend_role.external_secrets.role_name
            }
          }
        }
      }
    }
  })
}

output "secrets" {
  description = "Where a workload's secrets come from"
  value = {
    openbao             = "${local.openbao_version} (appVersion v2.6.2) -- raft, static seal, https://${local.openbao_host}"
    external_secrets    = local.external_secrets_version
    cluster_secretstore = "openbao -- kv/<namespace>/<app>/<key>"
  }
}
