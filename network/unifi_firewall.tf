data "unifi_firewall_zone" "internal" {
  name = "Internal"
}


# The NVMe-oF listener binds 10.212.4.150 only, so it does not answer on
# Trusted -- but the other networks can still route to it, because
# Internal -> Internal ends in the predefined allow-all and Trusted -> k8s is
# deliberately open (ssh to nodes, the ingress, NodePorts). NVMe-oF has no
# authentication of any kind, so the reachability is the whole access control.
resource "unifi_firewall_zone_policy" "nvmeof_deny" {
  name        = "nvmeof-deny-cross-vlan"
  description = "Only k8s may reach the NVMe-oF listener"
  action      = "BLOCK"
  protocol    = "tcp"
  logging     = true

  source = {
    zone_id = data.unifi_firewall_zone.internal.id

    # k8s is absent on purpose: it is the one network that may connect.
    network_ids = [
      for name in ["Guest", "Management", "Trusted", "IoT"] :
      unifi_network.this[name].id
    ]
  }

  destination = {
    zone_id = data.unifi_firewall_zone.internal.id
    ips     = [local.dns_records["nas-k8s"]]
    port    = 4420
  }
}


# Everything from k8s into the rest of the lab. Internet egress is a
# different zone pair and is unaffected -- images and updates keep working.
resource "unifi_firewall_zone_policy" "k8s_deny" {
  name        = "k8s-deny-internal"
  description = "Default deny: k8s may not initiate into the rest of the lab"
  action      = "BLOCK"
  logging     = true

  # Connection setup only. Blocking ESTABLISHED and RELATED as well would tear
  # down the return path of traffic started from Trusted -- ssh to a node, the
  # ingress -- which this policy is not meant to touch.
  connection_state_type = "CUSTOM"
  connection_states     = ["NEW", "INVALID"]

  # The provider writes `connection_states` correctly but reads it back as
  # null, so every plan wants to re-add it and every apply then dies with
  # "Provider produced inconsistent result after apply". Same family as
  # filipowm/terraform-provider-unifi#183. Verify this one in the UI: terraform
  # can no longer tell you when it drifts.
  #
  # Drop this block after upgrading the provider and confirm the plan is still
  # empty.
  lifecycle {
    ignore_changes = [connection_states]
  }

  source = {
    zone_id     = data.unifi_firewall_zone.internal.id
    network_ids = [unifi_network.this["k8s"].id]
  }

  destination = {
    zone_id = data.unifi_firewall_zone.internal.id

    # Everything the deny policy covers. k8s is absent on purpose: a network is
    # not blocked from talking to itself -- which is what both storage paths
    # now are.
    network_ids = [
      for name in ["Guest", "Management", "Trusted", "IoT"] :
      unifi_network.this[name].id
    ]
  }
}


# Evaluation order for the Internal -> Internal pair. Policies are matched
# top-to-bottom and `index` is controller-assigned, so without this the order is
# whatever the last apply happened to produce -- and recreating the policies
# once put a deny above the allows, which silently cut k8s off from the NAS.
#
# Both go before the predefined policies, which end in the built-in allow-all
# for this pair -- that allow-all is what `nvmeof_deny` exists to precede.
resource "unifi_firewall_zone_policy_order" "internal" {
  source_zone_id      = data.unifi_firewall_zone.internal.id
  destination_zone_id = data.unifi_firewall_zone.internal.id

  before_predefined_ids = [
    unifi_firewall_zone_policy.nvmeof_deny.id,
    unifi_firewall_zone_policy.k8s_deny.id,
  ]
}
