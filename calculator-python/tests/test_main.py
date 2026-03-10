from fastapi.testclient import TestClient
from app.main import app

client = TestClient(app)

def test_add_operation():
    response = client.post("/calculate", json={"operation": "add", "x": 10, "y": 5})
    assert response.status_code == 200
    assert response.json() == {"result": 15.0}

def test_unsupported_op():
    response = client.post("/calculate", json={"operation": "multiply", "x": 10, "y": 5})
    assert response.json() == {"result": "Operation not supported"}
