import json
from unittest.mock import patch, MagicMock
from enforcer import handler, _spend_per_user

@patch("enforcer.cw")
@patch("enforcer.sns")
@patch("enforcer.bedrock")
@patch("enforcer.logs")
def test_handler_under_cap(mock_logs, mock_bedrock, mock_sns, mock_cw):
    mock_logs.start_query.return_value = {"queryId": "q1"}
    mock_logs.get_query_results.return_value = {
        "status": "Complete",
        "results": [
            [
                {"field": "modelId", "value": "arn:aws:bedrock:us-east-1:111:aip/1"},
                {"field": "inputTokens", "value": "1000"},
                {"field": "outputTokens", "value": "1000"}
            ]
        ]
    }
    
    # Alice is untagged
    mock_bedrock.list_tags_for_resource.return_value = {"tags": []}

    res = handler({}, None)
    assert res["status"] == "ok"
    assert not mock_bedrock.tag_resource.called
    assert not mock_bedrock.untag_resource.called
    
    # Price is 0.003 for input, 0.015 for output, so total is $0.018 for Alice
    assert res["summary"]["alice"]["spend_usd"] == 0.018
    assert res["summary"]["alice"]["blocked"] is False

@patch("enforcer.cw")
@patch("enforcer.sns")
@patch("enforcer.bedrock")
@patch("enforcer.logs")
def test_handler_over_cap(mock_logs, mock_bedrock, mock_sns, mock_cw):
    mock_logs.start_query.return_value = {"queryId": "q1"}
    # Make Alice go over the $5.0 cap (e.g., 500,000 output tokens = $7.5)
    mock_logs.get_query_results.return_value = {
        "status": "Complete",
        "results": [
            [
                {"field": "modelId", "value": "arn:aws:bedrock:us-east-1:111:aip/1"},
                {"field": "inputTokens", "value": "0"},
                {"field": "outputTokens", "value": "500000"}
            ]
        ]
    }
    
    mock_bedrock.list_tags_for_resource.return_value = {"tags": []}

    res = handler({}, None)
    assert res["status"] == "ok"
    assert mock_bedrock.tag_resource.called
    assert res["summary"]["alice"]["blocked"] is True
    assert res["summary"]["alice"]["transition"] == "newly_blocked"
    assert mock_sns.publish.called

