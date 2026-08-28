provider "unifi" {
  api_url = "https://10.212.1.1"

  # UNIFI_API_KEY, exported by scripts/tofu.sh from the ansible vault. Create
  # it under *Control Plane -> Admins & Users*, on a limited admin with local
  # access only -- it is shown exactly once. Username/password also works but
  # cannot coexist with 2FA.

  # The controller's certificate is self-signed.
  allow_insecure = true
}
