from fastapi.testclient import TestClient

from main import app

client = TestClient(app)


def test_health_returns_ok():
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_version_returns_default(monkeypatch):
    monkeypatch.delenv("APP_VERSION", raising=False)
    response = client.get("/version")
    assert response.status_code == 200
    assert response.json() == {"version": "0.1.0"}
