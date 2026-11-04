terraform {
  required_version = "~> 1.12"

  # State is committed, encrypted -- the same treatment the other two tofu
  # layers get, for a third reason.
  #
  # This state is not irreplaceable the way `cluster`'s is: nothing here exists
  # only in the state file, and losing it costs a re-import rather than the
  # cluster. What it does hold is a live credential -- the TrueNAS API key
  # reaches the driver through a helm value, and a helm value is stored.
  #
  # So the choice is not "commit or don't", it is "encrypted in git, or
  # plaintext in the working tree". The second is strictly worse.
  #
  # "In git" means `secrets/`, a private submodule -- a live credential is a
  # live credential whether or not it is encrypted at rest.
  backend "local" {
    path = "../secrets/state/platform.tfstate"
  }

  encryption {
    # TF_VAR_terraform_state_passphrase, exported by scripts/tofu.sh from the
    # ansible vault. Three layers now share it, which means the vault password
    # is the single key to the cluster CAs *and* to the NAS credential.
    key_provider "pbkdf2" "vault" {
      passphrase = var.terraform_state_passphrase
    }

    method "aes_gcm" "default" {
      keys = key_provider.pbkdf2.vault
    }

    state {
      method = method.aes_gcm.default
    }

    plan {
      method = method.aes_gcm.default
    }
  }

  required_providers {
    # Most of this layer is a chart. Every release comes from an upstream
    # repository rather than being vendored -- the versions are pinned in each
    # component file, which is where the upgrade note lives.
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3"
    }

    # Namespaces and the Secrets that have to exist before the chart that
    # reads them -- neither of which helm can place (`create_namespace` makes
    # a bare namespace and nothing else).
    #
    # `kubectl` rather than `kubernetes` for the same reason the cluster layer
    # gives: `kubernetes_manifest` does API discovery at plan time, and this
    # layer plans against a cluster whose CRDs it is in the middle of
    # installing. Keeping one provider for all raw manifests means the next
    # component here does not have to think about it.
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.4"
    }

    # OpenBao's seal key, and later the passwords this layer hands out. Both
    # are born here and exist nowhere else -- which is the second reason the
    # state below is encrypted.
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }

    # OpenBao's insides -- the kv mount, the policies, the Kubernetes auth
    # method. There is no `openbao` provider in the registry; OpenBao speaks
    # Vault's API and this is the client for it. Address and token arrive as
    # VAULT_ADDR and VAULT_TOKEN from scripts/tofu.sh, so it is the one
    # provider here that is not configured in providers.tf.
    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.11"
    }
  }
}
