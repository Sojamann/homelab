#!/usr/bin/env bash
# Runs tofu in one layer, with that layer's secrets pulled straight out of the
# ansible vault so no credential sits unencrypted on disk.
#
#   scripts/tofu.sh <layer> [tofu args...]
set -euo pipefail
cd "$(dirname "$0")/.."

layer="${1:?usage: tofu.sh <layer> [args...]}"
shift

# shellcheck source=lib.sh
. scripts/lib.sh

require() {
  [ -n "${!1}" ] || { echo "$2" >&2; exit 1; }
}

# Both layers name things after the domain, and the domain is the one
# deployment-specific value in the repo. Assigned before it is exported --
# `export x=$(cmd)` reports export's status, not the command's, so a missing
# key would sail through as "lab." instead of failing.
zone="$(vault_require secrets/vault.yml zone)"
export TF_VAR_lab_domain="lab.$zone"

# The zone's other half: hosted services, behind the cluster's gateway. The
# split is network/README.md's -- infrastructure names under `lab.`, service
# names under `app.`, and a wildcard record for the second.
export TF_VAR_app_domain="app.$zone"

case "$layer" in
  network)
    for key in terraform_state_passphrase unifi_api_key \
               wifi_trusted_ssid wifi_iot_ssid \
               wifi_trusted_passphrase wifi_iot_passphrase; do
      value="$(vault_require secrets/vault.yml "$key")"
      case "$key" in
        unifi_api_key) export UNIFI_API_KEY="$value" ;;
        *) export "TF_VAR_$key=$value" ;;
      esac
    done
    unset value
    ;;
  guests)
    PROXMOX_VE_API_TOKEN="$(vault_get secrets/proxmox-token.yml pve_api_token)"
    export PROXMOX_VE_API_TOKEN
    require PROXMOX_VE_API_TOKEN \
      "no pve_api_token in secrets/proxmox-token.yml -- rerun machine-config"

    # Each guest carries its own DNS record, so this layer talks to the
    # controller as well as to Proxmox.
    UNIFI_API_KEY="$(vault_require secrets/vault.yml unifi_api_key)"
    export UNIFI_API_KEY

    # This layer's state is committed, encrypted -- both credentials above and
    # the guests' SSH private key are in it. Same passphrase as the others.
    TF_VAR_terraform_state_passphrase="$(vault_require secrets/vault.yml terraform_state_passphrase)"
    export TF_VAR_terraform_state_passphrase
    ;;
  cluster)
    # The same three as `guests`, for different reasons. Spelled out here
    # rather than shared with that branch: the value of this file is that one
    # branch tells you everything a layer touches.

    # The nodes are found by their Proxmox tags, not from a list -- see
    # cluster/cluster_nodes.tf.
    PROXMOX_VE_API_TOKEN="$(vault_get secrets/proxmox-token.yml pve_api_token)"
    export PROXMOX_VE_API_TOKEN
    require PROXMOX_VE_API_TOKEN \
      "no pve_api_token in secrets/proxmox-token.yml -- rerun machine-config"

    # The VIP's DNS record belongs with the VIP, which is defined here.
    UNIFI_API_KEY="$(vault_require secrets/vault.yml unifi_api_key)"
    export UNIFI_API_KEY

    # This layer's state is committed, encrypted -- it holds the cluster's
    # CAs, which exist nowhere else. Same passphrase as the network layer.
    TF_VAR_terraform_state_passphrase="$(vault_require secrets/vault.yml terraform_state_passphrase)"
    export TF_VAR_terraform_state_passphrase
    ;;
  platform)
    # Two, and neither is Proxmox or UniFi: this layer talks to the cluster and
    # to the NAS, and to nothing else in the lab.

    # Its state is committed, encrypted -- not because anything here exists
    # only in state, but because the TrueNAS key below ends up in it.
    TF_VAR_terraform_state_passphrase="$(vault_require secrets/vault.yml terraform_state_passphrase)"
    export TF_VAR_terraform_state_passphrase

    # democratic-csi's own API key, scoped to the `democratic-csi` user on the
    # NAS -- see machines/truenas.md.
    TF_VAR_truenas_api_key="$(vault_require secrets/vault.yml truenas_api_key)"
    export TF_VAR_truenas_api_key

    # cert-manager proves the domain over DNS-01 with the same token Proxmox
    # uses, and registers its ACME account with the same address. Neither is
    # dialled from here -- both are written into the cluster for Flux.
    TF_VAR_cloudflare_api_token="$(vault_require secrets/vault.yml cloudflare_api_token)"
    export TF_VAR_cloudflare_api_token

    TF_VAR_acme_email="$(vault_require secrets/vault.yml acme_email)"
    export TF_VAR_acme_email

    # OpenBao is the exception to everything above: this layer does not only
    # write it into the cluster, it configures it over its own API. That needs
    # a route from here to a ClusterIP service, and a port-forward is the only
    # one that adds neither exposure nor a second credential -- it rides the
    # apiserver connection the providers already hold, and the root token never
    # leaves loopback.
    #
    # `vault_get`, not `vault_require`: the first install cannot have a token.
    # The vault has to be running before `bao operator init` can produce one,
    # which is why that install is two passes -- see platform/README.md.
    bao_root_token="$(vault_get secrets/vault.yml bao_root_token)"
    if [ -n "$bao_root_token" ]; then
      export KUBECONFIG="$PWD/secrets/kubeconfig"
      kubectl port-forward -n openbao svc/openbao 8200:8200 >/dev/null 2>&1 &
      bao_pf=$!
      trap 'kill "$bao_pf" 2>/dev/null || true' EXIT

      # The tunnel is not up when the command returns. A long apply can also
      # outlive it, and when it dies tofu reports a connection refused that
      # says nothing about port-forwarding -- rerun, the resources are
      # idempotent.
      for _ in $(seq 50); do
        (exec 3<>/dev/tcp/127.0.0.1/8200) 2>/dev/null && break
        sleep 0.1
      done

      export VAULT_ADDR="http://127.0.0.1:8200"
      export VAULT_TOKEN="$bao_root_token"
    fi
    ;;
  *)
    echo "unknown layer: $layer" >&2
    exit 1
    ;;
esac

cd "$layer"
[ -d .terraform ] || tofu init

# Not `exec` while a tunnel is open: the trap that closes it has to run.
if [ -n "${bao_pf:-}" ]; then
  tofu "$@"
else
  exec tofu "$@"
fi
