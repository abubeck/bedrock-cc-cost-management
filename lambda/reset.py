"""
Daily reset Lambda for Claude Code Bedrock quotas.

Runs once per day at the configured UTC hour. Detaches the quota-deny policy
from every managed user, giving everyone a clean slate for the new day.

Note: the enforcer also re-derives spend from the current UTC day's logs on
every run, so even if this reset were skipped, users would be unblocked on the
first enforcer pass after midnight UTC. This Lambda makes the reset immediate
and explicit.
"""

import json
import os

import boto3

bedrock = boto3.client("bedrock")
sns = boto3.client("sns")

MANAGED_USERS = json.loads(os.environ["MANAGED_USERS"])
AIP_USER_MAP = json.loads(os.environ["AIP_USER_MAP_JSON"])
TOPIC_MAP = json.loads(os.environ.get("TOPIC_MAP_JSON", "{}"))  # {user: topic_arn}


def _aips_for_user(user: str):
    return [arn for arn, data in AIP_USER_MAP.items() if data["user"] == user]


def _is_tagged(aip_arn: str) -> bool:
    resp = bedrock.list_tags_for_resource(resourceARN=aip_arn)
    for tag in resp.get("tags", []):
        if tag["key"] == "QuotaExceeded" and tag["value"] == "true":
            return True
    return False


def _notify_reset(user: str):
    topic = TOPIC_MAP.get(user)
    if not topic:
        return
    try:
        sns.publish(
            TopicArn=topic,
            Subject="Claude Code: daily quota reset",
            Message=(
                f"Hi {user},\n\n"
                f"A new day has started and your Claude Code daily Bedrock quota "
                f"has been reset. Your access is restored.\n\nHappy coding!\n"
            ),
        )
        print(f"NOTIFY {user}: reset")
    except Exception as e:
        print(f"WARN notify {user} failed: {e}")


def handler(event, context):
    reset = []
    for user in MANAGED_USERS:
        aips = _aips_for_user(user)
        if not aips:
            continue
            
        if _is_tagged(aips[0]):
            for aip in aips:
                bedrock.untag_resource(resourceARN=aip, tagKeys=["QuotaExceeded"])
            reset.append(user)
            print(f"RESET {user}: untagged AIPs")
            _notify_reset(user)
    return {"status": "ok", "reset_users": reset}
