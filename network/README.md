# Network

VLANs, DHCP pools, DNS records, firewall policy and wifi. Everything else
assumes the network already looks like this, so it comes early -- a machine
cannot take a static address in a VLAN that does not exist, and re-addressing
it afterwards is a migration rather than a setting.

```sh
mise run network plan     # args are forwarded to tofu
```

## Networks

| Name            | CIDR          | VLAN TAG | DHCP                          | Description          |
|-----------------|---------------|----------|-------------------------------|----------------------|
| Guest (Default) | 10.212.0.0/24 | untagged | 10.212.0.6 - 10.212.0.254     | the controller's own |
| Management      | 10.212.1.0/24 | 10       | 10.212.1.6 - 10.212.1.254     | all network gear     |
| Trusted         | 10.212.2.0/24 | 20       | 10.212.2.6 - 10.212.2.**149** | all home devices     |
| IoT             | 10.212.3.0/24 | 30       | 10.212.3.6 - 10.212.3.254     | all IoT devices      |
| k8s             | 10.212.4.0/24 | 40       | 10.212.4.**100** - 10.212.4.**149** | network of k8s nodes |

`IoT` has client isolation on -- the VLAN keeps it away from everything else,
and isolation keeps its members away from each other.

Two `BLOCK` policies, order pinned; everything they do not name stays open, so
both denies have to be explicit. They match connection setup only -- what you
start *from* Trusted still gets its replies back. `k8s` reaching the NAS is not
crossing anything: same network, which is why no allow appears here at all.

- all regular devices are in the `Trusted` network and get their IP via DHCP
- the NAS is `.150`. It gets its own slot at the bottom of the static range
  because everything else in the lab mounts it, and an address that never moves
  is worth one wasted number. It is `.150` in `k8s` too, on a second interface
- physical homelab equipment uses `.151-.159`, statically assigned and
  deliberately outside the DHCP pool -- which is why that pool stops at `.149`
- permanent, statically addressed guests -- VMs and containers alike -- use
  `.160+`; `netbird` is the first of them at `.160`, and pihole will take the
  next free number
- everything else is a normal DHCP client

The `k8s` network is laid out differently, because nothing in it is a person's
device and almost none of it is a DHCP client:

| Range                       | Holds                                    | Written by |
|-----------------------------|------------------------------------------|------------|
| `10.212.4.1`                | gateway, and the nodes' resolver         | controller |
| `10.212.4.5`                | the Talos VIP -- the Kubernetes endpoint | [cluster](../cluster/README.md) |
| `10.212.4.10-.12`           | control planes (`talos-cp-1` is `.10`)   | [guests](../guests/README.md) |
| `10.212.4.13-.19`           | workers                                  | [guests](../guests/README.md) |
| `10.212.4.100-.149`         | DHCP                                     | controller |
| `10.212.4.150`              | the NAS, second interface -- all storage | [machines](../machines/README.md) |
| `10.212.4.200`              | the cluster's gateway -- all of `app.`   | [cluster](../cluster/README.md) |
| `10.212.4.201-.254`         | `LoadBalancer` services, Cilium LB-IPAM  | [cluster](../cluster/README.md) |

Control planes are `.10-.12` and workers `.13-.19` so that growing to three
control planes -- one per machine, once there are three machines -- is three
new VMs and no renumbering.

The NAS is the one thing here that is not a cluster node: a second interface,
same host octet it takes in Trusted, so that storage never crosses the router.
The DHCP pool stops at `.149` to leave it free.

## DNS

The zone is `<domain>`, split in two:

| Subdomain      | Contents                              | Shape                                    |
|----------------|---------------------------------------|------------------------------------------|
| `lab.<domain>` | infrastructure -- physical hosts, vms | one record per machine, `<name>.lab....`  |
| `app.<domain>` | hosted services (nextcloud, ...)      | one wildcard onto the cluster's gateway  |

Cloudflare holds the zone but none of these records. Its only job is proving
domain control to Let's Encrypt, which it does with `_acme-challenge` TXT
records that exist for seconds at a time -- see
[bootstrap/cloudflare](../bootstrap/cloudflare.md).

One `A` record per machine, and one per VM. Nothing under `app` is ever
enumerated -- it is a single wildcard, so adding a service is a kubernetes
concern rather than a DNS one.

One exception: the NAS has two records, `nas` and `nas-k8s`, one per interface.
A single name resolving to both addresses would break half the connections, and
the TrueNAS certificate has to name whichever one is dialled -- both are SANs
on it.

## k8s firewall

The k8s network runs arbitrary containers pulled from the internet, and Trusted
holds the NAS and every Proxmox management interface. It is the one place in
this lab where the permissive option is actually dangerous, and the list of
things it legitimately needs is one line long:

| From            | To              | Port        | Why             |
|-----------------|-----------------|-------------|-----------------|
| `10.212.4.0/24` | internet        | any         | images, updates |
| `10.212.4.0/24` | Proxmox hosts   | 9100, 9221  | Prometheus scrapes the exporters -- `metrics-allow-proxmox`, ordered above the deny |
| `10.212.4.0/24` | anything else   | --          | denied          |

The two allows that used to be here, 4420 and 443 to the NAS, are gone: the NAS
has an interface in this network, so storage never crosses the zone pair. The
scrape cannot be arranged away the same fashion -- the hosts have no interface
in k8s -- so it is a narrow allow rather than an abandoned policy: named
addresses, two read-only ports, and the exporters bind the Trusted address
only. Keep the list this short.

The NAS being in here is the cost. NVMe-oF has no authentication and
`nvme connect` no TLS, so reaching `10.212.4.150:4420` is enough to attach a
volume, and two things must both hold to prevent it:

- the listener **binds the k8s address only** -- set on the NAS, see
  [machines/truenas](../machines/truenas.md#shares-and-services)
- `nvmeof-deny-cross-vlan` **blocks the other four networks** from routing to
  it. Necessary because `Internal -> Internal` ends in the predefined allow-all
  and Trusted -> k8s stays open by design.

The NAS binds everything else -- SMB, ssh -- to Trusted. The exception is the
TrueNAS API, which shares a listener with the web UI, so the login page is
reachable from k8s: an accepted trade, see
[platform](../platform/README.md#known-trade-offs).

## What is here

| File           | Contents                                              |
|----------------|-------------------------------------------------------|
| `unifi_networks.tf` | the VLAN table, and one `unifi_network` per row      |
| `unifi_dns.tf`      | the address table, one `A` record per entry, and the `app.` wildcard |
| `unifi_firewall.tf` | the k8s allow list, the default block, and their order |
| `unifi_wifi.tf`     | the two SSIDs -- trusted and IoT, named from the vault |
| `providers.tf`      | the controller URL                                  |

**VMs are not in this table.** A guest's record is defined beside the guest, in
the [guests](../guests/README.md) layer, through this same provider and API
key.

The `app.` wildcard is the exception to that rule**, and the reason is that
the layer that should own it cannot. Everything under `app.` is served by one
Gateway in the cluster; the Gateway is written in the apps repo, which Flux
applies [cluster](../cluster/README.md).

## Verify

From a machine on Trusted, once a machine exists:

```sh
dig +short dione.lab.<domain>   # -> 10.212.2.156
dig +short foo.app.<domain>     # -> 10.212.4.200, for any name
```

If that resolves but nothing connects, the problem is almost certainly 
the workstation rather than the network see
[bootstrap/workstation](../bootstrap/workstation.md).
