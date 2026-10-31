# Network

VLANs, DHCP pools, DNS records, firewall policy, wifi, and the tailnet. Everything else
assumes the network already looks like this, so it comes early -- a machine
cannot take a static address in a VLAN that does not exist, and re-addressing
it afterwards is a migration rather than a setting.

What the network looks like and why -- VLANs, address plan, DNS, firewall
intent, the tailnet policy: [Networking](../docs/src/networking.md).

```sh
mise run network plan     # args are forwarded to tofu
mise run network apply
```

## What is here

| File           | Contents                                              |
|----------------|-------------------------------------------------------|
| `unifi_networks.tf` | the VLAN table, and one `unifi_network` per row      |
| `unifi_clients.tf`  | DHCP reservations -- MAC to fixed address, per network |
| `unifi_dns.tf`      | the address table, one `A` record per entry, and the `app.` wildcard |
| `unifi_firewall.tf` | the three `BLOCK` policies, the two scrape allows, and their order |
| `unifi_wifi.tf`     | the two SSIDs -- trusted and IoT, named from the vault |
| `tailscale_policy.tf` | the tailnet policy -- groups, tags, hosts, auto-approved routes, grants |
| `tailscale_dns.tf`  | MagicDNS and the split DNS for `lab.` and `app.`    |
| `providers.tf`      | the controller URL, and the tailnet's OAuth client  |

**VMs are not in this table.** A guest's record is defined beside the guest, in
the [guests](../guests/README.md) layer, through this same provider and API
key. A name must exist in exactly one of the two layers.

The `app.` wildcard is the exception to that rule: everything under `app.` is
one Gateway (`platform/platform_gateway.tf`) on `10.212.4.200`, an LB-IPAM pool
of one held by `cluster/cluster_cilium.tf`. Both layers come later, and the
address is fixed, so the record lives here.

Parts set outside tofu:

- the NAS's listener binding, half of the NVMe-oF access control -- see
  [machines/truenas](../machines/truenas.md#shares-and-services)
- the `vpn` guest joining the tailnet -- see [guests](../guests/README.md#vpn)
- the Cloudflare zone -- see [bootstrap/cloudflare](../bootstrap/cloudflare.md)

## Verify

From a machine on Trusted, once a machine exists:

```sh
dig +short titan.<lab_domain>   # -> 10.212.2.151
dig +short foo.<app_domain>     # -> 10.212.4.200, for any name
```

If that resolves but nothing connects, the problem is almost certainly
the workstation rather than the network, see
[bootstrap/workstation](../bootstrap/workstation.md).
