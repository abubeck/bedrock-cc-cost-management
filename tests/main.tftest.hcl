mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

variables {
  users = {
    "alice" = {
      team          = "engineering"
      cost_center   = "123"
      daily_usd_cap = 5.0
      models        = ["sonnet"]
      notify_email  = "alice@example.com"
      cache_ttl     = "5m"
    }
  }

  model_catalog = {
    sonnet = {
      source_arn = "arn:aws:bedrock:eu-west-1:111122223333:inference-profile/eu.anthropic.claude-sonnet-4-5-20250929-v1:0"
    }
  }
}

run "plan_module" {
  command = plan

  assert {
    condition     = length(var.users) == 1
    error_message = "Should have exactly 1 user."
  }
}
