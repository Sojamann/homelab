locals {
  networks = {
    Guest      = { purpose = "corporate", cidr = "10.212.0.0/24", vlan = null, dhcp_start = "10.212.0.6", dhcp_stop = "10.212.0.254", isolate = false, ipv6_ra = true }
    Management = { purpose = "corporate", cidr = "10.212.1.0/24", vlan = 10, dhcp_start = "10.212.1.6", dhcp_stop = "10.212.1.254", isolate = false, ipv6_ra = false }
    Trusted    = { purpose = "corporate", cidr = "10.212.2.0/24", vlan = 20, dhcp_start = "10.212.2.6", dhcp_stop = "10.212.2.149", isolate = false, ipv6_ra = false }
    IoT        = { purpose = "corporate", cidr = "10.212.3.0/24", vlan = 30, dhcp_start = "10.212.3.6", dhcp_stop = "10.212.3.254", isolate = true, ipv6_ra = false }
    k8s        = { purpose = "corporate", cidr = "10.212.4.0/24", vlan = 40, dhcp_start = "10.212.4.100", dhcp_stop = "10.212.4.149", isolate = false, ipv6_ra = false }
  }
}

resource "unifi_network" "this" {
  for_each = local.networks

  name    = each.key
  purpose = each.value.purpose
  subnet  = each.value.cidr
  vlan_id = each.value.vlan

  # IoT devices have no business reaching each other, and the VLAN alone does
  # not stop them -- this is intra-network, below the firewall.
  network_isolation_enabled = each.value.isolate

  # SLAAC. Only where something actually wants IPv6; elsewhere it advertises a
  # prefix nothing is listening for.
  ipv6_ra_enable = each.value.ipv6_ra

  # Bonjour/Avahi. On by default on the controller, off by default in the
  # provider -- leaving it out would silently break AirPlay and printer discovery.
  multicast_dns = true

  dhcp_enabled = true
  dhcp_start   = each.value.dhcp_start
  dhcp_stop    = each.value.dhcp_stop
}
