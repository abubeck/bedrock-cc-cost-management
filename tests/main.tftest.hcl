mock_provider "aws" {
  alias = "default"
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
}

run "plan_module" {
  command = plan

  assert {
    condition     = length(var.users) == 1
    error_message = "Should have exactly 1 user."
  }
}
