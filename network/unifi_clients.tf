# DHCP reservations. The device stays a DHCP client, the controller just always
# hands it the same address.
locals {
  fixed_clients = {
    "samsung-tv" = { mac = "fc:03:9f:f3:ad:39", network = "Trusted", ip = "10.212.2.139" }
  }
}

resource "unifi_user" "fixed" {
  for_each = local.fixed_clients

  name       = each.key
  mac        = each.value.mac
  network_id = unifi_network.this[each.value.network].id
  fixed_ip   = each.value.ip

  # The controller already knows the device; adopt it rather than fail.
  allow_existing = true
  # Destroying only drops the reservation, it does not forget the client.
  skip_forget_on_destroy = true
}
