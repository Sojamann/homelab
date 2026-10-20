#!/usr/bin/env bash
# `aws s3` against Garage on the NAS, as one of its keys from the vault.
#
#   scripts/s3.sh <key> <aws s3 args...>
#   scripts/s3.sh volsync ls s3://k8s-backups/
#   scripts/s3.sh volsync rm --recursive --dryrun s3://k8s-backups/<ns>/<pvc>/
#
# <key> names the vault pair `garage_<key>_key_id` / `garage_<key>_secret_key`.
# A key only sees the buckets it was granted.
set -euo pipefail
cd "$(dirname "$0")/.."

key="${1:?usage: s3.sh <key> <aws s3 args...>}"
shift

# shellcheck source=lib.sh
. scripts/lib.sh

AWS_ACCESS_KEY_ID="$(vault_require secrets/vault.yml "garage_${key}_key_id")"
AWS_SECRET_ACCESS_KEY="$(vault_require secrets/vault.yml "garage_${key}_secret_key")"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION=lab

# No profile or config from ~/.aws may leak in and override the above.
export AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null

exec aws --endpoint-url "https://s3.lab.$(vault_require secrets/vault.yml zone):3900" s3 "$@"
