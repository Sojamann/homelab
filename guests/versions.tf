terraform {
  required_version = "~> 1.12"

  # State is committed and encrypted as it contains sensitive information
  #
  # Committed to `secrets/`, a private submodule, not to this repo -- see the
  # network layer for why encrypted ciphertext still does not belong in public.
  backend "local" {
    path = "../secrets/state/guests.tfstate"
  }

  encryption {
    # TF_VAR_terraform_state_passphrase, exported by scripts/tofu.sh from the ansible vault
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
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.84"
    }

    # A guest's DNS record belongs with the guest, not with the network -- see
    # providers.tf. Same provider and version as the network layer.
    unifi = {
      source  = "filipowm/unifi"
      version = "~> 1.1"
    }

    # The guests' SSH key: minted by tls, written out by local. Both only
    # exist for ssh_key.tf.
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }

    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }

    # Only for the image factory schematic -- see guest_talos_image.tf. The
    # schematic describes the image a guest boots, which is this layer's
    # business; everything about the cluster the guests then form is the
    # cluster layer's, and no credential of its appears here.
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.11"
    }
  }
}
