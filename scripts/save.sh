#!/usr/bin/env bash
# Commits a change that spans this repo and its submodules: whatever you have
# staged here, plus whatever is dirty in `flux/` and `secrets/`.
#
#   git add <the files you changed>
#   mise run save "cluster: a second control plane"
#
# `git push` afterwards carries the submodule commits along
# (push.recursesubmodules=on-demand).
set -euo pipefail
cd "$(dirname "$0")/.."

msg="${1:?usage: save.sh <message>}"

dirty=()
for sub in flux secrets; do
  [ -n "$(git -C "$sub" status --porcelain)" ] && dirty+=("$sub")
done

[ ${#dirty[@]} -gt 0 ] || {
  echo "flux/ and secrets/ are clean -- nothing to save, commit here directly" >&2
  exit 1
}

# The children first: the parent's commit *is* the new pointer, so it cannot be
# written until the commits it points at exist.
for sub in "${dirty[@]}"; do
  git -C "$sub" add -A
  git -C "$sub" commit -qm "$msg"
done

git add "${dirty[@]}"
git commit -qm "$msg"

# And now the back-reference, which could not be part of the message above --
# the parent's hash did not exist yet. A note attaches to a commit without
# changing it, so the pointer the parent just recorded stays valid.
#
# `git push` ignores notes by default. Each submodule's remote.origin.push
# carries a `refs/notes/*` refspec so these travel with the commits.
parent="$(git rev-parse HEAD)"
for sub in "${dirty[@]}"; do
  git -C "$sub" notes add -f -m "lab@$parent" HEAD
  printf '%-8s %s  %s\n' "$sub" "$(git -C "$sub" rev-parse --short HEAD)" "$msg"
done
printf '%-8s %s  %s\n' lab "$(git rev-parse --short HEAD)" "$msg"
