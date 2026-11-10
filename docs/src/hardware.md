# Hardware

Everything physical in the lab, for reordering. `?` = not recorded yet.

## Compute, storage, network

| Item | Qty | Role | Notes |
|--|--|--|--|
| Lenovo ThinkCentre M920q Tiny, i7-9700T, 32GB RAM | 1 | `titan`, [Proxmox](platform/proxmox.md) | boot/guest disk: `?` |
| UGREEN NASync DXP4800 GT | 1 | [TrueNAS](platform/truenas.md) | TrueNAS on onboard eMMC |
| Lexar NM620 M.2 NVMe SSD 1TB | 2 | NAS pool `fast`, mirror | both M.2 slots full -- [Storage](storage.md) |
| Seagate IronWolf 4TB HDD, ST4000VN006 | 2 | NAS pool `slow`, mirror | 2 of 4 bays free |
| UniFi Dream Router 7 | 1 | gateway, DNS, firewall, Wi-Fi -- [Networking](networking.md) | |
| Raspberry Pi (`?` model) | 1 | `pi`, second Tailscale subnet router | [Networking](networking.md) |

## Rack (10")

| Item | Qty | Source |
|--|--|--|
| Rack frame (`?`) | 1 | |
| Adam Hall 61535B12 rack strip, 12U, black | `?` | |
| Adam Hall 5653 rack nut pack | `?` | |
| Adam Hall 5410BLK rack screw pack | `?` | |
| Adam Hall 5417BLK rack screw pack | `?` | |
| Adam Hall 5621 plain nylon washers | `?` | |
| GeeekPi 12-port Cat6 patch panel, 0.5U | 1 | |
| DIGITUS power strip, 4x Schuko, 1U | 1 | |
| Universal shelf, 1U, for 450mm depth | `?` | [serverschrank24](https://www.serverschrank24.de/10-universeller-fachboden-fur-450mm-tiefe-10-zoll-serverschranke-1he.html) |

## Cables, power

| Item | Qty | Notes |
|--|--|--|
| Cat6 patch cables (`?` lengths) | `?` | |
| M920q power brick (`?` W) | 1 | |
| Pi power supply | 1 | |
