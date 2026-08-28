# The node set is discovered.

locals {
  proxmox_endpoint = "https://titan.${var.lab_domain}:8006/"

  # k8s cluster is named like the proxmox cluster
  cluster_name = "lab"

  # The Kubernetes endpoint. It goes into every machineconfig and into the
  # apiserver's certificate, so changing it later means regenerating configs and rolling certs.
  cluster_vip      = "10.212.4.5"
  cluster_fqdn     = "k8s.${var.lab_domain}"
  cluster_endpoint = "https://k8s.${var.lab_domain}:6443"

  talos_version      = "v1.13.10"
  kubernetes_version = "1.36.3"

  # KEEP IN SYNC WITH guests/ to match the extensions we have installed initially. Without this list
  # an talos upgrade would install a plain talos without any extensions.
  talos_extensions = [
    "siderolabs/intel-ucode",
    "siderolabs/qemu-guest-agent",
    "siderolabs/nvme-cli",
    "siderolabs/util-linux-tools",
  ]

  # Explicit listing of talos defaults for transparancy sake
  pod_subnet     = "10.244.0.0/16"
  service_subnet = "10.96.0.0/12"
}

data "proxmox_virtual_environment_vms" "controlplanes" {
  tags = ["talos", "talos-controlplane"]
}

data "proxmox_virtual_environment_vms" "workers" {
  tags = ["talos", "talos-worker"]
}

locals {
  # The data source returns name, vm_id, node_name, status and tags -- and no
  # address. Both of the things this layer needs are derived from what it does
  # return:
  #
  #   endpoint -- the guest's own DNS record, written by the guests layer in
  #     the same file as the guest. No arithmetic, and it stays right if the
  #     addressing convention ever changes.
  #
  #   address -- from the vm id, which encodes it. The guests layer numbers a
  #     Talos VM `<third octet><host octet>`, so `4010` is `10.212.4.10`. The
  #     machineconfig needs a literal address for the interface, and deriving
  #     it here means the address is stated once, in the guests layer, rather
  #     than in two layers that can drift.
  talos_nodes = {
    for vm in concat(
      data.proxmox_virtual_environment_vms.controlplanes.vms,
      data.proxmox_virtual_environment_vms.workers.vms,
      ) : vm.name => {
      vm_id        = vm.vm_id
      machine      = contains(vm.tags, "talos-controlplane") ? "controlplane" : "worker"
      endpoint     = "${vm.name}.${var.lab_domain}"
      address      = "10.212.${floor(vm.vm_id / 1000)}.${vm.vm_id % 1000}"
      proxmox_node = vm.node_name
    }
  }

  controlplanes = { for name, n in local.talos_nodes : name => n if n.machine == "controlplane" }
  workers       = { for name, n in local.talos_nodes : name => n if n.machine == "worker" }

  # etcd is bootstrapped exactly once, on one node.
  #
  # The placeholder is for the case this layer is applied before the guests
  # layer has built anything: discovery then returns nothing, and indexing an
  # empty map fails with "Invalid index", which says nothing about what is
  # actually wrong. The precondition on `talos_machine_bootstrap` catches it
  # first and says it.
  controlplane_names = sort(keys(local.controlplanes))
  bootstrap_node = length(local.controlplane_names) > 0 ? local.controlplanes[local.controlplane_names[0]] : {
    vm_id        = 0
    machine      = "controlplane"
    endpoint     = "no-controlplane-found"
    address      = "0.0.0.0"
    proxmox_node = ""
  }

  # Written by this layer for talosctl and kubectl, and read back by the helm
  # and kubectl providers -- which need a path that is constant at plan time.
  talosconfig_path = "${path.module}/../secrets/talosconfig"
  kubeconfig_path  = "${path.module}/../secrets/kubeconfig"
}
