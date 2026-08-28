# Cloudflare

Cloudflare is the public authority for `<domain>`. It exists in this setup for
exactly one reason: proving to Let's Encrypt that you control the domain.

## What Cloudflare actually holds

- The zone itself.
- `_acme-challenge` TXT records, written and removed by Proxmox on every
  certificate order and renewal. They exist for seconds at a time.

No `A` records, no delegation, nothing persistent -- every name under it is resolved privately by
[UniFi](../network/README.md#dns), and the addresses never leave the network.

The one unavoidable exception is the challenge record itself: DNS-01 proves
control by publishing `_acme-challenge.<node>.lab.<domain>` as a TXT record in
the public zone, so the *name* of a node is briefly visible even though its
address never is. Avoiding that entirely would mean dropping Let's Encrypt for
a private CA and distributing your own root to every client.

> Per-node hostnames still appear in public Certificate Transparency logs --
> that is inherent to using a publicly trusted CA, and is an accepted
> trade-off.

## API token

Create a scoped token (My Profile -> API Tokens) with exactly:

| Permission        | Level |
|-------------------|-------|
| Zone / DNS        | Edit  |
| Zone / Zone       | Read  |

Restricted to `<domain>`. No account-level permissions -- the ACME plugin
resolves the zone from the record name, which is why no account ID is needed.

Put the value in the vault as `cloudflare_api_token`, alongside `acme_email`
-- see [secrets](../bootstrap/README.md#secrets) for how that file is created.
