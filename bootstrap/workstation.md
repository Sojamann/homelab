# Workstation

Every later layer runs from here, not from the nodes.

## Toolchain

Everything is pinned in `mise.toml` -- ansible and opentofu:

```sh
mise install
```

## Reachability

Your workstation needs to reach the physical range on port 22 as `root`. On
wifi that means being on the Trusted VLAN, and it means
[Client Device Isolation](../network/README.md#what-actually-bites) is off.

## macOS 15 (Sequoia): Local Network permission

**Read this before debugging anything that looks like a network fault.**

Sequoia gates local-network access per application. A denied app gets
`EHOSTUNREACH` from the kernel *before a packet is ever sent*, so `ping`,
`ssh`, `nc` and `curl` all fail instantly with `No route to host` while the
Proxmox web UI works fine in a browser -- the browser has the permission and
your terminal does not.

The tell is that it fails in about a millisecond, and `tcpdump` on the node
shows no SYN arriving at all.

Grant it under *System Settings -> Privacy & Security -> Local Network*, or
reset the prompts with:

```sh
tccutil reset LocalNetwork
```

## Verify

Nothing to reach yet -- no machine exists at this point. Come back to this once
[machines](../machines/README.md) has installed one, and note that the name
only resolves after [network](../network/README.md) has written its A record:

```sh
nc -vz dione.lab.<domain> 22
ssh root@dione.lab.<domain> true
```
