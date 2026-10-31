# Zot

## What it's for

In-cluster OCI registry for own images (e.g. Kassenbuch), so they need not go
to ghcr. Own images only: no pull-through cache, so the nodes need no mirror
config.

## Access

- **URL / UI:** `https://registry.<app_domain>`. LAN and tailnet.
- **Pull:** anonymous -- no `imagePullSecret` anywhere. Nodes pull through the
  Gateway like any client; the wildcard cert is Let's Encrypt, so containerd
  trusts it without Talos config.
- **Push / delete:** user `push`, htpasswd. Once per workstation:
  ```sh
  bao kv get -mount=kv -field=password zot/registry \
    | crane auth login registry.<app_domain> -u push --password-stdin
  ```
- **Break-glass:** none needed beyond the above; the password lives only in
  OpenBao (`kv/zot/registry`), so OpenBao's root token is the way in when OIDC
  is down.

## Where it runs

Namespace `zot`, one Deployment (`Recreate`, uid 1000), Service `:5000`,
HTTPRoute with `timeout 0s`. Config in `config.json` beside it, in
`flux/infrastructure/controllers/zot/`; Flux Kustomization `infrastructure`.
Wiring: [Build guide: Zot](../build/flux/docs/zot.md).

## Data

PVC `zot-data`, `bulk` (RWX, on the mirror), at `/var/lib/registry`. The 20Gi
request is a label -- an NFS directory, not enforced. Not state: the config
(git), the htpasswd (generated in `platform_secrets.tf`).

On `bulk`, not `fast`: an empty registry means re-pushing every own image
before its app can restart.

## Backup & restore

[ZFS snapshots](../backups.md#zfs-snapshots) on `slow/k8s-csi`, 24 hourly +
30 daily. Not VolSync. Everything in it is rebuildable from source.

**Restore** a lost directory: the generic `bulk` restore in
[ZFS snapshots](../backups.md#zfs-snapshots), app `zot`, Kustomization
`infrastructure`. **Or rebuild:** let it come up empty and re-push each image
the manifests reference (`mise run image <app> <version>`, from the app's
built image).

**Verify.**

```sh
kubectl -n zot rollout status deploy/zot
crane ls registry.<app_domain>/<app>        # the tags the manifests reference
```

## Admin

**Releasing** an own image:

```sh
# in the app repo: clean tree, tagged HEAD, tests, linux/amd64 into local docker
mise run release                       # -> kassenbuch:1.0.1

# in lab
mise run image kassenbuch 1.0.1        # push to zot, bump flux/apps/kassenbuch
git add <...> && mise run save "kassenbuch: 1.0.1"
```

`image` refuses a non-semver tag (retention would delete it), a non-
`linux/amd64` image, and a tag zot already has -- a node that pulled it keeps
its copy, so overwriting would run different code depending on where the pod
lands. It only rewrites `image: registry.${app_domain}/<app>:` lines, so an
app moves onto zot by hand once. Renovate skips images in zot.

**Retention.** Repositories are flat, `registry.<app_domain>/<app>:<tag>`.

| Tag | Kept |
|--|--|
| `1.2.3` / `v1.2.3` | the 5 most recently pushed |
| `sha-*`, `dev-*` | pushed within 14 days |
| anything else, `latest` included | **deleted** |

Untagged manifests and orphaned referrers go after 24h; GC runs daily. Live,
no dry run. Rolling back further than 5 releases means re-pushing.

**Rotate the push password:** `-replace=random_password.zot_push` on
`mise run platform apply`, force-sync the `zot` ExternalSecret, restart zot
(it re-reads htpasswd on start), log in again on each workstation.

## Gotchas

- **Retention judges by push, not pull.** Zot cannot see what is deployed, and
  containerd never re-pulls a cached image -- a `pulledWithin` rule would
  delete the image a running app needs on its next node rebuild.
- **`compat: docker2s2`** is on so a plain `docker push` is accepted.
- **One replica**: two instances GC-ing one directory would race.
- **Envoy's 15s default** would cut off large layer uploads, hence the route
  timeout.

## What breaks without it

Own apps cannot pull on a restart or reschedule onto a node without the
image cached. Running pods are unaffected; public images are unaffected.
