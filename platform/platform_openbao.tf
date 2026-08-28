# The cluster's secret store.
locals {
  openbao_version = "0.29.4" # chart; appVersion v2.6.2

  # Bump to rotate the seal key. The identifier and the key material must move
  # together: OpenBao records the id it sealed with, and a mismatch is a vault
  # that will not start rather than one that complains.
  openbao_seal_key_id = "1"

  openbao_namespace = "openbao"
  openbao_host      = "bao.${var.app_domain}"

  # Named here because the auth role below binds them and the chart in
  # platform_external_secrets.tf creates them -- one spelling, two files.
  eso_namespace       = "external-secrets"
  eso_service_account = "external-secrets"
}

resource "kubectl_manifest" "openbao_namespace" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Namespace"
    metadata   = { name = local.openbao_namespace }
  })
}

# The seal key, and the reason this vault comes back from a reboot on its own.
#
# OpenBao starts sealed. The alternatives to a key it can read for itself are
# Shamir -- three key shares typed in by hand after every restart, on a
# single-node cluster that restarts for every Talos upgrade -- or a KMS this
# lab does not have. `seal "static"` is upstream's answer for exactly that
# case: a 32-byte AES key from somewhere the environment already keeps
# secrets.
#
# The key sits next to the lock, deliberately. What guards it is RBAC on this
# Secret and on the namespace, not the seal.
resource "random_bytes" "openbao_seal" {
  length = 32
}

resource "kubectl_manifest" "openbao_seal_key" {
  depends_on = [kubectl_manifest.openbao_namespace]

  sensitive_fields = ["data.unseal-key"]

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Secret"
    metadata = {
      name      = "openbao-seal"
      namespace = local.openbao_namespace
    }
    data = {
      unseal-key = random_bytes.openbao_seal.base64
    }
  })
}

resource "helm_release" "openbao" {
  name       = "openbao"
  repository = "https://openbao.github.io/openbao-helm"
  chart      = "openbao"
  version    = local.openbao_version
  namespace  = local.openbao_namespace

  depends_on = [
    kubectl_manifest.openbao_namespace,
    kubectl_manifest.openbao_seal_key,
  ]

  # The readiness probe execs `bao status`, which is non-zero on a vault that
  # has never been initialized -- so the pod is legitimately NotReady until
  # `bao operator init` runs, and that cannot happen until this release exists.
  # Waiting would be waiting on a step this apply is a prerequisite for.
  wait = false

  values = [yamlencode({

    injector = { enabled = false } # we use ESO over side-car injector

    server = {
      ha = {
        enabled  = true
        replicas = 1 # raise alongside the second control plane

        # (n/2)-1 of one replica is not a useful number.
        disruptionBudget = { enabled = false }

        raft = {
          enabled = true

          # This lands in a ConfigMap, so nothing secret may appear in it --
          # the seal key is a file mounted from the Secret above.
          #
          # The StatefulSet updates `OnDelete`: changing anything here takes
          # effect on `kubectl -n openbao delete pod openbao-0`, not on apply.
          config = <<-HCL
            ui = true

            # Required by integrated storage, and the reason this pod needs no
            # elevated capabilities.
            disable_mlock = true

            listener "tcp" {
              tls_disable     = 1
              address         = "[::]:8200"
              cluster_address = "[::]:8201"
            }

            storage "raft" {
              path = "/openbao/data"
            }

            service_registration "kubernetes" {}

            # Every request, to the pod log. Declared here because OpenBao
            # refuses to enable an audit device over the API: a `file` device
            # writes to any path it is given.
            #
            # Devices fail closed -- if none can write, OpenBao stops serving
            # rather than lose an entry. On the data volume that would make a
            # full 1Gi PVC a total outage; the cost of stdout is a trail that
            # dies with the pod.
            audit "file" "stdout" {
              description = "Every request, to the pod log"
              options {
                file_path = "stdout"
              }
            }

            seal "static" {
              current_key_id = "${local.openbao_seal_key_id}"
              current_key    = "file:///openbao/seal/unseal-key"
            }
          HCL
        }
      }

      # Every secret in the cluster lives here. 
      dataStorage = {
        enabled      = true
        size         = "1Gi"
        storageClass = "fast"
      }

      auditStorage = { enabled = false } # logging on stdout

      volumes = [{
        name   = "seal"
        secret = { secretName = "openbao-seal" }
      }]

      volumeMounts = [{
        name      = "seal"
        mountPath = "/openbao/seal"
        readOnly  = true
      }]

      gateway = {
        httpRoute = {
          enabled    = true
          hosts      = [local.openbao_host]
          parentRefs = [{ name = "lab", namespace = "gateway", sectionName = "https" }]
        }
      }
    }
  })]
}

# --- What is inside it ------------------------------------------------------
#
# Everything below needs a running, initialized OpenBao, and the release above
# cannot provide one within the same apply: `bao operator init` is a manual
# step between two passes. See "First install" in the README.

# One kv-v2 mount, and the tree under it is `kv/<namespace>/<app>/<key>`.
resource "vault_mount" "kv" {
  path        = "kv"
  type        = "kv"
  options     = { version = "2" }
  description = "Cluster secrets, one subtree per namespace"
}

# How ESO proves who it is, and the reason no credential exists for it
# anywhere: it presents its own ServiceAccount token and OpenBao asks the
# apiserver whether that token is real.
resource "vault_auth_backend" "kubernetes" {
  type        = "kubernetes"
  description = "In-cluster workloads, by ServiceAccount"
}

resource "vault_kubernetes_auth_backend_config" "kubernetes" {
  backend         = vault_auth_backend.kubernetes.path
  kubernetes_host = "https://kubernetes.default.svc"
}

# Read on everything, which is wider than it looks: ESO is one deputy holding
# the whole tree, so anything that can create an `ExternalSecret` in any
# namespace can read any secret in the cluster. Accepted because every
# workload here arrives through a commit in the apps repo 
resource "vault_policy" "external_secrets" {
  name = "external-secrets"

  policy = <<-HCL
    path "kv/data/*" {
      capabilities = ["read"]
    }

    path "kv/metadata/*" {
      capabilities = ["read", "list"]
    }
  HCL
}

resource "vault_kubernetes_auth_backend_role" "external_secrets" {
  backend   = vault_auth_backend.kubernetes.path
  role_name = local.eso_service_account

  bound_service_account_names      = [local.eso_service_account]
  bound_service_account_namespaces = [local.eso_namespace]

  token_policies = [vault_policy.external_secrets.name]
  token_ttl      = 3600
}
