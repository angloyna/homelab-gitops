# The default WARP device profile: include-mode split tunnel carrying only
# the cluster's Service CIDR, so nothing else on an enrolled laptop goes
# through WARP, at home or away. Managing the default profile adopts the
# one every account has (imported by account id).
resource "cloudflare_zero_trust_device_default_profile" "default" {
  account_id = var.account_id

  include = [
    { address = var.cluster_service_cidr, description = "k3s Service CIDR, through the tunnel" },
  ]
  # A profile is in include mode or exclude mode and the provider enforces
  # it: setting `include` is the switch, and `exclude` may not appear. The
  # stock exclude list (RFC 1918 and friends) goes with the mode.

  # As the account had them on 2026-11-20 (first plan), spelled out so a
  # later dashboard edit shows as drift.
  allow_mode_switch     = false
  allow_updates         = false
  allowed_to_leave      = true
  auto_connect          = 0
  captive_portal        = 180
  disable_auto_fallback = false
  switch_locked         = false
  tunnel_protocol       = "masque"
}

# What the cluster's names resolve through on an enrolled device: CoreDNS,
# inside the routed range. The rest of the list is Cloudflare's default
# local-domain set, exactly as the account carries it; this resource
# replaces the whole list, so the defaults are restated rather than lost.
resource "cloudflare_zero_trust_device_default_profile_local_domain_fallback" "default" {
  account_id = var.account_id

  domains = concat(
    [{
      suffix      = var.cluster_domain
      dns_server  = [var.cluster_dns]
      description = "the cluster: ClusterIP Service names, via CoreDNS"
    }],
    [for d in [
      "home.arpa", "intranet", "internal", "private", "localdomain", "domain",
      "lan", "home", "host", "corp", "local", "localhost", "invalid", "test",
    ] : { suffix = d }],
  )
}
