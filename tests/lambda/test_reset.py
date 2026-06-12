from unittest.mock import patch
from reset import handler

@patch("reset.sns")
@patch("reset.bedrock")
def test_reset_handler(mock_bedrock, mock_sns):
    # Mock Alice's AIP as tagged (QuotaExceeded=true), and Bob's as untagged
    def list_tags_side_effect(resourceARN):
        if resourceARN == "arn:aws:bedrock:us-east-1:111:aip/1":
            return {"tags": [{"key": "QuotaExceeded", "value": "true"}]}
        return {"tags": []}
        
    mock_bedrock.list_tags_for_resource.side_effect = list_tags_side_effect
    
    res = handler({}, None)
    
    assert res["status"] == "ok"
    assert "alice" in res["reset_users"]
    assert "bob" not in res["reset_users"]
    
    mock_bedrock.untag_resource.assert_called_with(
        resourceARN="arn:aws:bedrock:us-east-1:111:aip/1",
        tagKeys=["QuotaExceeded"]
    )
    assert mock_sns.publish.called
