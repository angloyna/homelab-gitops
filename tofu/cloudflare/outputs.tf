output "tunnel_id" {
  value = cloudflare_zero_trust_tunnel_cloudflared.cluster.id
}

output "cluster_route_id" {
  description = "The CIDR route's id, for `tofu import` on a rebuilt state."
  value       = cloudflare_zero_trust_tunnel_cloudflared_route.cluster_services.id
}

output "posture_rule_id" {
  description = "Referenced by the Gateway allow policy's device_posture expression."
  value       = cloudflare_zero_trust_device_posture_rule.known_device.id
}
