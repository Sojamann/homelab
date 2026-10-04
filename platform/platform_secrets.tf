# The values behind the apps repo's `ExternalSecret`s.

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

  # Grafana is stateless (no PVC), so the admin is re-read from here on every
  # start -- rotating it takes effect on the next restart.
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

####################################
#            KASSENBUCH            #
####################################

# Only the hash: the app never needs the plaintext, and this repo never holds
# it. The Verein's name rides along to keep it out of the public apps repo.
# Both read as env, so a change takes effect on the next pod restart.
resource "vault_kv_secret_v2" "kassenbuch" {
  mount = vault_mount.kv.path
  name  = "kassenbuch/app"

  delete_all_versions = true

  data_json = jsonencode({
    password-hash    = var.kassenbuch_password_hash
    association-name = var.kassenbuch_association_name
  })
}
