# Certificates, so that a hostname can be served over HTTPS without anything
# per-app. One issuer, and the wildcard it produces lives in platform_gateway.tf.

locals {
  cert_manager_version   = "v1.21.1" # chart == appVersion
  cert_manager_namespace = "cert-manager"
}

# Created here because the Secret below needs somewhere to be, and it must
# exist before the chart is installed into it.
resource "kubectl_manifest" "cert_manager_namespace" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Namespace"
    metadata   = { name = local.cert_manager_namespace }
  })
}

# A `ClusterIssuer` resolves secret references against cert-manager's own
# namespace, not the Issuer's -- which is why this lives here and the wildcard
# certificate it produces lives in `gateway`.
resource "kubectl_manifest" "cloudflare_api_token" {
  depends_on = [kubectl_manifest.cert_manager_namespace]

  sensitive_fields = ["stringData.api-token"]

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Secret"
    metadata = {
      name      = "cloudflare-api-token"
      namespace = local.cert_manager_namespace
    }
    stringData = {
      api-token = var.cloudflare_api_token
    }
  })
}

resource "helm_release" "cert_manager" {
  name       = "cert-manager"
  repository = "oci://quay.io/jetstack/charts"
  chart      = "cert-manager"
  version    = local.cert_manager_version
  namespace  = local.cert_manager_namespace

  depends_on = [kubectl_manifest.cert_manager_namespace]

  values = [yamlencode({
    # The chart owns the CRD lifecycle, so an upgrade carries them along
    # instead of leaving them at whatever version first installed them.
    crds = { enabled = true }

    # Raise all three alongside the second control plane.
    replicaCount = 1
    webhook      = { replicaCount = 1 }
    cainjector   = { replicaCount = 1 }

    # cert-manager checks for its own `_acme-challenge` TXT record before
    # asking Let's Encrypt to. The cluster's resolver serves this zone
    # privately and would never see it.
    dns01RecursiveNameservers     = "1.1.1.1:53,9.9.9.9:53"
    dns01RecursiveNameserversOnly = true
  })]
}

# Production Let's Encrypt, with no staging sibling: five certificates per week
# for that name set, no appeal. Watch the Order and the Challenge on a first
# issue rather than retrying.
#
# A ClusterIssuer resolves secret references against cert-manager's own
# namespace, which is why the token above lives there.
resource "kubectl_manifest" "cluster_issuer" {
  depends_on = [helm_release.cert_manager]

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata   = { name = "letsencrypt-prod" }
    spec = {
      acme = {
        server = "https://acme-v02.api.letsencrypt.org/directory"
        email  = var.acme_email

        privateKeySecretRef = { name = "letsencrypt-prod-account" }

        solvers = [{
          dns01 = {
            cloudflare = {
              apiTokenSecretRef = {
                name = "cloudflare-api-token"
                key  = "api-token"
              }
            }
          }
        }]
      }
    }
  })
}
