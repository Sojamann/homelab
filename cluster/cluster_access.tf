# Both files land in secrets/ at 0600 and are gitignored, the same way the
# guests layer writes its SSH key. Nothing is merged into ~/.kube/config

resource "talos_cluster_kubeconfig" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration

  node     = local.bootstrap_node.endpoint
  endpoint = local.bootstrap_node.endpoint

  depends_on = [talos_machine_bootstrap.this]
}

resource "local_sensitive_file" "talosconfig" {
  filename        = local.talosconfig_path
  content         = data.talos_client_configuration.this.talos_config
  file_permission = "0600"
}

resource "local_sensitive_file" "kubeconfig" {
  filename        = local.kubeconfig_path
  content         = talos_cluster_kubeconfig.this.kubeconfig_raw
  file_permission = "0600"
}

# Two health checks, and they are not the same check.
#
# This one runs *before* Cilium and skips the Kubernetes-level ones. Bootstrap
# returns as soon as etcd is told to start, not when the apiserver is serving,
# and the VIP only comes alive once etcd is healthy -- so without this the helm
# release dials the endpoint seconds too early and fails with "connection
# refused". What it cannot wait for is nodes going Ready: with `cni: none` that
# does not happen until Cilium is in, which is the thing downstream of here.
data "talos_cluster_health" "bootstrapped" {
  client_configuration = talos_machine_secrets.this.client_configuration

  # Addresses, not endpoints: these two are parsed as IPs, and a name here
  # fails the plan outright. `endpoints` is dialed rather than parsed, so it
  # stays on the DNS records like everything else in this layer.
  control_plane_nodes = [for n in local.controlplanes : n.address]
  worker_nodes        = [for n in local.workers : n.address]
  endpoints           = [for n in local.controlplanes : n.endpoint]

  skip_kubernetes_checks = true

  depends_on = [talos_machine_bootstrap.this]
}

# And this one runs after Cilium, where the full check can finally pass.
data "talos_cluster_health" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration

  control_plane_nodes = [for n in local.controlplanes : n.address]
  worker_nodes        = [for n in local.workers : n.address]
  endpoints           = [for n in local.controlplanes : n.endpoint]

  depends_on = [helm_release.cilium]
}

output "cluster" {
  description = "How to reach the cluster"
  value = {
    name     = local.cluster_name
    endpoint = local.cluster_endpoint
    vip      = local.cluster_vip
    nodes    = { for name, n in local.talos_nodes : name => "${n.machine} ${n.address}" }

    talosctl = "talosctl --talosconfig secrets/talosconfig -n ${local.bootstrap_node.endpoint}"
    kubectl  = "KUBECONFIG=secrets/kubeconfig kubectl get nodes"
  }
}

# For comparing against the guests layer's `talos_schematic_id`. The two
# extension lists are duplicated on purpose; this is how you check they still
# agree.
output "talos_schematic_id" {
  description = "Image factory schematic this layer upgrades onto -- must match the guests layer"
  value       = talos_image_factory_schematic.this.id
}
