# Everything else this layer needs is a local -- see nodes.tf. Secrets come
# from the ansible vault, exported by scripts/tofu.sh.

variable "lab_domain" {
  description = "Domain holding infrastructure records -- hosts and VMs"
  type        = string
}

variable "terraform_state_passphrase" {
  description = "Passphrase for this layer's encrypted, committed state"
  type        = string
  sensitive   = true
}
