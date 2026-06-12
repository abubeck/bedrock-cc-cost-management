"""
Enforcer Lambda for Claude Code on Bedrock per-user daily spend caps.

Runs on a schedule (default every 15 min). For each managed user it:
  1. Queries today's Bedrock invocation logs (CloudWatch Logs Insights),
     summing input/output tokens per AIP ARN.
  2. Converts tokens -> USD using the configured price map.
  3. Publishes a per-user "DailySpendUSD" metric to CloudWatch.
  4. If spend >= the user's daily cap, attaches the quota-deny managed policy
     (blocking all Bedrock invocation). If under cap, ensures it is detached
     (covers the case where the reset Lambda has not yet run but a new UTC day
     has begun -- usage is always re-derived for the current UTC day).

This is REACTIVE: a user can overshoot by at most one evaluation interval
before the deny lands. There is no native Bedrock per-user hard cap.
"""

import datetime
import json
import os
import time

import boto3

logs = boto3.client("logs")
bedrock = boto3.client("bedrock")
cw = boto3.client("cloudwatch")
sns = boto3.client("sns")

LOG_GROUP = os.environ["LOG_GROUP_NAME"]
# QUOTA_POLICY_ARN removed for Tag-Based Deny
USER_QUOTAS = json.loads(os.environ["USER_QUOTAS_JSON"])      # {user: daily_usd_cap}
PRICE_MAP = json.loads(os.environ["PRICE_MAP_JSON"])          # {model: {input, output}}
AIP_USER_MAP = json.loads(os.environ["AIP_USER_MAP_JSON"])    # {aip_arn: {user, model}}
METRIC_NS = os.environ.get("METRIC_NAMESPACE", "ClaudeCode/Quota")
# {user: sns_topic_arn}. Empty if notifications are disabled.
TOPIC_MAP = json.loads(os.environ.get("TOPIC_MAP_JSON", "{}"))

# Logs Insights query: per modelId (== AIP ARN) token totals for the window.
QUERY = """
fields modelId,
       coalesce(input.inputTokenCount, 0) as inTok,
       coalesce(input.cacheReadInputTokenCount, 0) as cacheReadTok,
       coalesce(input.cacheWriteInputTokenCount, 0) as cacheWriteTok,
       coalesce(output.outputTokenCount, 0) as outTok
| filter ispresent(modelId)
| stats sum(inTok) as inputTokens, sum(cacheReadTok) as cacheReadTokens, sum(cacheWriteTok) as cacheWriteTokens, sum(outTok) as outputTokens by modelId
"""


def _start_of_utc_day_epoch() -> int:
    now = datetime.datetime.now(datetime.timezone.utc)
    start = now.replace(hour=0, minute=0, second=0, microsecond=0)
    return int(start.timestamp())


def _run_query(start_epoch: int, end_epoch: int):
    resp = logs.start_query(
        logGroupName=LOG_GROUP,
        startTime=start_epoch,
        endTime=end_epoch,
        queryString=QUERY,
    )
    qid = resp["queryId"]
    # Poll for completion (Logs Insights is async).
    for _ in range(30):  # ~30s max
        result = logs.get_query_results(queryId=qid)
        if result["status"] in ("Complete", "Failed", "Cancelled", "Timeout"):
            return result
        time.sleep(1)
    logs.stop_query(queryId=qid)
    return {"status": "Timeout", "results": []}


def _rows_to_field_dicts(results):
    out = []
    for row in results.get("results", []):
        out.append({f["field"]: f["value"] for f in row})
    return out


def _spend_per_user(field_rows):
    """Aggregate AIP-level token totals into per-user USD spend."""
    spend = {u: 0.0 for u in USER_QUOTAS}
    for row in field_rows:
        aip = row.get("modelId", "")
        mapping = AIP_USER_MAP.get(aip)
        if not mapping:
            # Usage not coming through one of our AIPs (e.g. direct invoke that
            # somehow slipped through). Cannot attribute -> skip; the bypass
            # guardrail policy should prevent this in the first place.
            continue
        user = mapping["user"]
        model = mapping["model"]
        cache_ttl = mapping.get("cache_ttl", "5m")
        price = PRICE_MAP.get(model, {"input": 0.0, "output": 0.0, "cache_read": 0.0, "cache_write_5m": 0.0, "cache_write_1h": 0.0})
        write_price = price["cache_write_1h"] if cache_ttl == "1h" else price["cache_write_5m"]
        in_tok = float(row.get("inputTokens", 0) or 0)
        cache_read_tok = float(row.get("cacheReadTokens", 0) or 0)
        cache_write_tok = float(row.get("cacheWriteTokens", 0) or 0)
        out_tok = float(row.get("outputTokens", 0) or 0)
        cost = ((in_tok / 1000.0) * price["input"] +
                (cache_read_tok / 1000.0) * price["cache_read"] +
                (cache_write_tok / 1000.0) * write_price +
                (out_tok / 1000.0) * price["output"])
        spend[user] = spend.get(user, 0.0) + cost
    return spend


def _aips_for_user(user: str):
    return [arn for arn, data in AIP_USER_MAP.items() if data["user"] == user]

def _is_tagged(aip_arn: str) -> bool:
    resp = bedrock.list_tags_for_resource(resourceARN=aip_arn)
    for tag in resp.get("tags", []):
        if tag["key"] == "QuotaExceeded" and tag["value"] == "true":
            return True
    return False

def _enforce(user: str, over_cap: bool) -> str:
    """Apply enforcement and return the transition that occurred:
    'newly_blocked', 'newly_unblocked', or 'no_change'."""
    aips = _aips_for_user(user)
    if not aips:
        return "no_change"
        
    # Assume all AIPs for a user share the same state to avoid partial states
    currently = _is_tagged(aips[0])
    
    if over_cap and not currently:
        for aip in aips:
            bedrock.tag_resource(resourceARN=aip, tags=[{"key": "QuotaExceeded", "value": "true"}])
        print(f"BLOCKED {user}: tagged AIPs")
        return "newly_blocked"
    elif not over_cap and currently:
        for aip in aips:
            bedrock.untag_resource(resourceARN=aip, tagKeys=["QuotaExceeded"])
        print(f"UNBLOCKED {user}: untagged AIPs")
        return "newly_unblocked"
    return "no_change"


def _notify(user: str, transition: str, used: float, cap: float):
    """Send an email (via the user's SNS topic) only on a state transition,
    so the user gets exactly one message when blocked and one when freed --
    not one every enforcement interval."""
    topic = TOPIC_MAP.get(user)
    if not topic or transition == "no_change":
        return

    if transition == "newly_blocked":
        subject = "Claude Code: daily Bedrock quota reached"
        body = (
            f"Hi {user},\n\n"
            f"Your Claude Code usage on Amazon Bedrock has reached your daily "
            f"limit of ${cap:.2f} (estimated spend so far today: ${used:.2f}).\n\n"
            f"Bedrock requests will be blocked for the rest of the day and you "
            f"will see 'AccessDenied' errors in Claude Code. Access resets "
            f"automatically at the start of the next day (UTC).\n\n"
            f"If you need a higher limit, contact your administrator.\n"
        )
    else:  # newly_unblocked
        subject = "Claude Code: Bedrock access restored"
        body = (
            f"Hi {user},\n\n"
            f"Your daily Claude Code quota has reset and your access to Amazon "
            f"Bedrock is restored. Current estimated spend today: ${used:.2f} "
            f"of your ${cap:.2f} limit.\n\n"
            f"Happy coding!\n"
        )

    try:
        sns.publish(TopicArn=topic, Subject=subject, Message=body)
        print(f"NOTIFY {user}: {transition}")
    except Exception as e:  # never let a notification failure break enforcement
        print(f"WARN notify {user} failed: {e}")


def handler(event, context):
    start = _start_of_utc_day_epoch()
    end = int(time.time())

    results = _run_query(start, end)
    if results["status"] != "Complete":
        print(f"WARN: query status={results['status']}; skipping this run")
        # Fail open: do not change enforcement state on a failed read.
        return {"status": results["status"]}

    rows = _rows_to_field_dicts(results)
    spend = _spend_per_user(rows)

    metric_data = []
    summary = {}
    for user, cap in USER_QUOTAS.items():
        used = round(spend.get(user, 0.0), 6)
        over = used >= cap
        transition = _enforce(user, over)
        _notify(user, transition, used, cap)
        summary[user] = {
            "spend_usd": used,
            "cap_usd": cap,
            "blocked": over,
            "transition": transition,
        }
        metric_data.append({
            "MetricName": "DailySpendUSD",
            "Dimensions": [{"Name": "User", "Value": user}],
            "Value": used,
            "Unit": "None",
        })

    if metric_data:
        cw.put_metric_data(Namespace=METRIC_NS, MetricData=metric_data)

    print(json.dumps(summary))
    return {"status": "ok", "summary": summary}
