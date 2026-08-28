# Cilium, and the address range it hands out.
#
# The cluster is generated with `cni: none`, so this is not an add-on: without
# it the nodes never leave NotReady and CoreDNS never schedules.
#
# It also replaces kube-proxy, which is why `cluster.proxy.disabled` is set in
# the machineconfig. Talos's KubePrism, on by default, is what makes that work
# before the apiserver is reachable through a Service.

locals {
  cilium_version = "1.19.7"

  ingress_ip = "10.212.4.200"

  lb_pool_start = "10.212.4.201"
  lb_pool_stop  = "10.212.4.254"

  # The Service Cilium generates for a Gateway: `cilium-gateway-<name>`, in the
  # Gateway's own namespace. Both halves are stated in the apps repo
  # (`infrastructure/configs`), so renaming the Gateway there breaks the
  # reservation here
  ingress_gateway_namespace = "gateway"
  ingress_gateway_service   = "cilium-gateway-lab"
}

resource "helm_release" "cilium" {
  name       = "cilium"
  repository = "https://helm.cilium.io/"
  chart      = "cilium"
  version    = local.cilium_version
  namespace  = "kube-system"

  depends_on = [
    data.talos_cluster_health.bootstrapped,
    kubectl_manifest.gateway_api_crd,
  ]

  # Cilium will not come up on Talos with stock values
  values = [yamlencode(merge(local.cilium_values, {
    # Neither pod template depends on the ConfigMap, so a values-only change
    # rewrites `cilium-config` and leaves every running pod on the config it
    # started with -- helm reports success, the plan says nothing, and the
    # feature is simply off. Hashing the values into an annotation makes the
    # template change too, so helm rolls them.
    podAnnotations = { "lab/values-hash" = local.cilium_values_hash }
    operator = merge(local.cilium_values.operator, {
      podAnnotations = { "lab/values-hash" = local.cilium_values_hash }
    })
  }))]
}

locals {
  cilium_values_hash = sha256(jsonencode(local.cilium_values))

  cilium_values = {
    # Talos mounts the cgroup2 filesystem itself and its root is read-only, so
    # Cilium must not try to mount it.
    cgroup = {
      autoMount = { enabled = false }
      hostRoot  = "/sys/fs/cgroup"
    }

    # No kube-proxy, so Cilium has to reach the apiserver without a Service.
    # KubePrism is Talos's local endpoint for exactly this, and using it means
    # the agent does not depend on the VIP either.
    kubeProxyReplacement = true
    k8sServiceHost       = "localhost"
    k8sServicePort       = 7445

    # Talos runs with a restricted set of capabilities; these are the ones the
    # agent and its init containers genuinely need.
    securityContext = {
      capabilities = {
        ciliumAgent      = ["CHOWN", "KILL", "NET_ADMIN", "NET_RAW", "IPC_LOCK", "SYS_ADMIN", "SYS_RESOURCE", "PERFMON", "BPF", "DAC_OVERRIDE", "FOWNER", "SETGID", "SETUID"]
        cleanCiliumState = ["NET_ADMIN", "SYS_ADMIN", "SYS_RESOURCE"]
      }
    }

    l2announcements = { enabled = true } # VIPs for LBs by answering ARP requests
    gatewayAPI      = { enabled = true } # GatewayApi for having a gateway controller

    # A single node is its own failure domain; two replicas would sit pending.
    # Raise this alongside the second control plane.
    operator = { replicas = 1 }

    ipam = { mode = "kubernetes" }
  }
}

# The pool and the announcement policy are Cilium's own CRDs, so they cannot
# exist before the release above -- and cannot be planned by
# `kubernetes_manifest`, which does API discovery at plan time. See versions.tf.
#
# `depends_on` is necessary but not sufficient: the helm release returns once
# the CRDs are created, and the apiserver takes a moment longer to serve them
# in discovery. On a first apply that gap lands exactly here, as "isn't valid
# for cluster". The provider's `apply_retry_count` covers it -- see
# providers.tf.
resource "kubectl_manifest" "cilium_lb_pool" {
  yaml_body = yamlencode({
    # v2 since Cilium 1.17; v2alpha1 is still served but deprecated and goes
    # away. The L2 policy below has no v2 yet, which is why the two differ.
    apiVersion = "cilium.io/v2"
    kind       = "CiliumLoadBalancerIPPool"
    metadata   = { name = "lab" }
    spec = {
      blocks = [{ start = local.lb_pool_start, stop = local.lb_pool_stop }]
    }
  })

  depends_on = [helm_release.cilium]
}

# Seperate pool for ingress/gateway endpoint
resource "kubectl_manifest" "cilium_ingress_pool" {
  yaml_body = yamlencode({
    apiVersion = "cilium.io/v2"
    kind       = "CiliumLoadBalancerIPPool"
    metadata   = { name = "ingress" }
    spec = {
      blocks = [{ start = local.ingress_ip, stop = local.ingress_ip }]

      # limited to where the gateway/ingress controller is deployed to
      serviceSelector = {
        matchLabels = {
          "io.kubernetes.service.namespace" = local.ingress_gateway_namespace
          "io.kubernetes.service.name"      = local.ingress_gateway_service
        }
      }
    }
  })

  depends_on = [helm_release.cilium]
}

resource "kubectl_manifest" "cilium_l2_policy" {
  yaml_body = yamlencode({
    apiVersion = "cilium.io/v2alpha1"
    kind       = "CiliumL2AnnouncementPolicy"
    metadata   = { name = "lab" }
    spec = {
      # Every node, and only LoadBalancer addresses -- announcing node IPs
      # would fight with the addresses the guests layer already assigned.
      loadBalancerIPs = true
      externalIPs     = false
      interfaces      = ["^eth[0-9]+"]
    }
  })

  depends_on = [helm_release.cilium]
}
