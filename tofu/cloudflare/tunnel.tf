# The tunnel exists already and its token is the hand-created Secret the
# cluster runs cloudflared with (README, "Cloudflare tunnel"); it is
# imported, not created, so that token stays valid. config_src stays
# "cloudflare": the ingress rules below are what the dashboard used to hold.
resource "cloudflare_zero_trust_tunnel_cloudflared" "cluster" {
  account_id = var.account_id
  name       = var.tunnel_name
  config_src = "cloudflare"

  lifecycle {
    # Never recreate: a new tunnel means a new token in the cluster.
    prevent_destroy = true
    ignore_changes  = [tunnel_secret]
  }
}

# The public hostnames, plus the catch-all every tunnel config must end
# with. Until 2026-11 these two rules were set by hand in Zero Trust.
resource "cloudflare_zero_trust_tunnel_cloudflared_config" "cluster" {
  account_id = var.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.cluster.id

  config = {
    ingress = concat(
      [for h in var.public_hostnames : {
        hostname       = h.hostname
        service        = h.service
        origin_request = {} # as the API reports it; absent would diff forever
      }],
      [{ service = "http_status:404" }],
    )
  }
}

# The private network: the cluster's Service CIDR, reachable by enrolled
# WARP devices through the cloudflared pods, which sit inside it. What the
# ClusterIP-only personal apps are reached through (README, "Private
# network"). Created by hand on 2026-11-20 and imported.
resource "cloudflare_zero_trust_tunnel_cloudflared_route" "cluster_services" {
  account_id = var.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.cluster.id
  network    = var.cluster_service_cidr
  comment    = "k3s Service CIDR (ClusterIPs); CoreDNS at ${var.cluster_dns}"
}
