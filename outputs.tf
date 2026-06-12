###############################################################################
# outputs.tf
###############################################################################

output "permission_set_policy_json" {
  description = "IAM Policy JSON to attach to your ClaudeCodeUser Permission Set in the Landing Zone."
  value       = data.aws_iam_policy_document.permission_set.json
}

output "application_inference_profiles" {
  description = <<-EOT
    Per-user Application Inference Profile ARNs, keyed by "<user>-<model>".
    Use these ARNs as ANTHROPIC_MODEL / ANTHROPIC_DEFAULT_*_MODEL in each
    user's Claude Code config.
  EOT
  value = {
    for k, p in aws_bedrock_inference_profile.this : k => {
      arn   = p.arn
      user  = local.user_model_pairs[k].user
      model = local.user_model_pairs[k].model_key
    }
  }
}

output "claude_code_env_per_user" {
  description = <<-EOT
    Ready-to-paste Claude Code environment variables per user. Drop these into
    each user's ~/.claude/settings.json "env" block. The first model listed for
    a user becomes the primary ANTHROPIC_MODEL; a "haiku" AIP, if present, is
    wired up as the small/fast model default.
  EOT
  value = {
    for uname, ucfg in var.users : uname => merge(
      {
        CLAUDE_CODE_USE_BEDROCK = "1"
        AWS_REGION              = local.region
        ANTHROPIC_MODEL         = aws_bedrock_inference_profile.this["${uname}-${ucfg.models[0]}"].arn
      },
      contains(ucfg.models, "haiku") ? {
        ANTHROPIC_DEFAULT_HAIKU_MODEL = aws_bedrock_inference_profile.this["${uname}-haiku"].arn
      } : {},
      contains(ucfg.models, "sonnet") ? {
        ANTHROPIC_DEFAULT_SONNET_MODEL = aws_bedrock_inference_profile.this["${uname}-sonnet"].arn
      } : {},
      contains(ucfg.models, "opus") ? {
        ANTHROPIC_DEFAULT_OPUS_MODEL = aws_bedrock_inference_profile.this["${uname}-opus"].arn
      } : {},
    )
  }
}

output "enforcer_function_name" {
  description = "Name of the enforcer Lambda."
  value       = aws_lambda_function.enforcer.function_name
}

output "reset_function_name" {
  description = "Name of the daily-reset Lambda."
  value       = aws_lambda_function.reset.function_name
}

output "invocation_log_group" {
  description = "CloudWatch Log Group receiving Bedrock invocation logs (the usage source of truth)."
  value       = var.invocation_log_group_name
}

output "notification_topics" {
  description = "Per-user SNS topic ARNs used for quota notifications (only for users with notify_email set)."
  value       = { for u, t in aws_sns_topic.user_quota : u => t.arn }
}

output "report_bucket" {
  description = "S3 bucket holding daily/monthly report CSVs (null if reporting disabled)."
  value       = var.enable_reporting ? aws_s3_bucket.reports[0].id : null
}

output "report_topic_arn" {
  description = "SNS topic that emails report summaries (null if reporting disabled)."
  value       = var.enable_reporting ? aws_sns_topic.reports[0].arn : null
}

output "report_function_name" {
  description = "Name of the reporting Lambda (null if reporting disabled)."
  value       = var.enable_reporting ? aws_lambda_function.report[0].function_name : null
}

output "next_steps" {
  description = "Manual steps Terraform cannot perform."
  value       = <<-EOT
    1. Enable Anthropic model access in the Bedrock console (Model catalog ->
       request access) for each model in your catalog, in ${local.region}.
    2. Activate cost-allocation tags in the Billing console:
       Billing -> Cost allocation tags -> activate: User, CostCenter, Team,
       Application, ModelTier. (Up to 24h to appear; NOT retroactive.)
    3. Attach the permission_set_policy_json output to your Landing Zone
       "ClaudeCodeUser" Permission Set. The policy is intentionally
       account-agnostic (uses arn:aws:bedrock:*:*:application-inference-profile/*) so
       you attach it once and it works in every account where this module is
       deployed — no need to re-render or re-attach when new accounts join.
       Per-user isolation is enforced by ABAC: the Allow statement matches
       aws:userid against *:<ResourceTag/User>, so each SSO principal's role
       session name must match their key in var.users exactly. In most SSO
       setups the session name is the SSO username or email — set your
       users map keys accordingly (e.g. "alice@example.com" if that is the
       session name AWS assigns).
       Then distribute the claude_code_env_per_user values to each user.
    4. Verify pricing in var.price_per_1k_tokens matches current Bedrock rates.
    5. EMAIL NOTIFICATIONS: each user (and the admin, if set) will receive a
       one-time "AWS Notification - Subscription Confirmation" email. They must
       click the confirmation link or they will NOT receive quota alerts.
    6. REPORTING: the admin must confirm the reporting topic subscription too.
       The MONTHLY report uses Cost Explorer, which must be enabled once in the
       Billing console (Cost Explorer -> Launch) and depends on the User and
       ModelTier cost-allocation tags being ACTIVATED (step 2). Until tags are
       active, monthly rows show as "(untagged)". The DAILY report uses logs and
       works immediately.
  EOT
}
