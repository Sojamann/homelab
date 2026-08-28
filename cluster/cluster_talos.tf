# The cluster's identity and every node's configuration.
#
# `talos_machine_secrets` is the whole reason this layer's state is committed
# and encrypted -- see versions.tf. It is generated once and never again;
# `prevent_destroy` is there because a `tofu destroy` that takes it with it is
# not recoverable by re-running anything.

resource "talos_machine_secrets" "this" {
  talos_version = local.talos_version

  lifecycle {
    prevent_destroy = true
  }
}

data "talos_client_configuration" "this" {
  cluster_name         = local.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration

  # The VIP is not up until etcd has elected a holder, so talosctl is pointed
  # at the nodes themselves. That is also what you want when something is
  # wrong: the Talos API is how you fix a cluster whose Kubernetes endpoint is
  # not answering.
  endpoints = [for n in local.talos_nodes : n.endpoint]
  nodes     = [for n in local.talos_nodes : n.endpoint]
}

locals {
  # Applied to every node regardless of role.
  common_patch = yamlencode({
    machine = {
      # The Talos API cert, not the Kubernetes one (that is cluster.apiServer
      # below). Without this apid's cert carries only the node's hostname, and
      # every connection in this layer -- which addresses nodes by their DNS
      # record, not their hostname -- fails the TLS verify. Every node gets
      # every node's name so the list stays the same on all of them.
      certSANs = concat(
        [local.cluster_vip],
        [for n in local.talos_nodes : n.endpoint],
        [for n in local.talos_nodes : n.address],
      )

      install = {
        # The image is already installed -- the guest booted from a disk image,
        # not an installer. This is what `talosctl upgrade` moves the node onto,
        # so it has to carry the same extensions as the image in the guests
        # layer, or an upgrade quietly drops them.
        image = "factory.talos.dev/nocloud-installer/${talos_image_factory_schematic.this.id}:${local.talos_version}"
        disk  = "/dev/sda"
      }

      # The node resolves at its own gateway. Not 10.212.2.1: that is in
      # Trusted, and the k8s deny policy would eat every query, which looks
      # like a broken node rather than a firewalled one.
      network = {
        nameservers = ["10.212.4.1"]

        # The one name the cluster cannot afford to lose. Every kubelet
        # resolves the endpoint to find the apiserver, so pinning it locally
        # means bringup does not depend on the gateway's DNS being healthy --
        # and it keeps working through the move to pihole.
        extraHostEntries = [
          {
            ip      = local.cluster_vip
            aliases = [local.cluster_fqdn, "k8s"]
          },
        ]
      }
    }

    cluster = {
      network = {
        # Cilium. Until it is installed the nodes stay NotReady and CoreDNS
        # pends -- which is why the health check in this layer runs after the
        # helm release, not before it.
        cni            = { name = "none" }
        podSubnets     = [local.pod_subnet]
        serviceSubnets = [local.service_subnet]
      }

      # Cilium replaces it, using KubePrism on localhost:7445.
      proxy = { disabled = true }
    }
  })

  # Control-plane only.
  controlplane_patch = yamlencode({
    machine = {
      # The VIP, and the reason this layer configures an interface at all.
      # Talos elects the holder through etcd, so it does not come alive until
      # after bootstrap -- and on a one-node cluster "etcd is unhealthy" and
      # "the endpoint resolves to nothing alive" are the same event. The Talos
      # API on :50000 is unaffected, which is what you use to fix that.
      #
      # The addresses are stated here as well as on the guest's cloud-init
      # drive. Two places for one fact, deliberately: once this layer has to
      # declare the interface for the VIP, having it declare half the interface
      # and inherit the rest is the more fragile arrangement.
      network = {
        interfaces = [
          {
            deviceSelector = { physical = true }
            dhcp           = false
            addresses      = ["ADDRESS/24"]
            routes         = [{ network = "0.0.0.0/0", gateway = "10.212.4.1" }]
            vip            = { ip = local.cluster_vip }
          },
        ]
      }
    }

    cluster = {
      allowSchedulingOnControlPlanes = true

      apiServer = {
        certSANs = concat(
          [local.cluster_fqdn, local.cluster_vip],
          [for n in local.talos_nodes : n.endpoint],
          [for n in local.talos_nodes : n.address],
        )
      }
    }
  })
}

# The same schematic the guests layer declares -- registering it is idempotent,
# so both layers can compute the id from the extension list rather than copying
# a hash between files.
resource "talos_image_factory_schematic" "this" {
  schematic = yamlencode({
    customization = {
      systemExtensions = {
        officialExtensions = local.talos_extensions
      }
    }
  })
}

data "talos_machine_configuration" "controlplane" {
  cluster_name       = local.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = "controlplane"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = local.talos_version
  kubernetes_version = local.kubernetes_version
}

data "talos_machine_configuration" "worker" {
  cluster_name       = local.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = "worker"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = local.talos_version
  kubernetes_version = local.kubernetes_version
}

resource "talos_machine_configuration_apply" "controlplane" {
  for_each = local.controlplanes

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controlplane.machine_configuration

  node     = each.value.endpoint
  endpoint = each.value.endpoint

  config_patches = [
    local.common_patch,
    # The node's own address is the only per-node value. Substituted rather
    # than templated into the patch above so the patch itself stays readable.
    replace(local.controlplane_patch, "ADDRESS", each.value.address),
  ]
}

resource "talos_machine_configuration_apply" "worker" {
  for_each = local.workers

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker.machine_configuration

  node     = each.value.endpoint
  endpoint = each.value.endpoint

  config_patches = [
    local.common_patch,
    yamlencode({
      machine = {
        network = {
          interfaces = [
            {
              deviceSelector = { physical = true }
              dhcp           = false
              addresses      = ["${each.value.address}/24"]
              routes         = [{ network = "0.0.0.0/0", gateway = "10.212.4.1" }]
            },
          ]
        }
      }
    }),
  ]
}

# Once, on one node. Everything else joins.
resource "talos_machine_bootstrap" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration

  node     = local.bootstrap_node.endpoint
  endpoint = local.bootstrap_node.endpoint

  depends_on = [talos_machine_configuration_apply.controlplane]

  lifecycle {
    precondition {
      condition     = length(local.controlplanes) > 0
      error_message = "No VM is tagged both `talos` and `talos-controlplane` in Proxmox. The guests layer builds the nodes this layer configures -- run `mise run guests apply` first."
    }
  }
}
