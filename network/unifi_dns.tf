# CORE DNS records are managed here everyting else will go to the pihole later.
#
# Machines only. A VM's record lives beside its definition in the guests layer,
# so that a new guest is one file there rather than an edit in both -- see
# guests/providers.tf. Both layers write the same zone through the same
# controller, so a name belongs to exactly one of them.

locals {
  dns_records = {
    # well ... the NAS
    nas : "10.212.2.150",

    # The NAS again, on its second interface in the k8s network. Both storage
    # paths run over this one: NVMe/TCP, and the TrueNAS API, which needs a
    # name because it is verified against the certificate -- so the cert
    # carries both names as SANs. See machines/truenas.md.
    "nas-k8s" : "10.212.4.150",

    # generic worker machines running proxmox
    titan : "10.212.2.151",
    enceladus : "10.212.2.152",
    mimas : "10.212.2.153",
    rhea : "10.212.2.154",
    iapetus : "10.212.2.155",
    dione : "10.212.2.156",
  }

  # The machines running Proxmox, as opposed to the NAS. Only the firewall
  # needs the distinction -- see unifi_firewall.tf.
  proxmox_hosts = ["titan", "enceladus", "mimas", "rhea", "iapetus", "dione"]
}

resource "unifi_dns_record" "machines" {
  for_each = local.dns_records

  name   = "${each.key}.${var.lab_domain}"
  type   = "A"
  record = each.value

  ttl = 0 # auto
}

# The address is `cluster`'s: a LB-IPAM pool of one, held apart so nothing else
# can be handed it. See cluster/cluster_cilium.tf.
resource "unifi_dns_record" "app_wildcard" {
  name   = "*.${var.app_domain}"
  type   = "A"
  record = "10.212.4.200"

  ttl = 0 # auto
}
