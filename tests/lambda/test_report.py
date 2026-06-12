from unittest.mock import patch
from report import handler

@patch("report.s3")
@patch("report.sns")
@patch("report.logs")
def test_daily_report(mock_logs, mock_sns, mock_s3):
    mock_logs.start_query.return_value = {"queryId": "q1"}
    mock_logs.get_query_results.return_value = {
        "status": "Complete",
        "results": [
            [
                {"field": "modelId", "value": "arn:aws:bedrock:us-east-1:111:aip/1"},
                {"field": "invocations", "value": "5"},
                {"field": "inputTokens", "value": "1000"},
                {"field": "outputTokens", "value": "1000"}
            ]
        ]
    }
    
    res = handler({"mode": "daily"}, None)
    assert res["status"] == "ok"
    assert res["mode"] == "daily"
    assert res["total_usd"] == 0.018
    assert mock_s3.put_object.called

@patch("report.ce")
@patch("report.s3")
@patch("report.sns")
def test_monthly_report(mock_sns, mock_s3, mock_ce):
    mock_ce.get_cost_and_usage.return_value = {
        "ResultsByTime": [
            {
                "Groups": [
                    {
                        "Keys": ["User$alice", "ModelTier$sonnet"],
                        "Metrics": {"UnblendedCost": {"Amount": "12.34"}}
                    }
                ]
            }
        ]
    }
    
    res = handler({"mode": "monthly"}, None)
    assert res["status"] == "ok"
    assert res["mode"] == "monthly"
    assert res["total_usd"] == 12.34
    assert mock_s3.put_object.called
