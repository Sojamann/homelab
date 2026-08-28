terraform {
  required_version = "~> 1.12"

  # State is committed, encrypted. The network layer commits its state because
  # it cannot put it anywhere else; this layer commits its state for a
  # different reason, and the reason is worth stating plainly:
  #
  #   `talos_machine_secrets` holds the Talos CA, the Kubernetes CA, the etcd
  #   CA and the service-account key. That material exists nowhere else. Every
  #   other layer's state describes things that can be rediscovered from the
  #   infrastructure -- lose it and you re-import. Lose this and you cannot
  #   authenticate to the cluster at all, by any means, and the only way
  #   forward is to rebuild it and everything on it.
  #
  # Committed and encrypted is therefore not a convenience: it is the
  # difference between one copy on one laptop and a versioned, off-machine one.
  #
  # Off-machine, but not public. It lives in `secrets/`, a private submodule:
  # this file is the CA, and a CA in a public repo is one offline attack on one
  # passphrase away from being someone else's.
  backend "local" {
    path = "../secrets/state/cluster.tfstate"
  }

  encryption {
    # TF_VAR_terraform_state_passphrase, exported by scripts/tofu.sh from the
    # ansible vault -- the same passphrase the network layer uses. Two things
    # follow: the cluster CA is exactly as strong as the vault password, and
    # losing the passphrase makes this unreadable in history as well as in the
    # working tree.
    key_provider "pbkdf2" "vault" {
      passphrase = var.terraform_state_passphrase
    }

    method "aes_gcm" "default" {
      keys = key_provider.pbkdf2.vault
    }

    state {
      method = method.aes_gcm.default
    }

    # Only written with `-out`, but it holds the same secrets when it is.
    plan {
      method = method.aes_gcm.default
    }
  }

  required_providers {
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.11"
    }

    # The nodes are found by their Proxmox tags rather than listed here -- see
    # cluster_nodes.tf. Read-only: this layer never creates a VM.
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.111"
    }

    # One record: the VIP. Same provider and key as the other two layers.
    unifi = {
      source  = "filipowm/unifi"
      version = "~> 1.1"
    }

    # Cilium, which this cluster cannot come up without -- `cni: none` means
    # the nodes stay NotReady until it is installed.
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3"
    }

    # Two Cilium CRs, and the reason it is not `kubernetes_manifest`:
    # that resource does API discovery at *plan* time, so it cannot plan a
    # custom resource whose CRD does not exist yet -- which on a first apply is
    # every Cilium CRD. This provider applies YAML without the discovery, so
    # one `tofu apply` gets from nothing to a cluster that can hand out a
    # LoadBalancer address.
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.4"
    }

    # The Gateway API CRDs, fetched from a pinned upstream tag rather than
    # vendored -- see cluster_gateway_api.tf.
    http = {
      source  = "hashicorp/http"
      version = "~> 3.5"
    }

    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}
