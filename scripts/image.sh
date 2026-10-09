#!/usr/bin/env bash
# Moves a locally built image into zot and points the app's manifests at it.
# The app repo builds `<app>:<version>` into the local docker store; this is
# the only place that knows the registry.
#
#   scripts/image.sh <app> <version>
#
# Commits nothing -- review, then `mise run save`.
set -euo pipefail
cd "$(dirname "$0")/.."

app="${1:?usage: image.sh <app> <version>}"
version="${2:?usage: image.sh <app> <version>}"

# shellcheck source=lib.sh
. scripts/lib.sh

die() { echo "$*" >&2; exit 1; }

# zot's retention keeps only these; anything else is gone within a day.
[[ "$version" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || die "$version is not semver -- zot's retention would delete it"

local_ref="$app:$version"
platform="$(docker image inspect -f '{{.Os}}/{{.Architecture}}' "$local_ref" 2>/dev/null)" \
  || die "no local image $local_ref -- build it in the app repo first"
[ "$platform" = linux/amd64 ] \
  || die "$local_ref is $platform, the nodes are linux/amd64"

host="registry.app.$(vault_require secrets/vault.yml zone)"
ref="$host/$app:$version"

# Never overwrite: a node that already pulled the tag keeps its copy, so a
# rebuilt tag would run different code depending on where the pod lands.
status="$(curl -s -o /dev/null -w '%{http_code}' \
  -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
  "https://$host/v2/$app/manifests/$version")"
case "$status" in
  404) ;;
  200) die "$ref already exists -- release a new version instead" ;;
  *) die "could not ask $host about $ref (HTTP $status)" ;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
docker save -o "$tmp/image.tar" "$local_ref"
crane push "$tmp/image.tar" "$ref"

# The manifests name the registry by `${app_domain}`, substituted by Flux.
pattern="registry\.\\\$\{app_domain\}/$app:"
files="$(grep -rlE "image: $pattern" "flux/apps/$app" 2>/dev/null || true)"
[ -n "$files" ] || die "pushed $ref, but nothing in flux/apps/$app references registry.\${app_domain}/$app"
for f in $files; do
  sed -i.bak -E "s#(image: $pattern)[^[:space:]]+#\1$version#" "$f" && rm "$f.bak"
done

git -C flux diff --stat
echo "pushed $ref -- review, then: git add <...> && mise run save \"$app: $version\""
