# The tailnet's policy file. The `vpn` guest (guests layer) is the subnet
# router and exit node; it joins with a one-shot auth key carrying the tag
# below, so it is owned by the tag rather than a user and its key never
# expires.
#
# People are groups, machines are tags. Personal devices stay untagged, so
# they keep their owner's identity -- and since no grant names them as a
# destination, nothing on the tailnet can open a connection to a laptop or a
# phone. Grants are stateful: replies to what a device opens still flow.

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
    groups = {
      # From the vault: login names are personal, and this repo is public.
      "group:admin"  = split(",", var.tailscale_admins)
      "group:family" = []
    }

    # `tag:public` marks a machine reachable from the internet. It is a risk
    # class, never a grant source: what such a box may reach is nothing. A
    # public box also carries a tag for what it runs, which is where its own
    # holes go -- `tag:public` gets only what every public box shares.
    #
    # `tag:k8s` is the cluster's tailscale operator's proxies, which it tags
    # itself -- hence owned by the operator's own tag.
    tagOwners = {
      "tag:lab-router"   = ["group:admin"]
      "tag:public"       = ["group:admin"]
      "tag:dhs"          = ["group:admin"]
      "tag:k8s-operator" = ["group:admin"]
      "tag:k8s"          = ["tag:k8s-operator"]
    }

    # Not this layer's: the gateway is Trusted's, the ingress the cluster
    # layer's, Home Assistant the guests layer's. Changing one there means
    # changing it here.
    hosts = {
      "lab-dns"        = "10.212.2.1"
      "lab-ingress"    = "10.212.4.200"
      "home-assistant" = "10.212.2.161"
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
      { src = ["group:admin"], dst = local.tailnet_routes, ip = ["*"] },
      { src = ["group:admin"], dst = ["autogroup:internet"], ip = ["*"] },
      { src = ["group:admin"], dst = ["tag:public"], ip = ["*"] },

      # The lab's front door only. Split DNS needs the resolver, or no `app.`
      # name resolves.
      { src = ["group:family"], dst = ["lab-dns"], ip = ["tcp:53", "udp:53"] },
      { src = ["group:family"], dst = ["lab-ingress"], ip = ["tcp:80", "tcp:443", "udp:443"] },
      { src = ["group:family"], dst = ["home-assistant"], ip = ["tcp:8123"] },
      { src = ["group:family"], dst = ["autogroup:internet"], ip = ["*"] },

      # Pull, never push: the cluster scrapes and dumps, a public box opens
      # nothing toward the lab.
      { src = ["tag:k8s"], dst = ["tag:public"], ip = ["tcp:9100"] },
      { src = ["tag:k8s"], dst = ["tag:dhs"], ip = ["tcp:5432"] },
    ]
  })
}
