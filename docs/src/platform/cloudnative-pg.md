# CloudNativePG

## What it's for

The Postgres operator. It installs the `Cluster` CRD and its kin, watches
every namespace, and runs databases declared beside the app that owns them.
It runs no database itself.

**No `Cluster` exists today.** Nothing under `flux/apps/` declares one; DHS's
postgres runs on its own box outside the cluster (see
[DHS](../workloads/dhs.md)). The operator is installed ahead of a first user.

## Access

No UI, no login. `kubectl` with `secrets/kubeconfig`; the `cnpg` kubectl
plugin is not pinned in `mise.toml`.

```sh
kubectl -n cnpg-system get deploy,pods
kubectl get clusters.postgresql.cnpg.io -A
```

## Where it runs

Namespace `cnpg-system`, HelmRelease `cloudnative-pg` from an OCIRepository
(`ghcr.io/cloudnative-pg/charts/cloudnative-pg`), 1 replica, `clusterWide`,
CRDs created by the chart. In `flux/infrastructure/controllers/cloudnative-pg/`,
Flux Kustomization `infrastructure`. No wiring doc in the Build guide; see
[Build guide: Flux, *Infrastructure*](../build/flux/README.md#infrastructure).

## Data

None of its own. A future `Cluster`'s PVCs and backups belong to that app.

## Backup & restore

Nothing to back up: the operator is rebuilt from git. CNPG's own backup
feature is not used.

**Verify.** `kubectl -n cnpg-system rollout status deploy/cloudnative-pg` and
`kubectl get crd clusters.postgresql.cnpg.io`.

## Admin

**Upgrades.** The chart tag is pinned in `repository.yaml`; Renovate proposes
bumps, merging deploys. The chart carries the CRDs along.

**Adding a database.** A `Cluster` in the app's directory under `apps/` --
never in `infrastructure/controllers/`, which is applied in the same pass as
the chart that defines the kind. `apps` waits for `infrastructure` to be
healthy, so the CRDs exist by then.

## Gotchas

- **Never rename or prune the `infrastructure` Kustomization.** Pruning the
  release removes its CRDs, and with them every `Cluster` and its database.
- **Single replica**, like every controller here; raise alongside a second
  control plane.

## What breaks without it

Today: nothing. With databases: no failover, no reconciliation or
maintenance of them; whether the instances keep serving depends on CNPG's
behaviour and is not tested here.
