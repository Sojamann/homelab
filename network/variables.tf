# Everything else this layer needs is a local, in the file that uses it.
# lab_domain and the secrets are exported by scripts/tofu.sh from the vault.

variable "terraform_state_passphrase" {
  description = "Passphrase the state is encrypted with"
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.terraform_state_passphrase) >= 16
    error_message = "pbkdf2 requires at least 16 characters."
  }
}

variable "lab_domain" {
  description = "Domain holding infrastructure records"
  type        = string
}

variable "app_domain" {
  description = "Domain holding hosted services -- a single wildcard record"
  type        = string
}

variable "wifi_trusted_ssid" {
  description = "Name of the trusted SSID"
  type        = string
}

variable "wifi_iot_ssid" {
  description = "Name of the IoT SSID"
  type        = string
}

variable "wifi_trusted_passphrase" {
  description = "PSK for the trusted SSID"
  type        = string
  sensitive   = true
}

variable "wifi_iot_passphrase" {
  description = "PSK for the IoT SSID"
  type        = string
  sensitive   = true
}
