variable "lab_domain" {
  description = "Domain holding infrastructure records -- hosts and VMs"
  type        = string
}

variable "app_domain" {
  description = "Domain holding hosted services -- what the gateway serves"
  type        = string
}

variable "acme_email" {
  description = "Let's Encrypt account contact -- shared with Proxmox's own ACME"
  type        = string
}

variable "cloudflare_api_token" {
  description = "Zone DNS:Edit + Zone:Read, for cert-manager's DNS-01 solver"
  type        = string
  sensitive   = true
}

variable "terraform_state_passphrase" {
  description = "Passphrase for this layer's encrypted, committed state"
  type        = string
  sensitive   = true
}

variable "truenas_api_key" {
  description = "TrueNAS API key for the democratic-csi user -- see machines/truenas.md"
  type        = string
  sensitive   = true
}
