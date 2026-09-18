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

####################################
#             ALERTING             #
####################################

# The first secret here the repo consumes rather than produces: both values are
# issued by someone else and arrive through `secrets/vault.yml`. Nothing to
# generate, so no `random_password` above it.
#
# Both land in one secret because one consumer reads both: Alertmanager mounts
# it and points `bot_token_file` and `url_file` at the two files. The chat id is
# not here -- it is no credential, and travels in `cluster-vars` instead.
resource "vault_kv_secret_v2" "alerting" {
  mount = vault_mount.kv.path
  name  = "monitoring/alerting"

  delete_all_versions = true

  data_json = jsonencode({
    telegram-bot-token = var.telegram_bot_token

    # Pinged by the permanently-firing `Watchdog` alert every 5 minutes. When
    # the pings stop -- a dead Prometheus, a dead cluster, a dead WAN --
    # whoever hosts this URL is what notices, from outside the lab. Which
    # service that is, this repo does not need to know.
    heartbeat-url = var.heartbeat_url
  })
}
