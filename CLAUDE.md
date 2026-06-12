# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Initialize (run once, or after provider changes)
terraform init

# Validate and plan
terraform validate
terraform plan

# Apply
terraform apply

# Get user env blocks to distribute (use -json for paste-ready output)
terraform output -json claude_code_env_per_user

# Get permission set policy to attach to Landing Zone
terraform output permission_set_policy_json

# See post-apply manual steps
terraform output next_steps
```

For the `example/` directory, run the same commands from within it (`cd example/`).

To manually invoke a Lambda for testing:
```bash
aws lambda invoke --function-name claude-code-quota-enforcer /tmp/out.json && cat /tmp/out.json
aws lambda invoke --function-name claude-code-bedrock-report \
  --payload '{"mode":"daily"}' /tmp/out.json && cat /tmp/out.json
```

## Architecture

This is a **Terraform module** (root = the module itself, `example/` = a working consumer). It provisions per-user Bedrock cost tracking and reactive daily USD spend caps — no external proxy.

**Enforcement flow:**
```
Claude Code → Application Inference Profile (AIP) → Bedrock foundation model
                     ↓
Bedrock invocation logging → CloudWatch Log Group (identity.arn + token counts)
                     ↓
EventBridge (every 15 min) → enforcer Lambda
  - Logs Insights query: token totals per AIP ARN for today
  - Converts tokens → USD via PRICE_MAP_JSON env var
  - If spend ≥ cap: tags AIP with QuotaExceeded=true  ← block lands here
  - Publishes DailySpendUSD metric + SNS email on transition

EventBridge (daily 00:00 UTC) → reset Lambda
  - Removes QuotaExceeded tag from all AIPs (clean slate for new day)
```

**Key design decisions:**

- **ABAC enforcement**: The Permission Set IAM policy (output, not created here) uses `aws:userid StringLike *:<ResourceTag/User>` so each SSO principal can only invoke their own AIPs. User keys in `var.users` must exactly match the SSO role session name.
- **Tag-based deny**: When quota is exceeded, the enforcer tags the AIP with `QuotaExceeded=true`. The Permission Set policy has a Deny statement that fires on this tag. No IAM policy attachment/detachment needed.
- **One AIP per user × model**: The `local.user_model_pairs` flatten in `main.tf` drives all AIP creation. The `lifecycle { ignore_changes = [tags["QuotaExceeded"]] }` block prevents Terraform from removing the enforcement tag on the next plan.
- **Single Lambda package**: All three Lambdas (`enforcer.py`, `reset.py`, `report.py`) are zipped together from `lambda/`. Terraform uses `archive_file` data source; the zip is written to `.build/enforcer.zip`.
- **Reactive cap, not hard cap**: Users can overshoot by at most one enforcement interval (default 15 min). A hard 429 cap requires a proxy — out of scope.

**Reporting** (separate Lambda, `report.py`):
- Daily report: CloudWatch Logs Insights → estimated USD from token counts → CSV to S3 + SNS email
- Monthly report: AWS Cost Explorer → actual billed USD grouped by `User`/`ModelTier` tags → CSV to S3 + SNS email

## Key constraints

- **One Bedrock logging config per account/region.** If one already exists, set `manage_bedrock_logging = false` and point `invocation_log_group_name` at the existing group.
- **Cost-allocation tags** (`User`, `CostCenter`, `Team`, `Application`, `ModelTier`) must be activated in the Billing console — up to 24h delay and not retroactive.
- **EU cross-region inference profiles** use the `eu.` prefix (e.g., `eu.anthropic.claude-sonnet-4-6`).
- **SNS email subscriptions** require a one-time confirmation click per subscriber before alerts fire.
- **`terraform output -json`** is required for `claude_code_env_per_user` — the default HCL output uses `=` instead of `:` and cannot be pasted into `settings.json`.
- The `model_catalog` validation rejects ARNs containing `000000000000` (placeholder account ID).
