# One key for the whole layer. Cloud-init authorises the public half on every guest.

resource "tls_private_key" "guests" {
  algorithm = "ED25519"

  # we need it for accessing all machines altough guest-config might add more keys later.
  lifecycle {
    prevent_destroy = true
  }
}

resource "local_sensitive_file" "guests_ssh_key" {
  filename        = "${path.module}/../secrets/guests-ssh-key"
  content         = tls_private_key.guests.private_key_openssh
  file_permission = "0600"
}
