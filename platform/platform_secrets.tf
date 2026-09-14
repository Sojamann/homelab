# The values behind the apps repo's `ExternalSecret`s.

####################################
#         PAPERLESS NGX            #
####################################

# The database is not here: CNPG generates its own credentials into
# `paperless-db-app` in the namespace, and paperless reads that Secret directly.
resource "random_password" "paperless_secret_key" {
  length = 64

  # Django signs sessions and password-reset tokens with this. Alphanumeric at
  # 64 characters is ~380 bits, far past anything the symbols would add, and it
  # survives every quoting layer between here and the container's environment.
  special = false
}

resource "random_password" "paperless_admin" {
  length  = 32
  special = false
}

resource "vault_kv_secret_v2" "paperless" {
  mount = vault_mount.kv.path
  name  = "paperless/paperless"

  # kv-v2 deletes are soft by default: the data goes, the path and its version
  # history stay, and `bao kv list` keeps showing a secret that holds nothing.
  # Destroy should mean destroy.
  delete_all_versions = true

  data_json = jsonencode({
    # Rotating this logs everyone out. It does not touch stored documents.
    secret-key = random_password.paperless_secret_key.result

    # Read once, at first login:
    #   bao kv get -field=admin-password kv/paperless/paperless
    # paperless only consults it while creating the superuser on an empty
    # database. Changing it afterwards changes nothing -- the password lives in
    # Postgres from then on, and is changed in the UI.
    admin-password = random_password.paperless_admin.result
  })
}

####################################
#            GRAFANA               #
####################################

resource "random_password" "grafana_admin" {
  length  = 32
  special = false
}

resource "vault_kv_secret_v2" "grafana" {
  mount = vault_mount.kv.path
  name  = "monitoring/grafana"

  delete_all_versions = true

  # Grafana is stateless (no PVC), so unlike paperless the admin is re-read
  # from here on every start -- rotating it takes effect on the next restart.
  data_json = jsonencode({
    admin-user     = "admin"
    admin-password = random_password.grafana_admin.result
  })
}
