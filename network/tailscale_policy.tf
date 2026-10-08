# The tailnet's policy file. The `vpn` guest (guests layer) is the subnet
# router and exit node; it joins with a one-shot auth key carrying the tag
# below, so it is owned by the tag rather than a user and its key never
# expires.

locals {
  tailnet_routes = [
    local.networks.Trusted.cidr,
    local.networks.k8s.cidr,
  ]
}

resource "tailscale_acl" "this" {
  # Replaces whatever the console holds -- this file is the policy, there is no
  # second copy worth importing.
  overwrite_existing_content = true

  acl = jsonencode({
    tagOwners = {
      "tag:lab-router" = ["autogroup:admin"]
    }

    autoApprovers = {
      routes   = { for cidr in local.tailnet_routes : cidr => ["tag:lab-router"] }
      exitNode = ["tag:lab-router"]
    }

    # All of k8s is routed, NVMe-oF included. What keeps the tailnet off
    # 10.212.4.150:4420 is `nvmeof-deny-cross-vlan`: the router SNATs to its
    # Trusted address, which that policy blocks. Running it with
    # `--snat-subnet-routes=false` would hand the gateway 100.x sources the
    # policy does not match.
    grants = [
      { src = ["autogroup:member"], dst = local.tailnet_routes, ip = ["*"] },
      { src = ["autogroup:member"], dst = ["autogroup:internet"], ip = ["*"] },
      { src = ["autogroup:member"], dst = ["autogroup:self"], ip = ["*"] },
    ]
  })
}
