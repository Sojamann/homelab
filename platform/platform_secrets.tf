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

# Issued by Pocket ID when the client is registered by hand, so it arrives
# through `secrets/vault.yml`. Losing it costs a re-registration, not access:
# the admin above still logs in.
resource "vault_kv_secret_v2" "grafana_oidc" {
  mount = vault_mount.kv.path
  name  = "monitoring/grafana-oidc"

  delete_all_versions = true

  data_json = jsonencode({
    client-id     = var.grafana_oidc_client_id
    client-secret = var.grafana_oidc_client_secret
  })
}

####################################
#           OAUTH2-PROXY           #
####################################

# 32 characters: oauth2-proxy wants a 16, 24 or 32 byte AES key. Rotating it
# logs everyone out of VMUI, VictoriaLogs and Alertmanager, nothing more.
resource "random_password" "oauth2_proxy_cookie" {
  length  = 32
  special = false
}

# The client is issued by Pocket ID when registered by hand, so it arrives
# through `secrets/vault.yml`. Lost, the three UIs are a port-forward away.
resource "vault_kv_secret_v2" "oauth2_proxy" {
  mount = vault_mount.kv.path
  name  = "monitoring/oauth2-proxy"

  delete_all_versions = true

  data_json = jsonencode({
    client-id     = var.oauth2_proxy_oidc_client_id
    client-secret = var.oauth2_proxy_oidc_client_secret
    cookie-secret = random_password.oauth2_proxy_cookie.result
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
    # the pings stop -- a dead VictoriaMetrics, a dead cluster, a dead WAN --
    # whoever hosts this URL is what notices, from outside the lab. Which
    # service that is, this repo does not need to know.
    heartbeat-url = var.heartbeat_url
  })
}

####################################
#              GARAGE              #
####################################

# Garage runs on the NAS, so its token is generated there and arrives through
# `secrets/vault.yml`. VMAgent reads it from here.
resource "vault_kv_secret_v2" "garage_metrics" {
  mount = vault_mount.kv.path
  name  = "monitoring/garage"

  delete_all_versions = true

  data_json = jsonencode({
    metrics-token = var.garage_metrics_token
  })
}

####################################
#            KASSENBUCH            #
####################################

# Only the hash: the app never needs the plaintext, and this repo never holds
# it. Read as env, so a change takes effect on the next pod restart.
resource "vault_kv_secret_v2" "kassenbuch" {
  mount = vault_mount.kv.path
  name  = "kassenbuch/app"

  delete_all_versions = true

  data_json = jsonencode({
    password-hash = var.kassenbuch_password_hash
  })
}

####################################
#            POCKET ID             #
####################################

# Encrypts the token signing keys in Pocket ID's database. Unlike the others,
# losing this loses data: the state is its only backup.
resource "random_password" "pocket_id_encryption_key" {
  length  = 48
  special = false
}

resource "vault_kv_secret_v2" "pocket_id" {
  mount = vault_mount.kv.path
  name  = "pocket-id/app"

  delete_all_versions = true

  data_json = jsonencode({
    encryption-key = random_password.pocket_id_encryption_key.result
  })
}

####################################
#           VAULTWARDEN            #
####################################

# Only the /admin token's hash, as for Kassenbuch: the plaintext lives offline.
resource "vault_kv_secret_v2" "vaultwarden" {
  mount = vault_mount.kv.path
  name  = "vaultwarden/app"

  delete_all_versions = true

  data_json = jsonencode({
    admin-token = var.vaultwarden_admin_token_hash
  })
}

####################################
#              MEMOS               #
####################################

# The admin is break-glass only -- everyone else signs in through Pocket ID.
# Read the password with
# `kubectl -n memos get secret memos -o jsonpath='{.data.ADMIN_PASSWORD}' | base64 -d`.
resource "random_password" "memos_admin" {
  length  = 32
  special = false
}

resource "vault_kv_secret_v2" "memos" {
  mount = vault_mount.kv.path
  name  = "memos/app"

  delete_all_versions = true

  data_json = jsonencode({
    admin-password     = random_password.memos_admin.result
    oidc-client-id     = var.memos_oidc_client_id
    oidc-client-secret = var.memos_oidc_client_secret
  })
}

####################################
#              MEALIE              #
####################################

# No admin here: Mealie seeds its own, deleted at first deploy -- see the
# workload page.
resource "vault_kv_secret_v2" "mealie" {
  mount = vault_mount.kv.path
  name  = "mealie/app"

  delete_all_versions = true

  data_json = jsonencode({
    oidc-client-id     = var.mealie_oidc_client_id
    oidc-client-secret = var.mealie_oidc_client_secret
  })
}

####################################
#            NEXTCLOUD             #
####################################

# The admin is break-glass only (`/login?direct=1`) -- everyone else signs in
# through Pocket ID. Used at install; afterwards it lives in Nextcloud's db.
resource "random_password" "nextcloud_admin" {
  length  = 32
  special = false
}

resource "vault_kv_secret_v2" "nextcloud" {
  mount = vault_mount.kv.path
  name  = "nextcloud/app"

  delete_all_versions = true

  data_json = jsonencode({
    admin-password     = random_password.nextcloud_admin.result
    oidc-client-id     = var.nextcloud_oidc_client_id
    oidc-client-secret = var.nextcloud_oidc_client_secret
  })
}

####################################
#              IMMICH              #
####################################

# Rendered into Immich's config file by the immich-config ExternalSecret.
resource "vault_kv_secret_v2" "immich" {
  mount = vault_mount.kv.path
  name  = "immich/app"

  delete_all_versions = true

  data_json = jsonencode({
    oidc-client-id     = var.immich_oidc_client_id
    oidc-client-secret = var.immich_oidc_client_secret
  })
}

####################################
#            TAILSCALE             #
####################################

# The operator's OAuth client, not the network layer's: this one may only mint
# keys for `tag:k8s-operator` and the proxies under it. Issued in the tailscale
# console, so it arrives through `secrets/vault.yml`.
resource "vault_kv_secret_v2" "tailscale_operator" {
  mount = vault_mount.kv.path
  name  = "tailscale/operator"

  delete_all_versions = true

  data_json = jsonencode({
    client-id     = var.tailscale_operator_client_id
    client-secret = var.tailscale_operator_client_secret
  })
}

####################################
#               DHS                #
####################################

# The backup role on the DHS box's postgres, created there by hand -- see
# flux/docs/dhs.md. Read-only; the cluster dumps through the tailnet.
resource "vault_kv_secret_v2" "dhs_backup" {
  mount = vault_mount.kv.path
  name  = "dhs/backup"

  delete_all_versions = true

  data_json = jsonencode({
    user     = var.dhs_backup_user
    password = var.dhs_backup_password
  })
}

####################################
#               ZOT                #
####################################

resource "random_password" "zot_push" {
  length  = 32
  special = false
}

# `bcrypt_hash` rather than `bcrypt()`: the function re-salts on every plan
# and would never settle. The plaintext is for `docker login`; zot only reads
# the htpasswd line, and re-reads it on restart.
resource "vault_kv_secret_v2" "zot" {
  mount = vault_mount.kv.path
  name  = "zot/registry"

  delete_all_versions = true

  data_json = jsonencode({
    username = "push"
    password = random_password.zot_push.result
    htpasswd = "push:${random_password.zot_push.bcrypt_hash}"
  })
}
