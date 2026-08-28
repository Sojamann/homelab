locals {
  kubeconfig = "${path.module}/../secrets/kubeconfig"
}

provider "helm" {
  kubernetes = {
    config_path = local.kubeconfig
  }
}

provider "kubectl" {
  config_path      = local.kubeconfig
  load_config_file = true

  # Charts in this layer install CRDs that later resources use. The helm
  # release returns once the CRDs are created; the apiserver takes a moment
  # longer to serve them in discovery, and on a first apply that gap is real.
  apply_retry_count = 5
}

# Address and token both come from the environment: scripts/tofu.sh opens a
# port-forward to `svc/openbao` and exports VAULT_ADDR onto it, with the root
# token out of the ansible vault. Empty on a first install, and every resource
# using it is excluded from that pass by `-target` -- see platform/README.md.
provider "vault" {}
