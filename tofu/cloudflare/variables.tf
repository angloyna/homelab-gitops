variable "homelab_state_passphrase" {
  description = "Encrypts state and plan files client-side. Supply as TF_VAR_homelab_state_passphrase; its own name so it never collides with the Spike repos' TF_VAR_state_passphrase in the same shell."
  type        = string
  sensitive   = true
}

variable "account_id" {
  description = "The Cloudflare account (Zero Trust team) everything here lives in. Supply as TF_VAR_account_id."
  type        = string
}

variable "tunnel_id" {
  description = "The existing tunnel the cluster's cloudflared Deployment connects (apps/cloudflared); imported, never created. Supply as TF_VAR_tunnel_id."
  type        = string
}

variable "tunnel_name" {
  description = "The tunnel's name as Zero Trust shows it; must match for the import to be a no-op."
  type        = string
}

variable "login_email" {
  description = "The one login that may enroll a device and reach the private network. Supply as TF_VAR_login_email."
  type        = string
}

variable "device_serial_numbers" {
  description = "Serial numbers of the machines allowed onto the private network; the posture rule matches on this list."
  type        = list(string)
}

variable "cluster_service_cidr" {
  description = "k3s's Service CIDR, routed through the tunnel to WARP clients."
  type        = string
  default     = "10.43.0.0/16"
}

variable "cluster_dns" {
  description = "CoreDNS's ClusterIP, the resolver WARP uses for the cluster's domain."
  type        = string
  default     = "10.43.0.10"
}

variable "cluster_domain" {
  description = "The cluster's DNS suffix, resolved through CoreDNS on enrolled devices."
  type        = string
  default     = "svc.cluster.local"
}

variable "public_hostnames" {
  description = "Public hostnames the tunnel serves, each to an origin reachable from the cloudflared pods. Order is the ingress order."
  type = list(object({
    hostname = string
    service  = string
    comment  = optional(string)
  }))
  default = [
    # Flow's two public paths: the Alloy push endpoints the Flow hosts write
    # to (flow-infrastructure, helm/monitoring) and ArgoCD's GitHub webhook
    # (flow-infrastructure, argocd-tailnet). Both Ingresses are on Traefik.
    # In the order the dashboard had them, so the import is a no-op.
    { hostname = "ingest.turdblossom.dev", service = "http://traefik.kube-system:80", comment = "Prometheus remote-write and Loki push" },
    { hostname = "hooks.turdblossom.dev", service = "http://traefik.kube-system:80", comment = "ArgoCD /api/webhook" },
  ]
}
