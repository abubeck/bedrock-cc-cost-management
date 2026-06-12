#!/usr/bin/env bash
# check-usage.sh — show today's Claude Code Bedrock spend vs. daily cap.
#
# Data sources:
#   - Spend : CloudWatch metric DailySpendUSD (namespace ClaudeCode/Quota),
#             published by the enforcer Lambda every ~15 min. At most that
#             old; use "data age" in the output to judge freshness.
#             The ClaudeCodeUser Permission Set grants cloudwatch:GetMetricStatistics
#             on * (IAM does not support namespace conditions on this action).
#   - Cap   : Enforcer Lambda environment variable USER_QUOTAS_JSON.
#             Requires lambda:GetFunctionConfiguration (admin / ops role only).
#             End users will see cap as "unknown" and no percentage is printed.
#
# Requirements: aws CLI, jq, date (macOS or GNU), bash >= 4.
#
# Exit codes: 0 = under cap (or cap unknown), 2 = over cap.

set -euo pipefail

FUNCTION_NAME="claude-code-quota-enforcer"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
USER_ARG=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Show today's Claude Code Bedrock spend vs. your daily budget cap.

Options:
  --user <name>          Target user (default: your own SSO session name)
  --region <region>      AWS region (default: \$AWS_REGION / \$AWS_DEFAULT_REGION)
  --function-name <name> Enforcer Lambda name (default: $FUNCTION_NAME)
  -h, --help             Show this help

Examples:
  $(basename "$0")
  $(basename "$0") --user alice@example.com
  $(basename "$0") --user alice@example.com --region eu-west-1
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)           USER_ARG="$2"; shift 2 ;;
    --region)         REGION="$2"; shift 2 ;;
    --function-name)  FUNCTION_NAME="$2"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

# ── Validate dependencies ────────────────────────────────────────────────────
for cmd in aws jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "error: '$cmd' not found on PATH" >&2; exit 1; }
done

REGION_FLAG=()
[[ -n "$REGION" ]] && REGION_FLAG=(--region "$REGION")

# ── Resolve target user ──────────────────────────────────────────────────────
if [[ -n "$USER_ARG" ]]; then
  TARGET_USER="$USER_ARG"
else
  CALLER_ARN=$(aws sts get-caller-identity "${REGION_FLAG[@]}" --query Arn --output text 2>/dev/null) \
    || { echo "error: could not determine caller identity (check AWS credentials)" >&2; exit 1; }
  # assumed-role ARN: arn:aws:sts::ACCT:assumed-role/ROLE/SESSION → SESSION
  # IAM user ARN:     arn:aws:iam::ACCT:user/NAME → NAME
  TARGET_USER="${CALLER_ARN##*/}"
fi

# ── Time window: UTC midnight → now ─────────────────────────────────────────
if date --version >/dev/null 2>&1; then
  # GNU date
  MIDNIGHT=$(date -u +%Y-%m-%dT00:00:00Z)
  NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  NOW_EPOCH=$(date -u +%s)
else
  # macOS date
  MIDNIGHT=$(date -u -j -f "%Y-%m-%d %H:%M:%S" "$(date -u +%Y-%m-%d) 00:00:00" +%Y-%m-%dT00:00:00Z)
  NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  NOW_EPOCH=$(date -u +%s)
fi

# ── Fetch spend from CloudWatch ──────────────────────────────────────────────
METRIC_JSON=$(aws cloudwatch get-metric-statistics \
  "${REGION_FLAG[@]}" \
  --namespace ClaudeCode/Quota \
  --metric-name DailySpendUSD \
  --dimensions Name=User,Value="$TARGET_USER" \
  --start-time "$MIDNIGHT" \
  --end-time "$NOW" \
  --period 86400 \
  --statistics Maximum \
  --output json) || { echo "error: CloudWatch query failed (see above)" >&2; exit 1; }

DATAPOINTS=$(echo "$METRIC_JSON" | jq '.Datapoints | length')
if [[ "$DATAPOINTS" -eq 0 ]]; then
  SPEND="0.00"
  DATA_AGE_STR="no data yet today"
else
  SPEND=$(echo "$METRIC_JSON" | jq -r '[.Datapoints[].Maximum] | max | . * 100 | round / 100 | tostring')
  TIMESTAMP=$(echo "$METRIC_JSON" | jq -r '[.Datapoints[] | .Timestamp] | sort | last')
  if date --version >/dev/null 2>&1; then
    DP_EPOCH=$(date -u -d "$TIMESTAMP" +%s 2>/dev/null || echo "$NOW_EPOCH")
  else
    DP_EPOCH=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "${TIMESTAMP%.*}Z" +%s 2>/dev/null || echo "$NOW_EPOCH")
  fi
  AGE_MIN=$(( (NOW_EPOCH - DP_EPOCH) / 60 ))
  DATA_AGE_STR="${AGE_MIN} min ago"
fi

# ── Fetch cap from Lambda env (best-effort; may lack permission) ─────────────
CAP="unknown"
QUOTAS_JSON=$(aws lambda get-function-configuration \
  "${REGION_FLAG[@]}" \
  --function-name "$FUNCTION_NAME" \
  --query 'Environment.Variables.USER_QUOTAS_JSON' \
  --output text 2>/dev/null) || true

if [[ -n "$QUOTAS_JSON" && "$QUOTAS_JSON" != "None" ]]; then
  CAP_RAW=$(echo "$QUOTAS_JSON" | jq -r --arg u "$TARGET_USER" '.[$u] // empty' 2>/dev/null || true)
  if [[ -n "$CAP_RAW" ]]; then
    CAP="$CAP_RAW"
  else
    echo "error: user '$TARGET_USER' not found in enforcer quota map" >&2
    exit 1
  fi
fi

# ── Compute percentage and blocked status ────────────────────────────────────
if [[ "$CAP" != "unknown" ]]; then
  PCT=$(echo "$SPEND $CAP" | awk '{printf "%.1f", $1/$2*100}')
  BLOCKED_STATUS="no"
  EXIT_CODE=0
  if (( $(echo "$SPEND >= $CAP" | bc -l) )); then
    BLOCKED_STATUS="YES"
    EXIT_CODE=2
  fi
else
  PCT=""
  BLOCKED_STATUS="unknown (cap unavailable)"
  EXIT_CODE=0
fi

# ── ASCII progress bar (30 chars) ────────────────────────────────────────────
BAR=""
if [[ -n "$PCT" ]]; then
  FILLED=$(echo "$PCT" | awk '{v=int($1/100*30+0.5); print (v>30)?30:v}')
  EMPTY=$(( 30 - FILLED ))
  BAR="["
  for ((i=0; i<FILLED; i++)); do BAR+="#"; done
  for ((i=0; i<EMPTY; i++)); do BAR+="-"; done
  BAR+="]"
fi

# ── Output ───────────────────────────────────────────────────────────────────
printf "user:    %s\n" "$TARGET_USER"
if [[ "$CAP" != "unknown" ]]; then
  printf "spent:   \$%s / \$%s  (%s%%)\n" "$SPEND" "$CAP" "$PCT"
else
  printf "spent:   \$%s  (cap unknown — needs lambda:GetFunctionConfiguration)\n" "$SPEND"
fi
printf "blocked: %s  (data age: %s)\n" "$BLOCKED_STATUS" "$DATA_AGE_STR"
[[ -n "$BAR" ]] && printf "%s\n" "$BAR"

exit "${EXIT_CODE:-0}"
