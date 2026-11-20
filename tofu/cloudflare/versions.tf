terraform {
  required_version = ">= 1.9"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.29"
    }
  }

  # State in S3, in the personal AWS account (profile `default`), the way
  # the Spike repos keep theirs: one versioned bucket, the object encrypted
  # client-side with the passphrase before upload, so the bucket holds
  # ciphertext. The bucket is created once by hand (README, "Cloudflare").
  backend "s3" {
    bucket       = "angloyna-homelab-tofu-state"
    key          = "cloudflare/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
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
