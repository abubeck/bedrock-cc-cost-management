###############################################################################
# example/main.tf
#
# Example: two users, each with individual cost tracking (via per-user
# Application Inference Profiles) and an individual daily USD spend cap that
# resets every day at midnight UTC. Region: Ireland (eu-west-1).
#
# User keys must match the SSO role session name for each principal.
# Replace 111122223333 with your AWS account ID before applying.
###############################################################################

provider "aws" {
  region = "eu-west-1"
}

module "claude_code_quota" {
  source = "../" # path to the module

  users = {
    # Keys must match SSO session names — see README for details.
    "alice@example.com" = {
      team          = "Platform"
      cost_center   = "CC-1042"
      daily_usd_cap = 20.0
      models        = ["sonnet", "haiku"]
      notify_email  = "alice@example.com"
    }
    "bob@example.com" = {
      team          = "Data"
      cost_center   = "CC-2080"
      daily_usd_cap = 10.0
      models        = ["sonnet", "opus", "haiku"]
      notify_email  = "bob@example.com"
    }
  }

  # Optional: copy an admin on every quota notification.
  admin_notification_email = "admin@example.com"

  # Point these at YOUR account's enabled model versions in eu-west-1.
  # Replace 111122223333 with your AWS account ID.
  model_catalog = {
    sonnet = {
      source_arn = "arn:aws:bedrock:eu-west-1:111122223333:inference-profile/eu.anthropic.claude-sonnet-4-6"
    }
    opus = {
      source_arn = "arn:aws:bedrock:eu-west-1:111122223333:inference-profile/eu.anthropic.claude-opus-4-7"
    }
    haiku = {
      source_arn = "arn:aws:bedrock:eu-west-1:111122223333:inference-profile/eu.anthropic.claude-haiku-4-5-20251001-v1:0"
    }
  }
  price_per_1k_tokens = {
    sonnet = { input = 0.003, output = 0.015, cache_read = 0.0003, cache_write_5m = 0.00375, cache_write_1h = 0.006 }
    opus   = { input = 0.005, output = 0.025, cache_read = 0.0005, cache_write_5m = 0.00625, cache_write_1h = 0.01 }
    haiku  = { input = 0.001, output = 0.005, cache_read = 0.0001, cache_write_5m = 0.00125, cache_write_1h = 0.002 }
  }

  # Optional overrides:
  # enforcement_interval_minutes = 15
  # reset_hour_utc               = 0
  # log_retention_days           = 30

  tags = {
    Project = "claude-code"
  }
}

output "claude_code_env_per_user" {
  value = module.claude_code_quota.claude_code_env_per_user
}

output "next_steps" {
  value = module.claude_code_quota.next_steps
}

output "permission_set_policy_json" {
  value = module.claude_code_quota.permission_set_policy_json
}
