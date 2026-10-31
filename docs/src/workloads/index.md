# Workloads

The services the household uses. Everything in the cluster sits behind the
gateway: LAN and tailnet only, never public (see
[Networking](../networking.md)). Home Assistant runs outside the cluster.

| Workload | What it's for | Reachability | Where it runs |
|--|--|--|--|
| [Vaultwarden](vaultwarden.md) | password manager | LAN + tailnet, `passwords.<app_domain>` | ns `vaultwarden` |
| [Syncthing](syncthing.md) | always-on sync hub, a copy of every file on the NAS | LAN + tailnet, `sync.<app_domain>` (GUI), `:22000` (sync) | ns `syncthing` |
| [Kassenbuch](kassenbuch.md) | the Verein's cash book | LAN + tailnet, `kassenbuch.<app_domain>` | ns `kassenbuch` |
| [Supplement tracker](supplement-tracker.md) | household supplement plan and daily ticks | LAN + tailnet, `supplements.<app_domain>` | ns `supplement-tracker` |
| [Glance](glance.md) | lab start page, release tracking | LAN + tailnet, `dash.<app_domain>` | ns `glance` |
| [Home Assistant](home-assistant.md) | home automation appliance | LAN + tailnet, `ha.<lab_domain>:8123`, not via the gateway | VM 161 on titan |

Not a workload: [DHS](dhs.md), a public service outside the lab -- the lab
only backs up its database and monitors the box.

Backups per workload: the [coverage matrix](../backups.md#coverage-matrix).
