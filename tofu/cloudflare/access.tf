# Who may enroll a device, and which device may then reach the private
# network. Two gates, on purpose: enrollment admits any device the login
# can sign in from; the posture rule below is what makes it one machine.

# Device enrollment permissions are an Access application of type "warp"
# with a policy. One policy, one email, decision allow.
resource "cloudflare_zero_trust_access_policy" "enroll" {
  account_id = var.account_id
  name       = "enroll: ${var.login_email}"
  decision   = "allow"

  include = [{
    email = { email = var.login_email }
  }]
}

resource "cloudflare_zero_trust_access_application" "warp_enrollment" {
  account_id = var.account_id
  type       = "warp"
  name       = "Warp Login App"

  policies = [{
    id         = cloudflare_zero_trust_access_policy.enroll.id
    precedence = 1
  }]
}

# The machines: a serial-number list and the posture rule that checks a
# device against it. WARP reports the serial; nothing to install.
resource "cloudflare_zero_trust_list" "device_serials" {
  account_id  = var.account_id
  name        = "personal devices"
  type        = "SERIAL"
  description = "Serial numbers allowed onto the cluster's private network"

  items = [for s in var.device_serial_numbers : { value = s }]
}

resource "cloudflare_zero_trust_device_posture_rule" "known_device" {
  account_id  = var.account_id
  name        = "known device (serial number)"
  type        = "serial_number"
  description = "The laptop is on the personal devices list"
  schedule    = "5m"

  input = {
    id = cloudflare_zero_trust_list.device_serials.id
  }

  match = [{ platform = "mac" }]
}

# Gateway network policies, lowest precedence first: the one login on a
# known device may reach the Service CIDR; everyone else enrolled is
# blocked from it. Nothing outside the CIDR passes through WARP anyway
# (include-mode split tunnel), so these are the whole policy.
resource "cloudflare_zero_trust_gateway_policy" "cluster_allow" {
  account_id  = var.account_id
  name        = "cluster: allow ${var.login_email} on a known device"
  description = "The private network, for the one login on a listed machine"
  enabled     = true
  precedence  = 1000
  action      = "allow"
  filters     = ["l4"]

  traffic        = "net.dst.ip in {${var.cluster_service_cidr}}"
  identity       = "identity.email == \"${var.login_email}\""
  device_posture = "any(device_posture.checks.passed[*] in {\"${cloudflare_zero_trust_device_posture_rule.known_device.id}\"})"
}

resource "cloudflare_zero_trust_gateway_policy" "cluster_block" {
  account_id  = var.account_id
  name        = "cluster: block everyone else"
  description = "Anything reaching the Service CIDR that the allow above did not match"
  enabled     = true
  precedence  = 2000
  action      = "block"
  filters     = ["l4"]

  traffic = "net.dst.ip in {${var.cluster_service_cidr}}"
}
