###############################################################################
# main.tf
#
# Per-user Claude Code on Bedrock: individual cost tracking + reactive daily
# USD spend cap with automatic midnight reset.
#
# Architecture (all native AWS, no external proxy):
#
#   Claude Code (user) --> Application Inference Profile (tagged) --> Bedrock FM
#                                   |
#   Bedrock model invocation logging --> CloudWatch Log Group
#                                   |
#   EventBridge (every 15 min) --> Enforcer Lambda
#                                   |  - reads today's token usage per user
#                                   |    from the log group via Logs Insights
#                                   |  - converts tokens -> USD with a price map
#                                   |  - if spend >= daily cap: attach a DENY
#                                   |    policy to that user (blocks Bedrock)
#                                   |  - else: ensure the DENY policy is detached
#                                   |
#   EventBridge (daily 00:00 UTC) --> Reset Lambda
#                                      - detaches the DENY policy from all users
#                                        (new day => clean slate; usage is
#                                         re-derived from logs each run anyway)
#
# NOTE ON SEMANTICS: this is a *reactive* cap. Because Bedrock has no native
# per-user spend limit, a user can overshoot by at most one invocation cycle
# (up to ~15 min of usage) before the DENY lands. For a true hard 429 cap you
# need a proxy in front of Bedrock; that is out of scope for this module.
###############################################################################

terraform {
  required_version = ">= 1.7.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4.0"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region

  # Common tags applied to every resource for cost allocation.
  common_tags = merge(var.tags, {
    Application = "ClaudeCode"
    ManagedBy   = "terraform"
    Module      = "bedrock-claude-quota"
  })

  # Flatten: one (user, model) pair per Application Inference Profile.
  # Each user gets one AIP per model tier they are allowed to use.
  user_model_pairs = {
    for pair in flatten([
      for uname, ucfg in var.users : [
        for model_key in ucfg.models : {
          key       = "${uname}-${model_key}"
          user      = uname
          model_key = model_key
          model_arn = var.model_catalog[model_key].source_arn
          cost_tag  = ucfg.cost_center
          cache_ttl = ucfg.cache_ttl
        }
      ]
    ]) : pair.key => pair
  }
}

# (IAM Users removed. Users are managed via Landing Zone Permission Set)

###############################################################################
# APPLICATION INFERENCE PROFILES (one per user x model)
#
# AIPs are the AWS-native cost-attribution wrapper. They CANNOT be created in
# the console; Terraform uses the aws_bedrock_inference_profile resource.
# The tags below are what flows into Cost Explorer / CUR once activated as
# cost-allocation tags in the Billing console (24h delay, not retroactive).
###############################################################################

resource "aws_bedrock_inference_profile" "this" {
  for_each = local.user_model_pairs

  name        = "cc-${replace(replace(each.value.user, "@", "-"), ".", "-")}-${each.value.model_key}"
  description = "Claude Code AIP for ${replace(replace(each.value.user, "@", "-"), ".", "-")} ${each.value.model_key}"

  model_source {
    copy_from = each.value.model_arn
  }

  tags = merge(local.common_tags, {
    User       = each.value.user
    CostCenter = each.value.cost_tag
    Team       = var.users[each.value.user].team
    ModelTier  = each.value.model_key
  })

  lifecycle {
    ignore_changes = [tags["QuotaExceeded"]]
  }
}

###############################################################################
# LANDING ZONE PERMISSION SET POLICY (OUTPUT)
#
# Since this module uses a shared Landing Zone Permission Set for all users,
# you must attach this policy document to your `ClaudeCodeUser` permission set.
# It uses ABAC (aws:userid matching the 'User' tag) to ensure users can only
# invoke their own Inference Profiles, and enforces the QuotaExceeded tag.
###############################################################################

data "aws_iam_policy_document" "permission_set" {
  # 1. Direct invocation of the user's own AIPs.
  statement {
    sid    = "AllowInvokeOwnApplicationInferenceProfiles"
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]
    resources = ["arn:aws:bedrock:*:*:application-inference-profile/*"]
    condition {
      test     = "StringLike"
      variable = "aws:userid"
      values   = ["*:$${aws:ResourceTag/User}"]
    }
  }

  # 2. Resolved invocation of underlying model, only via an AIP.
  statement {
    sid    = "AllowResolvedInvokeViaAIPOnly"
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]
    resources = ["arn:aws:bedrock:*::foundation-model/*"]
    condition {
      test     = "StringLike"
      variable = "bedrock:InferenceProfileArn"
      values   = ["arn:aws:bedrock:*:*:application-inference-profile/*"]
    }
  }

  # 3. Discovery actions (Claude Code lists profiles at startup).
  statement {
    sid    = "AllowProfileDiscovery"
    effect = "Allow"
    actions = [
      "bedrock:ListInferenceProfiles",
      "bedrock:GetInferenceProfile",
      "bedrock:ListFoundationModels",
      "bedrock:GetFoundationModel",
    ]
    resources = ["*"]
  }

  # 4. Guardrail: deny any model invocation that bypasses an AIP entirely.
  statement {
    sid    = "DenyDirectModelInvokeBypassingAIP"
    effect = "Deny"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]
    # Only foundation-model ARNs here. Including inference-profile/* would
    # fire on legitimate AIP invocations (bedrock:InferenceProfileArn is null
    # on a direct InvokeModel against an AIP ARN), blocking the primary path.
    resources = ["arn:aws:bedrock:*::foundation-model/*"]
    condition {
      test     = "Null"
      variable = "bedrock:InferenceProfileArn"
      values   = ["true"]
    }
  }

  # 5. CloudWatch read-only: own daily spend metric (used by check-usage.sh).
  # Neither GetMetricStatistics nor GetMetricData support resource-level or
  # namespace conditions in IAM — cloudwatch:namespace is only valid on
  # PutMetricData. The * resource with no condition is required.
  statement {
    sid    = "AllowReadOwnSpendMetric"
    effect = "Allow"
    actions = [
      "cloudwatch:GetMetricStatistics",
      "cloudwatch:GetMetricData",
    ]
    resources = ["*"]
  }

  # 6. Tag-based Quota Deny
  statement {
    sid    = "DenyQuotaExceeded"
    effect = "Deny"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]
    resources = ["arn:aws:bedrock:*:*:application-inference-profile/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/QuotaExceeded"
      values   = ["true"]
    }
  }
}

###############################################################################
# NOTIFICATIONS (SNS + email)
#
# One SNS topic per user. The enforcer publishes to it on the transition into
# "blocked", and the reset Lambda publishes on unblock. Each user's email is
# subscribed (requires a one-time confirmation click in the email AWS sends).
# An optional admin email is subscribed to every topic.
#
# Topics are only created for users that have a notify_email set.
###############################################################################

locals {
  notify_users = {
    for uname, ucfg in var.users : uname => ucfg
    if try(ucfg.notify_email, null) != null
  }
}

resource "aws_sns_topic" "user_quota" {
  for_each = local.notify_users

  name = "claude-code-quota-${replace(replace(each.key, "@", "-"), ".", "-")}"
  tags = merge(local.common_tags, { User = each.key })
}

# Allow both Lambdas to publish to the topics.
resource "aws_sns_topic_policy" "user_quota" {
  for_each = local.notify_users

  arn = aws_sns_topic.user_quota[each.key].arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowLambdaPublish"
      Effect    = "Allow"
      Principal = { AWS = aws_iam_role.lambda.arn }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.user_quota[each.key].arn
    }]
  })
}

resource "aws_sns_topic_subscription" "user_email" {
  for_each = local.notify_users

  topic_arn = aws_sns_topic.user_quota[each.key].arn
  protocol  = "email"
  endpoint  = each.value.notify_email
}

# Optional: admin copied on every user's topic.
resource "aws_sns_topic_subscription" "admin_email" {
  for_each = var.admin_notification_email == null ? {} : local.notify_users

  topic_arn = aws_sns_topic.user_quota[each.key].arn
  protocol  = "email"
  endpoint  = var.admin_notification_email
}

###############################################################################
# REPORTING (S3 + dedicated SNS topic)
#
# Daily and monthly spend breakdowns. Reports are written as CSV to S3 and a
# summary is emailed to the reporting topic (admin email subscribed).
###############################################################################

resource "aws_s3_bucket" "reports" {
  count         = var.enable_reporting ? 1 : 0
  bucket        = var.report_bucket_name != null ? var.report_bucket_name : "claude-code-bedrock-reports-${local.account_id}-${local.region}"
  force_destroy = var.report_bucket_force_destroy
  tags          = local.common_tags
}

resource "aws_s3_bucket_public_access_block" "reports" {
  count                   = var.enable_reporting ? 1 : 0
  bucket                  = aws_s3_bucket.reports[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "reports" {
  count  = var.enable_reporting ? 1 : 0
  bucket = aws_s3_bucket.reports[0].id
  rule {
    id     = "expire-old-reports"
    status = "Enabled"
    filter { prefix = "reports/" }
    expiration { days = var.report_retention_days }
  }
}

resource "aws_sns_topic" "reports" {
  count = var.enable_reporting ? 1 : 0
  name  = "claude-code-bedrock-reports"
  tags  = local.common_tags
}

resource "aws_sns_topic_subscription" "reports_admin" {
  count     = var.enable_reporting && var.admin_notification_email != null ? 1 : 0
  topic_arn = aws_sns_topic.reports[0].arn
  protocol  = "email"
  endpoint  = var.admin_notification_email
}

###############################################################################
# BEDROCK MODEL INVOCATION LOGGING -> CLOUDWATCH
#
# This is account-wide (Bedrock supports one logging config per account/region)
# and is the source of truth for per-user token usage. Logs include
# identity.arn, modelId (the AIP ARN), input/output token counts.
###############################################################################

resource "aws_cloudwatch_log_group" "bedrock_invocations" {
  count             = var.manage_bedrock_logging ? 1 : 0
  name              = var.invocation_log_group_name
  retention_in_days = var.log_retention_days
  tags              = local.common_tags
}

# Role Bedrock assumes to write invocation logs to CloudWatch.
data "aws_iam_policy_document" "bedrock_logging_assume" {
  count = var.manage_bedrock_logging ? 1 : 0
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["bedrock.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "bedrock_logging" {
  count              = var.manage_bedrock_logging ? 1 : 0
  name               = "claude-code-bedrock-logging"
  assume_role_policy = data.aws_iam_policy_document.bedrock_logging_assume[0].json
  tags               = local.common_tags
}

resource "aws_iam_role_policy" "bedrock_logging" {
  count = var.manage_bedrock_logging ? 1 : 0
  name  = "write-invocation-logs"
  role  = aws_iam_role.bedrock_logging[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.bedrock_invocations[0].arn}:*"
    }]
  })
}

resource "aws_bedrock_model_invocation_logging_configuration" "this" {
  count = var.manage_bedrock_logging ? 1 : 0

  logging_config {
    embedding_data_delivery_enabled = false
    image_data_delivery_enabled     = false
    text_data_delivery_enabled      = true
    video_data_delivery_enabled     = false

    cloudwatch_config {
      log_group_name = aws_cloudwatch_log_group.bedrock_invocations[0].name
      role_arn       = aws_iam_role.bedrock_logging[0].arn
    }
  }

  depends_on = [aws_iam_role_policy.bedrock_logging]
}

###############################################################################
# ENFORCER LAMBDA
###############################################################################

data "archive_file" "enforcer" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/.build/enforcer.zip"
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "claude-code-quota-enforcer"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "lambda_perms" {
  # Read usage from the invocation log group via Logs Insights.
  statement {
    sid    = "LogsInsights"
    effect = "Allow"
    actions = [
      "logs:StartQuery",
      "logs:GetQueryResults",
      "logs:StopQuery",
    ]
    resources = ["*"] # StartQuery does not support resource-level scoping reliably
  }

  # Tag AIPs when quota exceeded; list tags to check current state before tagging.
  statement {
    sid    = "ManageAIPTags"
    effect = "Allow"
    actions = [
      "bedrock:TagResource",
      "bedrock:UntagResource",
      "bedrock:ListTagsForResource",
    ]
    resources = [for k, p in local.user_model_pairs : aws_bedrock_inference_profile.this[k].arn]
  }

  # Publish quota notifications to per-user SNS topics.
  statement {
    sid       = "PublishNotifications"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = length(local.notify_users) > 0 ? [for t in aws_sns_topic.user_quota : t.arn] : ["arn:aws:sns:${local.region}:${local.account_id}:claude-code-quota-none"]
  }

  # Write its own logs.
  statement {
    sid    = "OwnLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["arn:aws:logs:${local.region}:${local.account_id}:*"]
  }

  # Publish a custom CloudWatch metric per user (current daily spend).
  statement {
    sid       = "PublishMetrics"
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["ClaudeCode/Quota"]
    }
  }
}

resource "aws_iam_role_policy" "lambda" {
  name   = "enforcer-permissions"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda_perms.json
}

###############################################################################
# REPORTING LAMBDA ROLE (separate, least-privilege)
###############################################################################

resource "aws_iam_role" "report" {
  count              = var.enable_reporting ? 1 : 0
  name               = "claude-code-bedrock-reporter"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "report_perms" {
  count = var.enable_reporting ? 1 : 0

  statement {
    sid       = "LogsInsights"
    effect    = "Allow"
    actions   = ["logs:StartQuery", "logs:GetQueryResults", "logs:StopQuery"]
    resources = ["*"]
  }

  # Cost Explorer is a global service; ce:* actions only accept "*".
  statement {
    sid       = "CostExplorer"
    effect    = "Allow"
    actions   = ["ce:GetCostAndUsage"]
    resources = ["*"]
  }

  statement {
    sid       = "WriteReports"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.reports[0].arn}/reports/*"]
  }

  statement {
    sid       = "PublishReportSummary"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.reports[0].arn]
  }

  statement {
    sid    = "OwnLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["arn:aws:logs:${local.region}:${local.account_id}:*"]
  }
}

resource "aws_iam_role_policy" "report" {
  count  = var.enable_reporting ? 1 : 0
  name   = "reporter-permissions"
  role   = aws_iam_role.report[0].id
  policy = data.aws_iam_policy_document.report_perms[0].json
}

resource "aws_lambda_function" "enforcer" {
  function_name    = "claude-code-quota-enforcer"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = "enforcer.handler"
  timeout          = 120
  filename         = data.archive_file.enforcer.output_path
  source_code_hash = data.archive_file.enforcer.output_base64sha256

  environment {
    variables = {
      LOG_GROUP_NAME = var.invocation_log_group_name
      # Quota Deny IAM policy removed, using tag-based deny
      USER_QUOTAS_JSON  = jsonencode({ for u, c in var.users : u => c.daily_usd_cap })
      PRICE_MAP_JSON    = jsonencode(var.price_per_1k_tokens)
      AIP_USER_MAP_JSON = jsonencode({ for k, p in local.user_model_pairs : aws_bedrock_inference_profile.this[k].arn => { user = p.user, model = p.model_key, cache_ttl = p.cache_ttl } })
      METRIC_NAMESPACE  = "ClaudeCode/Quota"
      TOPIC_MAP_JSON    = jsonencode({ for u, t in aws_sns_topic.user_quota : u => t.arn })
      RESET_HOUR_UTC    = tostring(var.reset_hour_utc)
    }
  }

  tags = local.common_tags

  lifecycle {
    precondition {
      condition     = alltrue([for k, _ in var.model_catalog : contains(keys(var.price_per_1k_tokens), k)])
      error_message = "Every model_catalog key needs a matching entry in price_per_1k_tokens — a missing price would be treated as $0 and the daily cap would never trigger for that model."
    }
  }
}

###############################################################################
# RESET LAMBDA (lightweight: just detaches the deny policy from all users)
###############################################################################

resource "aws_lambda_function" "reset" {
  function_name    = "claude-code-quota-reset"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = "reset.handler"
  timeout          = 60
  filename         = data.archive_file.enforcer.output_path
  source_code_hash = data.archive_file.enforcer.output_base64sha256

  environment {
    variables = {
      MANAGED_USERS     = jsonencode(keys(var.users))
      AIP_USER_MAP_JSON = jsonencode({ for k, p in local.user_model_pairs : aws_bedrock_inference_profile.this[k].arn => { user = p.user, model = p.model_key, cache_ttl = p.cache_ttl } })
      TOPIC_MAP_JSON    = jsonencode({ for u, t in aws_sns_topic.user_quota : u => t.arn })
    }
  }

  tags = local.common_tags
}

###############################################################################
# EVENTBRIDGE SCHEDULES
###############################################################################

# Enforcement run, every var.enforcement_interval_minutes.
resource "aws_cloudwatch_event_rule" "enforce" {
  name                = "claude-code-quota-enforce"
  description         = "Periodically evaluate per-user Bedrock spend and enforce daily caps"
  schedule_expression = "rate(${var.enforcement_interval_minutes} minutes)"
  tags                = local.common_tags
}

resource "aws_cloudwatch_event_target" "enforce" {
  rule      = aws_cloudwatch_event_rule.enforce.name
  target_id = "enforcer"
  arn       = aws_lambda_function.enforcer.arn
}

resource "aws_lambda_permission" "enforce" {
  statement_id  = "AllowEventBridgeEnforce"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.enforcer.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.enforce.arn
}

# Daily reset at the configured UTC hour (default midnight).
resource "aws_cloudwatch_event_rule" "reset" {
  name                = "claude-code-quota-reset"
  description         = "Daily reset of per-user Bedrock quota deny policies"
  schedule_expression = "cron(0 ${var.reset_hour_utc} * * ? *)"
  tags                = local.common_tags
}

resource "aws_cloudwatch_event_target" "reset" {
  rule      = aws_cloudwatch_event_rule.reset.name
  target_id = "reset"
  arn       = aws_lambda_function.reset.arn
}

resource "aws_lambda_permission" "reset" {
  statement_id  = "AllowEventBridgeReset"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.reset.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.reset.arn
}

###############################################################################
# REPORTING LAMBDA + SCHEDULES
#
# Same deployment package (lambda/ dir); handler = report.handler. One function
# handles both daily and monthly; the EventBridge input event selects the mode.
###############################################################################

resource "aws_lambda_function" "report" {
  count            = var.enable_reporting ? 1 : 0
  function_name    = "claude-code-bedrock-report"
  role             = aws_iam_role.report[0].arn
  runtime          = "python3.12"
  handler          = "report.handler"
  timeout          = 180
  filename         = data.archive_file.enforcer.output_path
  source_code_hash = data.archive_file.enforcer.output_base64sha256

  environment {
    variables = {
      LOG_GROUP_NAME    = var.invocation_log_group_name
      PRICE_MAP_JSON    = jsonencode(var.price_per_1k_tokens)
      AIP_USER_MAP_JSON = jsonencode({ for k, p in local.user_model_pairs : aws_bedrock_inference_profile.this[k].arn => { user = p.user, model = p.model_key, cache_ttl = p.cache_ttl } })
      REPORT_BUCKET     = aws_s3_bucket.reports[0].id
      REPORT_TOPIC_ARN  = aws_sns_topic.reports[0].arn
      COST_TAG_USER     = "User"
      COST_TAG_MODEL    = "ModelTier"
    }
  }

  tags = local.common_tags
}

# Daily report: runs each day at var.report_daily_hour_utc, covers the
# PREVIOUS full UTC day from invocation logs.
resource "aws_cloudwatch_event_rule" "report_daily" {
  count               = var.enable_reporting ? 1 : 0
  name                = "claude-code-report-daily"
  description         = "Daily Claude Code Bedrock spend report (estimated, from logs)"
  schedule_expression = "cron(0 ${var.report_daily_hour_utc} * * ? *)"
  tags                = local.common_tags
}

resource "aws_cloudwatch_event_target" "report_daily" {
  count     = var.enable_reporting ? 1 : 0
  rule      = aws_cloudwatch_event_rule.report_daily[0].name
  target_id = "report-daily"
  arn       = aws_lambda_function.report[0].arn
  input     = jsonencode({ mode = "daily" })
}

resource "aws_lambda_permission" "report_daily" {
  count         = var.enable_reporting ? 1 : 0
  statement_id  = "AllowEventBridgeReportDaily"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.report[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.report_daily[0].arn
}

# Monthly report: runs on day var.report_monthly_day_of_month, covers the
# PREVIOUS calendar month from Cost Explorer (billed, ~24h+ lag so default day 3).
resource "aws_cloudwatch_event_rule" "report_monthly" {
  count               = var.enable_reporting ? 1 : 0
  name                = "claude-code-report-monthly"
  description         = "Monthly Claude Code Bedrock spend report (billed, from Cost Explorer)"
  schedule_expression = "cron(0 ${var.report_daily_hour_utc} ${var.report_monthly_day_of_month} * ? *)"
  tags                = local.common_tags
}

resource "aws_cloudwatch_event_target" "report_monthly" {
  count     = var.enable_reporting ? 1 : 0
  rule      = aws_cloudwatch_event_rule.report_monthly[0].name
  target_id = "report-monthly"
  arn       = aws_lambda_function.report[0].arn
  input     = jsonencode({ mode = "monthly" })
}

resource "aws_lambda_permission" "report_monthly" {
  count         = var.enable_reporting ? 1 : 0
  statement_id  = "AllowEventBridgeReportMonthly"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.report[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.report_monthly[0].arn
}
