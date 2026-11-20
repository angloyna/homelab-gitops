# What existed before this module: the tunnel, its dashboard-set ingress,
# the CIDR route added by hand on 2026-11-20, the account's default WARP
# profile and its fallback list, and the WARP enrollment application
# Zero Trust creates when enrollment is first configured. Once in state
# these blocks are no-ops. The ids come from the dashboard (README,
# "Cloudflare"); the two left as variables differ per account.
import {
  to = cloudflare_zero_trust_tunnel_cloudflared.cluster
  id = "${var.account_id}/${var.tunnel_id}"
}

import {
  to = cloudflare_zero_trust_tunnel_cloudflared_config.cluster
  id = "${var.account_id}/${var.tunnel_id}"
}

import {
  to = cloudflare_zero_trust_device_default_profile.default
  id = var.account_id
}

import {
  to = cloudflare_zero_trust_device_default_profile_local_domain_fallback.default
  id = var.account_id
}
