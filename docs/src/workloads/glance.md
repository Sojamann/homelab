# Glance

## What it's for

The lab start page: bookmarks to the apps, the lab UIs and the infra, plus
release tracking for every version the cluster and platform layers pin.
Upstream `glanceapp/glance`, pinned by tag.

## Access

- **URL:** `https://dash.<app_domain>`
- **Reachability:** LAN and tailnet, like everything behind the gateway. Not
  public. See [Networking](../networking.md).
- **Login:** none.

## Where it runs

Namespace `glance`, one Deployment, Flux Kustomization `glance`.
Wiring: [Build guide: Glance](../build/flux/docs/glance.md).

## Data

None. The whole page is `apps/glance/glance.yml` in the apps repo, mounted
from a ConfigMap. Rebuildable from git.

## Backup & restore

Nothing to back up. Restore = Flux reconciling `glance`:

```sh
flux reconcile kustomization glance --with-source
kubectl -n glance rollout status deploy/glance
```

**Verify.** The page loads and the releases widget shows versions (it needs
internet egress, see below).

## Admin

**Config.** Edit `apps/glance/glance.yml`. A `configMapGenerator` turns it
into a ConfigMap whose name carries a content hash, so an edit rolls the pod.

Logos load in the browser from the `homarr-labs/dashboard-icons` jsDelivr CDN,
pinned to a commit since that repo has no tags. Own apps use `mdi:` icons.

**Release tracking.** Fetched server-side, so the pod needs egress to the
internet.

- `releases`: every version the cluster and platform layers pin.
  Unauthenticated GitHub allows 60 requests/hour, plenty for a dozen repos.
  Past ~20, add a token via an `ExternalSecret`.
- Proxmox and TrueNAS publish no GitHub releases, so they are not tracked;
  their forum announcement feeds were too noisy to be worth a widget.

Compare against the version locals in `cluster/` and `platform/` when
bumping. A new pinned component gets a line in `glance.yml`.

**Updates.** Bump the tag in `apps/glance/server.yaml`.

## Gotchas

- **Flux substitutes `${app_domain}` and `${lab_domain}`** into `glance.yml`
  like any other manifest. A literal dollar sign must be written `$$`, so
  Glance's own `${ENV}` syntax is unusable without escaping.
- **Some release repos are stand-ins:** ESO's latest release alternates
  between app and chart tags; democratic-csi only releases its chart;
  snapshot-controller is tracked via `kubernetes-csi/external-snapshotter`.
