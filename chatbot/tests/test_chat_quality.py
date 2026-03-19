def test_chat_quality(client):
    response = client.post("/chat", json={"message": "What is CI/CD?"})
    assert "pipeline" in response.json()["response"].lower()
