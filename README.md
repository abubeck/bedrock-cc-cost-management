# bedrock-cost-management

[![CI](https://github.com/abubeck/bedrock-cc-cost-management/actions/workflows/ci.yml/badge.svg)](https://github.com/abubeck/bedrock-cc-cost-management/actions/workflows/ci.yml)

Terraform module that provisions, for each of N users, an individual
**Application Inference Profile** (per model tier) for Bedrock cost tracking,
plus a **reactive daily USD spend cap** that resets every day.

Users are managed via a **Landing Zone Permission Set** — no IAM users are
created. Enforcement uses tag-based deny: the enforcer Lambda tags an AIP with
`QuotaExceeded=true` when the cap is reached, which the Permission Set policy
denies. The reset Lambda removes the tag at midnight UTC.

## Architecture

```
Claude Code → Application Inference Profile (AIP) → Bedrock foundation model
                      |
        Bedrock invocation logging
                      |
        CloudWatch Log Group (identity.arn + token counts)
                      |
  EventBridge (every 15 min) → Enforcer Lambda
    - Queries token totals per AIP ARN for today
    - Converts tokens → USD via price_per_1k_tokens
    - If spend ≥ cap: tags AIP QuotaExceeded=true  ← block lands here
    - Publishes DailySpendUSD metric + SNS email on transition
                      |
  EventBridge (daily 00:00 UTC) → Reset Lambda
    - Removes QuotaExceeded tag from all AIPs (clean slate for new day)
```

## What it creates

| Resource | Purpose |
|---|---|
| `aws_bedrock_inference_profile` (one per user × model) | Cost-attribution wrapper. Its tags flow into Cost Explorer / CUR. |
| Permission Set policy document (output) | Attach to your Landing Zone permission set. Allows each user to invoke only their own AIPs; uses ABAC on `aws:userid` for ownership checks; includes a tag-based `QuotaExceeded` deny. |
| Bedrock model invocation logging → CloudWatch | The per-user usage source of truth (`identity.arn`, `modelId`, token counts). |
| Enforcer Lambda + EventBridge (every 15 min) | Sums today's tokens per user, converts to USD, tags/untags AIPs with `QuotaExceeded=true`. Publishes `ClaudeCode/Quota DailySpendUSD` metric. |
| Reset Lambda + EventBridge (daily 00:00 UTC) | Removes `QuotaExceeded` tag from all AIPs at the start of each new day. |
| `aws_sns_topic` + email subscription (per user with `notify_email`) | Emails the user when they get blocked and when access is restored. Optional admin copied on all. |
| Reporting Lambda + S3 bucket + SNS topic + 2 schedules | Daily spend breakdown (from logs, estimated) and monthly breakdown (from Cost Explorer, billed). CSV to S3 + summary email. |

## How enforcement works (and its one limitation)

Bedrock has **no native per-user spend limit**. This module enforces caps
*reactively*: every `enforcement_interval_minutes` it reads the day's usage
from invocation logs and blocks any user at/over their cap. A user can
therefore overshoot by **at most one interval** (default 15 min) before the
block lands. For a hard, pre-spend 429 cap you need a proxy in front of
Bedrock (LiteLLM / Lambda gateway) — out of scope here.

Spend is computed from **billed** token counts and `price_per_1k_tokens`.
(Bedrock's 5× output-token *quota burndown* for Claude 3.7+ affects throttling,
not your bill, so it is intentionally not in the cost math.)

## Session name requirement

The Allow statement in the generated Permission Set policy uses:

```
Condition: StringLike aws:userid = "*:<ResourceTag/User>"
```

`aws:userid` for an assumed-role session is `<RoleId>:<RoleSessionName>`. The
session name must therefore equal the user's key in `var.users`. In most SSO
setups the session name is the SSO username — configure your `users` map keys
to match (e.g. use `alice` if the SSO session name is `alice`, or
`alice@example.com` if the session name is the full email).

## Usage

See `example/`. Minimum:

```hcl
module "claude_code_quota" {
  source = "github.com/abubeck/bedrock-cc-cost-management"

  users = {
    # Keys must match SSO session names — see README.
    alice = { team = "Platform", cost_center = "CC-1042", daily_usd_cap = 20, models = ["sonnet","haiku"] }
    bob   = { team = "Data",     cost_center = "CC-2080", daily_usd_cap = 10, models = ["sonnet","haiku"] }
  }

  model_catalog = {
    sonnet = { source_arn = "arn:aws:bedrock:eu-west-1:111122223333:inference-profile/eu.anthropic.claude-sonnet-4-5-20250929-v1:0" }
    haiku  = { source_arn = "arn:aws:bedrock:eu-west-1:111122223333:inference-profile/eu.anthropic.claude-haiku-4-5-20251001-v1:0" }
  }
}
```

Then read `module.claude_code_quota.claude_code_env_per_user` and put each
user's block into their `~/.claude/settings.json` `env`.

## Notifications

Set `notify_email` on a user to have them emailed when they hit their cap
("daily quota reached", with the cap amount and current spend) and again when
access is restored at reset. Notifications fire only on the *transition* — one
email when blocked, one when freed — not on every 15-min evaluation. Set
`admin_notification_email` to copy an admin on every user's events.

SNS email subscriptions require a **one-time confirmation click**: AWS sends
each subscriber an "AWS Notification - Subscription Confirmation" email after
`apply`. Until they click it, they won't receive alerts. (For a no-confirmation
channel, swap the `email` protocol subscription for Slack/Chatbot or an SES
Lambda — easy to extend.)

## Reporting

Enabled by default (`enable_reporting = true`). Produces two breakdowns of
Bedrock spend, each written as a CSV to S3 and summarized in an email to the
reporting SNS topic (admin subscribed):

- **Daily** (`cron` at `report_daily_hour_utc`, default 01:00 UTC): covers the
  previous full UTC day. Source is the CloudWatch invocation logs, so it's
  available immediately with no billing lag — but it's an **estimate** computed
  from token counts × `price_per_1k_tokens`. It matches the numbers users see
  in their quota emails. CSV: `s3://<bucket>/reports/daily/YYYY-MM-DD.csv`,
  columns `user, model, input_tokens, output_tokens, est_usd`.
- **Monthly** (`report_monthly_day_of_month`, default day 3): covers the
  previous calendar month. Source is **AWS Cost Explorer** grouped by the `User`
  and `ModelTier` cost-allocation tags — these are **actual billed dollars** and
  match your invoice. Runs a few days into the month so billing data finalizes.
  CSV: `s3://<bucket>/reports/monthly/YYYY-MM.csv`, columns
  `user, model, billed_usd`.

The two won't match to the cent: daily is a token estimate, monthly is billed
truth. That's expected. You can also invoke the Lambda manually with
`{"mode":"daily"}` or `{"mode":"monthly"}` to backfill or test.

Reports older than `report_retention_days` (default 400) are expired from S3 by
a lifecycle rule. Set `enable_reporting = false` to skip all of this.

## Manual steps Terraform can't do

1. **Enable model access** in the Bedrock console for each model (per region).
2. **Activate cost-allocation tags** in Billing (`User`, `CostCenter`, `Team`,
   `Application`, `ModelTier`). ~24h delay, **not retroactive** — do this first.
3. **Attach the policy**: apply the module, copy `permission_set_policy_json`
   output, and attach it to your Landing Zone `ClaudeCodeUser` Permission Set.
   Ensure each principal's SSO session name matches their `var.users` key.
4. **Distribute env blocks**: give each user their `claude_code_env_per_user`
   values to place in `~/.claude/settings.json`. A complete working config looks like:
   ```json
   {
     "awsAuthRefresh": "aws sso login --profile <your-sso-profile>",
     "env": {
       "CLAUDE_CODE_USE_BEDROCK": "1",
       "ANTHROPIC_DEFAULT_HAIKU_MODEL":  "<haiku-aip-arn>",
       "ANTHROPIC_DEFAULT_SONNET_MODEL": "<sonnet-aip-arn>",
       "ANTHROPIC_DEFAULT_OPUS_MODEL":   "<opus-aip-arn>",
       "AWS_REGION": "<region>",
       "AWS_PROFILE": "<your-sso-profile>"
     },
     "model": "opusplan"
   }
   ```
   Get AIP ARNs with `terraform output -json claude_code_env_per_user` (use `-json` — the default HCL output uses `=` instead of `:` and cannot be pasted directly into `settings.json`).
   Use `"model": "opusplan"` to have Claude Code use Opus for planning/thinking
   and Sonnet for regular responses.
5. **Confirm pricing** in `price_per_1k_tokens` against current Bedrock rates.
6. **Confirm SNS email subscriptions** — each user/admin clicks the link in the
   confirmation email or they get no quota alerts. The admin must also confirm
   the separate **reporting** topic subscription.
7. **Enable Cost Explorer** once in the Billing console (needed for the monthly
   report). The daily report works without it.

## Important constraints

- Bedrock allows **one** invocation-logging config per account/region. If you
  already have one, set `manage_bedrock_logging = false` and point
  `invocation_log_group_name` at the existing group.
- AIPs cap at ~1,000 per account/region and are one-model-each — fine for a
  handful of users, not for per-developer at 1,000-user scale (use OIDC +
  CloudWatch `identity.arn` attribution there instead).
- EU cross-region inference profiles use the `eu.` prefix (e.g.
  `eu.anthropic.claude-sonnet-4-5-...`), not `us.`.
- Claude Code's local `/cost` mis-attributes AIP usage (known bug); trust
  Cost Explorer and the `DailySpendUSD` metric over the in-app number.

## Check your usage

`scripts/check-usage.sh` shows your current daily spend and how much of your
budget you've used, without needing to open the AWS console.

```bash
# Your own usage (defaults to your SSO session name)
./scripts/check-usage.sh

# Another user (admin use — requires lambda:GetFunctionConfiguration)
./scripts/check-usage.sh --user alice@example.com

# Specify region if $AWS_REGION is not set
./scripts/check-usage.sh --region eu-west-1
```

Example output:

```
user:    alice@example.com
spent:   $3.42 / $10.00  (34.2%)
blocked: no  (data age: 7 min)
[##########--------------------]
```

The spend figure comes from the `DailySpendUSD` CloudWatch metric published by
the enforcer Lambda, so it's at most ~15 minutes old. The script exits with
code `2` if the user is over cap (useful in shell pipelines). The daily cap is
read from the Lambda's environment; if your IAM role lacks
`lambda:GetFunctionConfiguration` (typical for end users), only the spend
amount is shown without a percentage.

The `ClaudeCodeUser` Permission Set is granted `cloudwatch:GetMetricStatistics`
scoped to the `ClaudeCode/Quota` namespace, so end users can read their own
spend. The daily cap is read from the Lambda env var, which requires
`lambda:GetFunctionConfiguration` (admin/ops role only) — end users see spend
only, without a percentage or bar.

Requirements: `aws` CLI, `jq`, valid AWS credentials.

## Requirements

- Terraform >= 1.7, AWS provider >= 5.40 (for `aws_bedrock_inference_profile`).
- `archive` provider >= 2.4.
