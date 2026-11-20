terraform {
  required_version = ">= 1.9"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.29"
    }
  }

  # State in the cluster this configures: a Secret in the tofu-state
  # namespace, written through the kubeconfig in use. No extra credential
  # and nothing to create first beyond the namespace (README). Encrypted
  # client-side with the passphrase before it is written, like the Spike
  # repos' S3 state, so the Secret holds ciphertext.
  backend "kubernetes" {
    secret_suffix = "cloudflare"
    namespace     = "tofu-state"
  }

  encryption {
    key_provider "pbkdf2" "state" {
      passphrase = var.state_passphrase
    }

    method "aes_gcm" "state" {
      keys = key_provider.pbkdf2.state
    }

    state {
      method   = method.aes_gcm.state
      enforced = true
    }

    plan {
      method   = method.aes_gcm.state
      enforced = true
    }
  }
}

# Reads CLOUDFLARE_API_TOKEN from the environment (README, "Cloudflare").
provider "cloudflare" {}
