# The Gateway API CRDs, and nothing that uses them.
#
# Cilium implements Gateway API but does not ship its CRDs -- they are upstream
# `kubernetes-sigs/gateway-api` types, and must already exist when the agent
# starts. So they live next to the release whose feature flag needs them.
#
# The `Gateway` itself is not here. This layer stops at a cluster that *can*
# route: the CRDs, the feature, and `GatewayClass/cilium`, which the chart
# creates on its own. What listens on which hostname with which certificate is
# Flux's -- see the apps repo's `infrastructure` tier.

locals {
  # Not chosen: Cilium 1.20 requires at least v1.6.1. Bump the two together.
  # renovate: datasource=github-releases depName=kubernetes-sigs/gateway-api
  gateway_api_version = "v1.6.3"

  # What Cilium 1.20 requires, plus TCPRoute. The rest of the standard channel
  # (ListenerSet, UDPRoute) is optional -- Cilium disables those features
  # without their CRDs.
  gateway_api_crds = [
    "gatewayclasses",
    "gateways",
    "httproutes",
    "referencegrants",
    "grpcroutes",
    "backendtlspolicies",
    "tlsroutes",
    "tcproutes",
  ]
}

# A git tag upstream is immutable, so fetching at apply time is reproducible.
data "http" "gateway_api_crd" {
  for_each = toset(local.gateway_api_crds)

  url = join("/", [
    "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api",
    local.gateway_api_version,
    "config/crd/standard/gateway.networking.k8s.io_${each.key}.yaml",
  ])

  # Otherwise a 404 -- a moved path, a bad tag -- is applied as if it were a
  # manifest, and fails much later with something unrelated.
  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "GET ${self.url} returned ${self.status_code}"
    }
  }
}

# `server_side_apply` is not optional: these carry the full Gateway API schema
# and are far past the 256KB client-side apply stuffs into
# `last-applied-configuration`. Without it they fail as
# "metadata.annotations: Too long", which says nothing about why.
resource "kubectl_manifest" "gateway_api_crd" {
  for_each = toset(local.gateway_api_crds)

  yaml_body         = data.http.gateway_api_crd[each.key].response_body
  server_side_apply = true
  force_conflicts   = true
}

# Upstream's guard on the CRDs above: it refuses experimental-channel CRDs over
# standard ones, and any bundle older than v1.5. Without it, either mistake
# applies cleanly; the experimental one can make stored objects unreadable.
# Deleting it is the escape hatch when a downgrade is truly intended.
data "http" "gateway_api_vap" {
  url = join("/", [
    "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api",
    local.gateway_api_version,
    "config/crd/standard/gateway.networking.k8s.io_vap_safeupgrades.yaml",
  ])

  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "GET ${self.url} returned ${self.status_code}"
    }
  }
}

# The policy and its binding, two documents in one file.
data "kubectl_file_documents" "gateway_api_vap" {
  content = data.http.gateway_api_vap.response_body
}

resource "kubectl_manifest" "gateway_api_vap" {
  for_each = data.kubectl_file_documents.gateway_api_vap.manifests

  yaml_body         = each.value
  server_side_apply = true
  force_conflicts   = true

  depends_on = [kubectl_manifest.gateway_api_crd]
}
