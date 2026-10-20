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

variable "telegram_bot_token" {
  description = "Telegram bot Alertmanager posts alerts as"
  type        = string
  sensitive   = true
}

variable "telegram_chat_id" {
  description = "Telegram group the bot posts into -- negative for a group"
  type        = string
}

variable "heartbeat_url" {
  description = "Heartbeat URL the `Watchdog` alert pings -- whoever hosts it"
  type        = string
  sensitive   = true
}

variable "kassenbuch_password_hash" {
  description = "Kassenbuch login, base64 argon2id hash from scripts/hash-password.js"
  type        = string
  sensitive   = true
}

variable "vaultwarden_admin_token_hash" {
  description = "Vaultwarden /admin token, argon2id PHC string from `vaultwarden hash`"
  type        = string
  sensitive   = true
}

variable "garage_metrics_token" {
  description = "Bearer token for Garage's /metrics on the NAS"
  type        = string
  sensitive   = true
}

variable "volsync_restic_password" {
  description = "restic password for every VolSync repository in Garage"
  type        = string
  sensitive   = true
}

variable "garage_volsync_key_id" {
  description = "Garage key id on the k8s-backups bucket"
  type        = string
  sensitive   = true
}

variable "garage_volsync_secret_key" {
  description = "Garage secret key on the k8s-backups bucket"
  type        = string
  sensitive   = true
}

variable "grafana_oidc_client_id" {
  description = "Grafana's client id in Pocket ID"
  type        = string
}

variable "grafana_oidc_client_secret" {
  description = "Grafana's client secret in Pocket ID -- shown once, at registration"
  type        = string
  sensitive   = true
}

variable "bao_oidc_client_id" {
  description = "OpenBao's client id in Pocket ID"
  type        = string
}

variable "bao_oidc_client_secret" {
  description = "OpenBao's client secret in Pocket ID -- shown once, at registration"
  type        = string
  sensitive   = true
}
