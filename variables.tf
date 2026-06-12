###############################################################################
# variables.tf
###############################################################################

variable "users" {
  description = <<-EOT
    Map of users, keyed by their SSO session name (must match the role session
    name assigned by your Landing Zone). Each user gets their own Application
    Inference Profile(s) for cost tracking and an individual daily USD spend cap.
  EOT
  type = map(object({
    team          = string
    cost_center   = string
    daily_usd_cap = number           # max USD this user may spend per day
    models        = list(string)     # keys into var.model_catalog
    notify_email  = optional(string) # email to notify on block / reset; null disables
    cache_ttl     = optional(string, "5m") # configures expected cache behavior: "5m" or "1h"
  }))

  validation {
    condition     = alltrue([for u in var.users : u.daily_usd_cap > 0])
    error_message = "Every user's daily_usd_cap must be greater than 0."
  }

  validation {
    condition     = alltrue([for u in var.users : length(u.models) > 0])
    error_message = "Every user must be assigned at least one model."
  }
}

variable "model_catalog" {
  description = <<-EOT
    Catalog of allowed models, keyed by a short alias (e.g. "sonnet", "haiku").
    source_arn: the ARN the AIP wraps. Use a system-defined cross-region
    inference profile ARN (recommended) or a foundation-model ARN.
    Update the default ARNs to match your region, account ID, and the model
    versions you have enabled in Bedrock.
  EOT
  type = map(object({
    source_arn = string
  }))

  # Defaults target eu-west-1 (Ireland) using EU cross-region inference
  # profiles. Replace 000000000000 with your account ID, and confirm the
  # model version IDs are the ones enabled in your Bedrock account.
  default = {
    sonnet = {
      source_arn = "arn:aws:bedrock:eu-west-1:000000000000:inference-profile/eu.anthropic.claude-sonnet-4-5-20250929-v1:0"
    }
    haiku = {
      source_arn = "arn:aws:bedrock:eu-west-1:000000000000:inference-profile/eu.anthropic.claude-haiku-4-5-20251001-v1:0"
    }
  }

  validation {
    condition     = alltrue([for m in var.model_catalog : !strcontains(m.source_arn, "000000000000")])
    error_message = "model_catalog source_arn values still contain the placeholder account ID 000000000000. Replace with your real AWS account ID."
  }
}

variable "price_per_1k_tokens" {
  description = <<-EOT
    USD price per 1,000 tokens, keyed by model alias, with separate input,
    output, and prompt caching (read/write) prices. The enforcer uses these
    to convert logged token counts into a USD spend estimate.
    Keep these in sync with current Bedrock pricing.
    NOTE: this is billed-token cost, NOT the 5x quota burndown applied to
    Claude 3.7+ output tokens (that affects throttling, not your bill).
  EOT
  type = map(object({
    input          = number
    output         = number
    cache_read     = number
    cache_write_5m = number
    cache_write_1h = number
  }))

  default = {
    sonnet = { input = 0.003, output = 0.015, cache_read = 0.0003, cache_write_5m = 0.00375, cache_write_1h = 0.006 }
    haiku  = { input = 0.0008, output = 0.004, cache_read = 0.00008, cache_write_5m = 0.001, cache_write_1h = 0.0016 }
  }
}

variable "invocation_log_group_name" {
  description = "CloudWatch Log Group name for Bedrock model invocation logs."
  type        = string
  default     = "/aws/bedrock/claude-code-invocations"
}

variable "log_retention_days" {
  description = "Retention for the invocation log group (days)."
  type        = number
  default     = 30
}

variable "manage_bedrock_logging" {
  description = <<-EOT
    Whether this module should create and own the account-level Bedrock model
    invocation logging configuration. Set to false if logging is already
    configured elsewhere (Bedrock allows only ONE config per account/region);
    in that case point invocation_log_group_name at the existing log group.
  EOT
  type        = bool
  default     = true
}

variable "enforcement_interval_minutes" {
  description = <<-EOT
    How often the enforcer evaluates spend. Smaller = tighter cap but more
    Logs Insights queries (cost). This is also the maximum overshoot window.
  EOT
  type        = number
  default     = 15
}

variable "reset_hour_utc" {
  description = "UTC hour (0-23) at which daily quotas reset."
  type        = number
  default     = 0

  validation {
    condition     = var.reset_hour_utc >= 0 && var.reset_hour_utc <= 23
    error_message = "reset_hour_utc must be between 0 and 23."
  }
}

variable "admin_notification_email" {
  description = <<-EOT
    Optional admin email subscribed to EVERY user's notification topic, so an
    administrator is copied on all block/reset events. Set to null to disable.
  EOT
  type        = string
  default     = null
}

variable "enable_reporting" {
  description = "Create the daily/monthly spend reporting (S3 bucket, SNS topic, Lambda, schedules)."
  type        = bool
  default     = true
}

variable "report_bucket_name" {
  description = "S3 bucket name for reports. Null = auto-name claude-code-bedrock-reports-<account>-<region>."
  type        = string
  default     = null
}

variable "report_bucket_force_destroy" {
  description = "Allow Terraform to destroy the report bucket even if it contains reports."
  type        = bool
  default     = false
}

variable "report_retention_days" {
  description = "Days to keep report CSVs in S3 before lifecycle expiry."
  type        = number
  default     = 400
}

variable "report_daily_hour_utc" {
  description = "UTC hour the daily report runs (and the hour-of-day for the monthly run)."
  type        = number
  default     = 1

  validation {
    condition     = var.report_daily_hour_utc >= 0 && var.report_daily_hour_utc <= 23
    error_message = "report_daily_hour_utc must be between 0 and 23."
  }
}

variable "report_monthly_day_of_month" {
  description = <<-EOT
    Day of month the monthly Cost Explorer report runs. Default 3 to allow
    billing data for the prior month to finalize (Cost Explorer lags ~24h+).
  EOT
  type        = number
  default     = 3

  validation {
    condition     = var.report_monthly_day_of_month >= 1 && var.report_monthly_day_of_month <= 28
    error_message = "report_monthly_day_of_month must be between 1 and 28."
  }
}

variable "tags" {
  description = "Additional tags applied to all resources."
  type        = map(string)
  default     = {}
}
