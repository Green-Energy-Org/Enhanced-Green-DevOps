from fastapi.testclient import TestClient
from main import app

client = TestClient(app)

def test_metrics():
    response = client.get("/metrics")
    assert response.status_code == 200
    assert "bot_requests_total" in response.text
