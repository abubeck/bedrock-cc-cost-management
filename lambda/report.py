"""
Reporting Lambda for Claude Code on Bedrock spend.

Two modes, selected by the EventBridge input event {"mode": "daily"|"monthly"}:

  daily   -> Reads the previous full UTC day from Bedrock invocation logs
             (CloudWatch Logs Insights), sums tokens per user per model,
             converts to an ESTIMATED USD spend via the price map. Fast, no
             billing lag, and consistent with the numbers users see in their
             quota emails. Good for a same-day operational view.

  monthly -> Reads the previous calendar month from AWS Cost Explorer, grouped
             by the cost-allocation tags on the Application Inference Profiles
             (User + model). These are ACTUAL billed dollars and match your
             invoice, but Cost Explorer data lags ~24h, so this runs a few days
             into the new month.

Both modes write a CSV to S3 (s3://<bucket>/reports/<period>/...) and publish a
human-readable summary email to the reporting SNS topic.

The two sources will not match to the cent: 'daily' is a token-based estimate,
'monthly' is billed truth. That is expected and noted in the email.
"""

import csv
import datetime
import io
import json
import os
import time

import boto3

logs = boto3.client("logs")
s3 = boto3.client("s3")
sns = boto3.client("sns")
ce = boto3.client("ce")

LOG_GROUP = os.environ["LOG_GROUP_NAME"]
PRICE_MAP = json.loads(os.environ["PRICE_MAP_JSON"])          # {model: {input, output}}
AIP_USER_MAP = json.loads(os.environ["AIP_USER_MAP_JSON"])    # {aip_arn: {user, model}}
REPORT_BUCKET = os.environ["REPORT_BUCKET"]
REPORT_TOPIC = os.environ.get("REPORT_TOPIC_ARN", "")
TAG_KEY_USER = os.environ.get("COST_TAG_USER", "User")
TAG_KEY_MODEL = os.environ.get("COST_TAG_MODEL", "ModelTier")

PER_AIP_QUERY = """
fields modelId,
       coalesce(input.inputTokenCount, 0) as inTok,
       coalesce(input.cacheReadInputTokenCount, 0) as cacheReadTok,
       coalesce(input.cacheWriteInputTokenCount, 0) as cacheWriteTok,
       coalesce(output.outputTokenCount, 0) as outTok
| filter ispresent(modelId)
| stats count(*) as invocations, sum(inTok) as inputTokens, sum(cacheReadTok) as cacheReadTokens, sum(cacheWriteTok) as cacheWriteTokens, sum(outTok) as outputTokens by modelId
"""

AUDIT_QUERY = """
fields modelId
| filter ispresent(modelId) and (input.inputBodyJson like '"ttl":"1h"' or input.inputBodyJson like '"ttl": "1h"')
| stats count(*) as has1h by modelId
"""


# --------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------- #
def _run_logs_query(start_epoch, end_epoch, query_string):
    qid = logs.start_query(
        logGroupName=LOG_GROUP,
        startTime=start_epoch,
        endTime=end_epoch,
        queryString=query_string,
    )["queryId"]
    for _ in range(60):
        r = logs.get_query_results(queryId=qid)
        if r["status"] in ("Complete", "Failed", "Cancelled", "Timeout"):
            return r
        time.sleep(1)
    logs.stop_query(queryId=qid)
    return {"status": "Timeout", "results": []}


def _publish(subject, body):
    if REPORT_TOPIC:
        sns.publish(TopicArn=REPORT_TOPIC, Subject=subject[:100], Message=body)


def _put_csv(key, header, rows):
    buf = io.StringIO()
    w = csv.writer(buf)
    w.writerow(header)
    w.writerows(rows)
    s3.put_object(
        Bucket=REPORT_BUCKET,
        Key=key,
        Body=buf.getvalue().encode("utf-8"),
        ContentType="text/csv",
    )
    return f"s3://{REPORT_BUCKET}/{key}"


def _fmt_table(header, rows):
    widths = [len(h) for h in header]
    for r in rows:
        for i, c in enumerate(r):
            widths[i] = max(widths[i], len(str(c)))
    line = "  ".join(h.ljust(widths[i]) for i, h in enumerate(header))
    out = [line, "  ".join("-" * widths[i] for i in range(len(header)))]
    for r in rows:
        out.append("  ".join(str(c).ljust(widths[i]) for i, c in enumerate(r)))
    return "\n".join(out)


# --------------------------------------------------------------------------- #
# daily (CloudWatch logs, estimated)
# --------------------------------------------------------------------------- #
def _daily(now_utc):
    yesterday = (now_utc - datetime.timedelta(days=1)).date()
    start = datetime.datetime.combine(
        yesterday, datetime.time.min, tzinfo=datetime.timezone.utc
    )
    end = start + datetime.timedelta(days=1)
    
    res = _run_logs_query(int(start.timestamp()), int(end.timestamp()), PER_AIP_QUERY)
    if res["status"] != "Complete":
        _publish(
            f"Claude Code daily report FAILED ({yesterday})",
            f"Logs Insights query status: {res['status']}",
        )
        return {"status": res["status"]}

    audit_res = _run_logs_query(int(start.timestamp()), int(end.timestamp()), AUDIT_QUERY)
    has_1h_models = set()
    if audit_res["status"] == "Complete":
        for row in audit_res.get("results", []):
            d = {f["field"]: f["value"] for f in row}
            if int(d.get("has1h", 0) or 0) > 0:
                has_1h_models.add(d.get("modelId", ""))

    agg = {}
    # user_cache accumulates token totals per user so the Admin Cache Overview
    # can emit one row per user — matching how Claude Code applies the TTL setting
    # (globally, not per model). cache_ttl is per-user in var.users; if AIPs for
    # the same user somehow diverge, max() surfaces the discrepancy.
    user_cache = {}

    for row in res.get("results", []):
        d = {f["field"]: f["value"] for f in row}
        aip = d.get("modelId", "")
        m = AIP_USER_MAP.get(aip)
        if not m:
            continue

        user, model, cache_ttl = m["user"], m["model"], m.get("cache_ttl", "5m")
        price = PRICE_MAP.get(model)
        if price is None:
            # Terraform validates price coverage; zero-pricing here would
            # silently under-report spend, so skip loudly instead.
            print(f"ERROR: no price for model '{model}' (AIP {aip}); "
                  f"its usage is EXCLUDED from the daily report")
            continue
        write_price = price["cache_write_1h"] if cache_ttl == "1h" else price["cache_write_5m"]

        invocs = int(d.get("invocations", 0) or 0)
        in_tok = float(d.get("inputTokens", 0) or 0)
        cache_read_tok = float(d.get("cacheReadTokens", 0) or 0)
        cache_write_tok = float(d.get("cacheWriteTokens", 0) or 0)
        out_tok = float(d.get("outputTokens", 0) or 0)
        usd = ((in_tok / 1000.0) * price["input"] +
               (cache_read_tok / 1000.0) * price["cache_read"] +
               (cache_write_tok / 1000.0) * write_price +
               (out_tok / 1000.0) * price["output"])

        uc = user_cache.get(user)
        if uc is None:
            user_cache[user] = {
                "cache_ttl": cache_ttl,
                "in_tok": in_tok,
                "cache_read_tok": cache_read_tok,
                "cache_write_tok": cache_write_tok,
                "has_1h": aip in has_1h_models,
            }
        else:
            uc["cache_ttl"] = max(uc["cache_ttl"], cache_ttl)
            uc["in_tok"] += in_tok
            uc["cache_read_tok"] += cache_read_tok
            uc["cache_write_tok"] += cache_write_tok
            uc["has_1h"] = uc["has_1h"] or (aip in has_1h_models)

        k = (user, model)
        cur = agg.get(k, [0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
        hit_rate_pct = 0.0
        total_in = in_tok + cache_read_tok + cache_write_tok
        if total_in > 0:
            hit_rate_pct = round((cache_read_tok / total_in) * 100, 1)
        agg[k] = [cur[0] + invocs, cur[1] + in_tok, cur[2] + cache_read_tok, cur[3] + cache_write_tok, hit_rate_pct, cur[5] + out_tok, cur[6] + usd]

    admin_rows = []
    for user, uc in sorted(user_cache.items()):
        cache_ttl = uc["cache_ttl"]
        cache_read_tok = uc["cache_read_tok"]
        cache_write_tok = uc["cache_write_tok"]
        in_tok = uc["in_tok"]
        total_in = in_tok + cache_read_tok + cache_write_tok
        hit_rate = (cache_read_tok / total_in) if total_in > 0 else 0.0
        hit_rate_pct = round(hit_rate * 100, 1)

        actual_usage = "5m"
        if cache_read_tok == 0 and cache_write_tok == 0:
            actual_usage = "Disabled or <1k tokens"
        elif uc["has_1h"]:
            actual_usage = "1h"

        suggested = "5m"
        if hit_rate < 0.22:
            suggested = "Disabled"
        elif hit_rate > 0.50:
            suggested = "5m or 1h"

        notes = ""
        if cache_ttl != actual_usage and actual_usage != "Disabled or <1k tokens":
            notes = f"Mismatch! Paying {cache_ttl} tier but using {actual_usage} locally."
        elif cache_ttl != "5m" and actual_usage == "Disabled or <1k tokens":
            notes = f"Paying {cache_ttl} tier but caching disabled."
        elif hit_rate < 0.22 and actual_usage != "Disabled or <1k tokens":
            notes = f"Losing money on caching. (Hit Rate: {hit_rate_pct}%)"

        admin_rows.append([user, cache_ttl, actual_usage, suggested, notes])

    rows = [
        [u, m, int(v[0]), int(v[1]), int(v[2]), int(v[3]), v[4], int(v[5]), round(v[6], 4)]
        for (u, m), v in sorted(agg.items())
    ]
    header = ["user", "model", "invocations", "input_tokens", "cache_read_tokens", "cache_write_tokens", "cache_hit_rate_pct", "output_tokens", "est_usd"]
    key = f"reports/daily/{yesterday}.csv"
    uri = _put_csv(key, header, rows)

    totals = {}
    for (u, _), v in agg.items():
        totals[u] = round(totals.get(u, 0.0) + v[6], 4)
    total_rows = [[u, f"${c:.4f}"] for u, c in sorted(totals.items())]
    grand = sum(totals.values())

    body = (
        f"Claude Code on Bedrock - DAILY report for {yesterday} (UTC)\n"
        f"Source: CloudWatch invocation logs (ESTIMATED from token counts)\n\n"
        f"Per-user estimated spend:\n"
        f"{_fmt_table(['user', 'est_usd'], total_rows)}\n\n"
        f"Total estimated: ${grand:.4f}\n\n"
        f"Admin Cache Overview (for cost tuning):\n"
        f"{_fmt_table(['User', 'Configured Billing Tier', 'Actual CLI Usage', 'Suggested Setting', 'Notes'], admin_rows)}\n\n"
        f"Full per-model breakdown: {uri}\n"
    )
    _publish(f"Claude Code daily report - {yesterday} (${grand:.2f})", body)
    return {"status": "ok", "mode": "daily", "s3": uri, "total_usd": round(grand, 4)}


# --------------------------------------------------------------------------- #
# monthly (Cost Explorer, billed)
# --------------------------------------------------------------------------- #
def _month_bounds(now_utc):
    first_this = now_utc.date().replace(day=1)
    last_prev = first_this - datetime.timedelta(days=1)
    first_prev = last_prev.replace(day=1)
    return first_prev, first_this  # CE end date is exclusive


def _monthly(now_utc):
    start, end = _month_bounds(now_utc)
    label = start.strftime("%Y-%m")
    resp = ce.get_cost_and_usage(
        TimePeriod={"Start": start.isoformat(), "End": end.isoformat()},
        Granularity="MONTHLY",
        Metrics=["UnblendedCost"],
        Filter={"Dimensions": {"Key": "SERVICE", "Values": ["Amazon Bedrock"]}},
        GroupBy=[
            {"Type": "TAG", "Key": TAG_KEY_USER},
            {"Type": "TAG", "Key": TAG_KEY_MODEL},
        ],
    )

    rows = []
    totals = {}
    for result in resp.get("ResultsByTime", []):
        for grp in result.get("Groups", []):
            # keys come back like "User$alice", "ModelTier$sonnet"
            keys = [k.split("$", 1)[-1] or "(untagged)" for k in grp["Keys"]]
            user = keys[0] if len(keys) > 0 else "(untagged)"
            model = keys[1] if len(keys) > 1 else "(untagged)"
            amt = float(grp["Metrics"]["UnblendedCost"]["Amount"])
            rows.append([user, model, round(amt, 4)])
            totals[user] = round(totals.get(user, 0.0) + amt, 4)

    rows.sort()
    header = ["user", "model", "billed_usd"]
    key = f"reports/monthly/{label}.csv"
    uri = _put_csv(key, header, rows)

    total_rows = [[u, f"${c:.2f}"] for u, c in sorted(totals.items())]
    grand = sum(totals.values())
    body = (
        f"Claude Code on Bedrock - MONTHLY report for {label}\n"
        f"Source: AWS Cost Explorer (ACTUAL billed, unblended USD)\n\n"
        f"Per-user billed spend:\n"
        f"{_fmt_table(['user', 'billed_usd'], total_rows)}\n\n"
        f"Total billed: ${grand:.2f}\n\n"
        f"Full per-model breakdown: {uri}\n\n"
        f"Note: requires the User/{TAG_KEY_MODEL} cost-allocation tags to be "
        f"ACTIVATED in Billing; untagged rows mean tags weren't active yet.\n"
    )
    _publish(f"Claude Code monthly report - {label} (${grand:.2f})", body)
    return {"status": "ok", "mode": "monthly", "s3": uri, "total_usd": round(grand, 2)}


# --------------------------------------------------------------------------- #
def handler(event, context):
    mode = (event or {}).get("mode", "daily")
    now = datetime.datetime.now(datetime.timezone.utc)
    if mode == "monthly":
        return _monthly(now)
    return _daily(now)
