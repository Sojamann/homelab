# The Kubernetes endpoint's record.
resource "unifi_dns_record" "cluster" {
  name   = local.cluster_fqdn
  type   = "A"
  record = local.cluster_vip

  ttl = 0 # auto
}
