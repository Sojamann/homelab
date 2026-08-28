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
  # Not chosen: this is what Cilium 1.19 supports. Bump the two together.
  gateway_api_version = "v1.4.1"

  # The standard channel is these five. `TLSRoute` is experimental and only
  # needed for TLS passthrough; this lab terminates at the Gateway.
  gateway_api_crds = [
    "gatewayclasses",
    "gateways",
    "httproutes",
    "referencegrants",
    "grpcroutes",
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
