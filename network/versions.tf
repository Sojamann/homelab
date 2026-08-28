terraform {
  required_version = "~> 1.12"

  # State is committed, encrypted. This layer cannot keep its state on the NAS.
  #
  # Committed to `secrets/`, a private submodule, not to this repo: encrypted
  # is not the same as unreadable, and ciphertext in a public repo can be
  # ground on offline, forever, by anyone.
  backend "local" {
    path = "../secrets/state/network.tfstate"
  }

  encryption {
    # TF_VAR_terraform_state_passphrase, exported by scripts/tofu.sh from
    # the ansible vault. Losing it makes every committed state unreadable,
    # history included, so it belongs in a password manager as well as the
    # vault.
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
    unifi = {
      source  = "filipowm/unifi"
      version = "~> 1.1"
    }
  }
}
