# Split DNS: only the lab's own zones go home, to the resolver that holds them
# -- reachable over the Trusted route. Everything else stays on the client's
# resolver, so a dead lab does not take a laptop's DNS with it.

resource "tailscale_dns_preferences" "this" {
  magic_dns = true
}

resource "tailscale_dns_split_nameservers" "lab" {
  for_each = toset([var.lab_domain, var.app_domain])

  domain      = each.key
  nameservers = ["10.212.2.1"]
}
