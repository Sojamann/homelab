provider "proxmox" {
  endpoint = local.proxmox_endpoint

  # PROXMOX_VE_API_TOKEN, exported by scripts/tofu.sh from the ansible vault.
  # Minted by machine-config, so it is never defined in this stage.

  insecure = false

  # Snippets are the one thing this layer cannot do over the API: Proxmox's
  # upload endpoint takes iso, vztmpl and import and nothing else, so a
  # cloud-init snippet has to be written on the node itself and the provider
  # scps it. Everything else here still goes over the API.
  #
  # `agent = true` uses the operator's own ssh-agent rather than putting a key
  # in this layer -- the same key that already reaches the node, so there is no
  # second credential to manage or rotate.
  ssh {
    agent    = true
    username = "root"
  }
}

# used for DNS records
provider "unifi" {
  api_url = "https://10.212.1.1"

  # UNIFI_API_KEY, exported by scripts/tofu.sh from the ansible vault -- the
  # same key the network layer uses.

  # The controller's certificate is self-signed.
  allow_insecure = true
}
