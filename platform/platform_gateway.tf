# The front door. One Gateway, one wildcard listener, one certificate, and an
# `HTTPRoute` per app in the apps repo -- no listener, no certificate and no
# DNS record per hostname.
#
# Its address is not requested here. The cluster layer holds one address in a
# LB-IPAM pool of one, selected onto the Service Cilium generates for this
# Gateway and onto nothing else, and the network layer points the `app.`
# wildcard record at it. So `Gateway/lab` in namespace `gateway` is a name
# three layers agree on: renaming it here breaks the other two silently.
locals {
  gateway_namespace = "gateway"
}

# Its own namespace rather than kube-system: the Gateway and its certificate
# are read often, and kube-system is the noisiest place in the cluster.
resource "kubectl_manifest" "gateway_namespace" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Namespace"
    metadata   = { name = local.gateway_namespace }
  })
}

# One wildcard for every hostname. One Secret is therefore every hostname, and
# a bad renewal is a total outage rather than one app's -- bought in exchange
# for an app that needs no certificate of its own, and for keeping every
# hostname but this one out of public Certificate Transparency logs.
#
# `*.app.<domain>` covers `foo.app.<domain>` and not `foo.bar.app.<domain>`.
# Nesting means a second certificate.
resource "kubectl_manifest" "wildcard_certificate" {
  depends_on = [
    kubectl_manifest.gateway_namespace,
    kubectl_manifest.cluster_issuer,
  ]

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "wildcard-app"
      namespace = local.gateway_namespace
    }
    spec = {
      secretName = "wildcard-app-tls"
      issuerRef = {
        kind = "ClusterIssuer"
        name = "letsencrypt-prod"
      }
      dnsNames = ["*.${var.app_domain}"]
    }
  })
}

# `from: All` because every workload here arrives through a commit in the apps
# repo. The cost is that two apps can claim one hostname; Gateway API resolves
# that oldest-route-wins, so the newer one breaks by not serving rather than by
# saying anything.
resource "kubectl_manifest" "gateway" {
  depends_on = [
    kubectl_manifest.gateway_namespace,
    kubectl_manifest.wildcard_certificate,
  ]

  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "Gateway"
    metadata = {
      name      = "lab"
      namespace = local.gateway_namespace
    }
    spec = {
      gatewayClassName = "cilium"
      listeners = [
        {
          name          = "http"
          protocol      = "HTTP"
          port          = 80
          hostname      = "*.${var.app_domain}"
          allowedRoutes = { namespaces = { from = "All" } }
        },
        {
          name     = "https"
          protocol = "HTTPS"
          port     = 443
          hostname = "*.${var.app_domain}"
          tls = {
            mode = "Terminate"
            certificateRefs = [{
              kind = "Secret"
              name = "wildcard-app-tls"
            }]
          }
          allowedRoutes = { namespaces = { from = "All" } }
        },
      ]
    }
  })
}

resource "kubectl_manifest" "https_redirect" {
  depends_on = [kubectl_manifest.gateway]

  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "https-redirect"
      namespace = local.gateway_namespace
    }
    spec = {
      parentRefs = [{ name = "lab", sectionName = "http" }]
      rules = [{
        filters = [{
          type = "RequestRedirect"
          requestRedirect = {
            scheme     = "https"
            statusCode = 301
          }
        }]
      }]
    }
  })
}

output "front_door" {
  description = "What serves the app half of the zone"
  value = {
    gateway      = "Gateway/lab in ${local.gateway_namespace} -- *.${var.app_domain}"
    certificate  = "wildcard-app -> wildcard-app-tls, letsencrypt-prod"
    cert_manager = local.cert_manager_version
  }
}
