# The two SSIDs already on the controller, adopted rather than redesigned.
# Crypto settings are transcribed from what is running: a rename or a cipher
# change makes every client re-associate, and for the IoT SSID a chunk of them
# would not come back.
#
# The names come from the vault, not from here. Not because an SSID is a
# credential -- it is broadcast in the clear to anyone in range -- but because
# wardriving databases index SSIDs against coordinates, so a name in a public
# repo ties this whole topology to a street address. The PSKs below are secret;
# these are merely locating.

data "unifi_user_group" "default" {}

# Which access points broadcast the SSID. Not setting it un-broadcasts the
# network from every AP, which looks exactly like the wifi being down.
data "unifi_ap_group" "default" {}

resource "unifi_wlan" "trusted" {
  name       = var.wifi_trusted_ssid
  network_id = unifi_network.this["Trusted"].id

  security   = "wpapsk"
  passphrase = var.wifi_trusted_passphrase

  # WPA3 where the client can, WPA2 where it cannot. 6GHz requires WPA3, so
  # dropping transition mode here would also drop the 6GHz band below.
  wpa3_support    = true
  wpa3_transition = true
  pmf_mode        = "optional"

  wlan_bands = ["2g", "5g", "6g"]

  user_group_id = data.unifi_user_group.default.id
  ap_group_ids  = [data.unifi_ap_group.default.id]
}

resource "unifi_wlan" "iot" {
  name       = var.wifi_iot_ssid
  network_id = unifi_network.this["IoT"].id

  security   = "wpapsk"
  passphrase = var.wifi_iot_passphrase

  # Transition mode, same as Trusted. IoT devices with elderly wifi stacks tend
  # to fail association rather than fall back, so this is worth re-testing
  # before it is tightened -- the isolation here comes from the VLAN, not the
  # cipher.
  wpa3_support    = true
  wpa3_transition = true
  pmf_mode        = "optional"

  # 2.4GHz only. Most of this population has no 5GHz radio, and an SSID on both
  # bands makes them roam to a band they cannot hold.
  wlan_bands = ["2g"]

  user_group_id = data.unifi_user_group.default.id
  ap_group_ids  = [data.unifi_ap_group.default.id]
}
