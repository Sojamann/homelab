# DHS

## What it's for

Not a lab workload: a publicly hosted service, external to the lab, that the
operator is partly responsible for. The lab provides only its **backups and
monitoring** -- a nightly dump of its postgres and a watch on the box. Nothing
in the lab serves it.

## Where it runs

A public Hetzner box: Ubuntu, docker compose, postgres. Reached over the
tailnet as `dhs.<tailnet>` -- `group:admin` reaches `tag:public`; public SSH
(22) is closed, no tailscale SSH. The cluster only pulls: one tailscale egress
proxy reaches postgres (5432) and node_exporter (9100) (`tag:k8s` ->
`tag:dhs` / `tag:public`), the box opens nothing toward the lab. See
[Networking](../networking.md).

The lab's side: namespace `dhs` (a dump CronJob, its PVC, the egress Service,
a scrape config), Flux Kustomization `dhs`. Wiring:
[Build guide: DHS](../build/flux/docs/dhs.md).

### The box {#the-box}

Not in this repo; done by hand:

- `tailscale up --advertise-tags=tag:public,tag:dhs` -- no `--ssh`
- Hetzner firewall: udp/41641 open, public 22 closed
- postgres published on loopback only (`127.0.0.1:5432:5432`), never
  `0.0.0.0` -- docker's rules bypass ufw; node_exporter likewise on
  `127.0.0.1:9100`
- tailscale forwards the two ports from the tailnet address, persisted in
  tailscaled's state:

  ```sh
  tailscale serve --bg --tcp 5432 tcp://127.0.0.1:5432
  tailscale serve --bg --tcp 9100 tcp://127.0.0.1:9100
  ```

  Nothing on the box listens beyond loopback, and the tailnet policy still
  decides who reaches the ports. Postgres sees every connection as
  `127.0.0.1`, so the password is the only guard past the policy.
- the backup role:

  ```sql
  CREATE ROLE backup LOGIN PASSWORD '...';
  GRANT pg_read_all_data TO backup;
  ```

  The official image's `pg_hba.conf` already admits any host by password.

**Backup role credentials.** `dhs_backup_user` / `dhs_backup_password` in
`secrets/vault.yml`, written by `platform_secrets.tf` to OpenBao at
`kv/dhs/backup`. To rotate: change the password on the box, then
`ansible-vault edit secrets/vault.yml`, `mise run platform apply`, and
`kubectl -n dhs annotate externalsecret postgres-backup force-sync=$(date +%s) --overwrite`.
The next CronJob run picks it up.

## Data

| What | Where | State? |
|--|--|--|
| postgres (17) | on the box | **yes** -- the only thing backed up |
| `postgres.dump`, `pg_dump -Fc`, latest only | PVC `postgres-dump`, `fast`, 5Gi | a copy; its history is restic's |
| compose files, tailscale state, the box | on the box | **yes**, not backed up |

The dump job (`dump.yaml`, `00:30` UTC) writes to `postgres.dump.tmp`,
`sync`s and renames, so the backup's clone never catches a half-written file.
It runs as the read-only `backup` role (`pg_read_all_data`).

## Backup & restore

Covered by [VolSync](../backups.md#volsync) on `postgres-dump`: nightly
`01:00` UTC, after the dump, retain daily 14, weekly 8, monthly 6. The rest of
the box is [not covered](../backups.md#not-covered).

**Restore.** Untested end to end; the dump itself is drilled (below). The
box's postgres is overwritten in place, so stop the app first.

1. **Pick the dump.** Last night's is still on `postgres-dump`. Anything older,
   or a lost PVC: the generic [VolSync restore](../backups.md#volsync) over
   `postgres-dump` (`restoreAsOf` for a point in time), with
   ```sh
   NS=dhs KS=dhs PVC=postgres-dump MOVER_UID=70   # no Deployment to scale
   ```
   Suspend `dhs` anyway, or the CronJob overwrites the dump at `00:30`.
   Without the cluster: plain restic against `k8s-backups/dhs/postgres-dump`.
2. **Get it out of the cluster.** A pod mounting the PVC read-only, then:
   ```sh
   kubectl -n dhs run fetch --image=docker.io/library/busybox:1.37 --restart=Never \
     --overrides='{"spec":{"volumes":[{"name":"d","persistentVolumeClaim":{"claimName":"postgres-dump","readOnly":true}}],
       "containers":[{"name":"fetch","image":"docker.io/library/busybox:1.37","command":["sleep","3600"],
       "volumeMounts":[{"name":"d","mountPath":"/dump","readOnly":true}]}]}}'
   kubectl -n dhs cp fetch:/dump/postgres.dump ./postgres.dump
   kubectl -n dhs delete pod fetch
   ```
3. **Onto the box**, over the tailnet:
   ```sh
   scp postgres.dump <user>@dhs.<tailnet>:
   ```
4. **Restore**, as the superuser, with the app stopped and postgres running.
   `--single-transaction`: it lands whole or not at all.
   ```sh
   docker compose stop <app>
   docker compose exec -T <postgres> \
     pg_restore -U postgres -d postgres --clean --if-exists --single-transaction < postgres.dump
   docker compose start <app>
   ```
   Flyway finds its history table restored with the data and migrates nothing.

On a fresh box: the dump holds no roles. The image creates `POSTGRES_USER` on
first start, which owns everything here; the `backup` role (see
[The box](#the-box)) has to be created again. The server must be the dump's
major (17) or newer.

**Verify.** Row counts per table, against the drill's (12 tables, 53 users,
flyway at 5 migrations on 2026-10-27):

```sh
docker compose exec -T <postgres> psql -U postgres -d postgres \
  -c "select schemaname, relname, n_live_tup from pg_stat_user_tables order by 1,2"
```

Then `DhsDumpStale` stays quiet after the next night's dump.

**Drill.** Run once on 2026-10-27, in `dhs`: a `ReplicationDestination`
(`trigger.manual`, `copyMethod: Direct`, uid 70) into a throwaway `fast` PVC
`drill`, then a pod on `postgres:17.11-alpine` that mounts it read-only,
starts a socket-only postgres in an `emptyDir` and restores into it:

```sh
initdb -D /tmp/pg
pg_ctl -D /tmp/pg -o "-k /tmp -c listen_addresses=''" -w start
createdb -h /tmp drill
pg_restore -h /tmp -d drill --no-owner --no-privileges --exit-on-error /restore/postgres.dump
psql -h /tmp -d drill -c "select schemaname, relname, n_live_tup from pg_stat_user_tables order by 1,2"
```

Result: clean restore, 12 tables (53 users, flyway at 5 migrations).

## Monitoring

See [Monitoring](../monitoring.md).

- `DhsDown` -- node_exporter unreachable for 5m: the box, its tailscale, or
  the proxy. Critical.
- `DhsDumpStale` -- no successful dump in 26h. Warning. Without it VolSync
  would keep backing up a stale file without complaint.

## Gotchas

- **`dump.yaml`'s image tracks the server's major (17).** An older `pg_dump`
  refuses the server, a newer one writes dumps the server's own `pg_restore`
  cannot read. Bump both together.
- **The proxy forwards every port;** the tailnet policy is what limits
  `tag:k8s` to 5432 and 9100.
- **The `instance` label is relabelled to `dhs`** -- the target address is
  only the proxy Service's name.
