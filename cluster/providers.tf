# Read-only. This layer finds the Talos guests by their tags; the guests layer
# is the only one that creates or destroys them.
provider "proxmox" {
  endpoint = local.proxmox_endpoint

  # PROXMOX_VE_API_TOKEN, exported by scripts/tofu.sh from the ansible vault.

  insecure = false
}

provider "unifi" {
  api_url = "https://10.212.1.1"

  # UNIFI_API_KEY, exported by scripts/tofu.sh from the ansible vault.

  # The controller's certificate is self-signed.
  allow_insecure = true
}

locals {
  kube = talos_cluster_kubeconfig.this.kubernetes_client_configuration
}

provider "helm" {
  kubernetes = {
    host                   = local.kube.host
    cluster_ca_certificate = base64decode(local.kube.ca_certificate)
    client_certificate     = base64decode(local.kube.client_certificate)
    client_key             = base64decode(local.kube.client_key)
  }
}

provider "kubectl" {
  host                   = local.kube.host
  cluster_ca_certificate = base64decode(local.kube.ca_certificate)
  client_certificate     = base64decode(local.kube.client_certificate)
  client_key             = base64decode(local.kube.client_key)
  load_config_file       = false

  # The credentials above are unknown until `talos_cluster_kubeconfig` applies,
  # and this provider builds its client while it configures itself -- at plan
  # time, where it would see them as empty and refuse. `lazy_load` defers that
  # until a resource actually needs the client, by which point they are real.
  lazy_load = true

  # The two Cilium CRs race the apiserver's discovery of the CRDs the helm
  # release just installed. Retrying is the fix the provider offers.
  apply_retry_count = 5
}
