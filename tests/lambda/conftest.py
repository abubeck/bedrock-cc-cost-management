import os
import sys
import pytest

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '../../lambda')))

os.environ["AWS_DEFAULT_REGION"] = "us-east-1"
os.environ["AWS_ACCESS_KEY_ID"] = "testing"
os.environ["AWS_SECRET_ACCESS_KEY"] = "testing"
os.environ["LOG_GROUP_NAME"] = "/dummy/log/group"
os.environ["USER_QUOTAS_JSON"] = '{"alice": 5.0, "bob": 10.0}'
os.environ["PRICE_MAP_JSON"] = '{"sonnet": {"input": 0.003, "output": 0.015, "cache_read": 0.0003, "cache_write_5m": 0.00375, "cache_write_1h": 0.00375}}'
os.environ["AIP_USER_MAP_JSON"] = '{"arn:aws:bedrock:us-east-1:111:aip/1": {"user": "alice", "model": "sonnet"}, "arn:aws:bedrock:us-east-1:111:aip/2": {"user": "bob", "model": "sonnet"}}'
os.environ["METRIC_NAMESPACE"] = "ClaudeCode/QuotaTest"
os.environ["TOPIC_MAP_JSON"] = '{"alice": "arn:aws:sns:us-east-1:111:alice-topic"}'
os.environ["REPORT_BUCKET"] = "dummy-report-bucket"
os.environ["MANAGED_USERS"] = '["alice", "bob"]'

