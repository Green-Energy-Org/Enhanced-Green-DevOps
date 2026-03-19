from fastapi.testclient import TestClient
from main import app
import pytest

client = TestClient(app)

class MockResponse:
    class Choice:
        class Message:
            content = "Mocked DevOps response"
        message = Message()
    choices = [Choice()]

@pytest.fixture(autouse=True)
def mock_groq(monkeypatch):
    def mock_create(*args, **kwargs):
        return MockResponse()

    monkeypatch.setattr(
        "main.client.chat.completions.create",
        mock_create
    )

def test_chat():
    response = client.post("/chat", json={"message": "Explain Docker"})
    assert response.status_code == 200
    assert "response" in response.json()
