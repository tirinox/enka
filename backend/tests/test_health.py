from __future__ import annotations


async def test_health_is_public_and_reports_the_database(anon_client):
    response = await anon_client.get("/health")
    assert response.status_code == 200

    body = response.json()
    assert body["status"] == "ok"
    assert body["database"] == "ok"
    assert body["version"]


async def test_openapi_schema_is_served(anon_client):
    response = await anon_client.get("/openapi.json")
    assert response.status_code == 200
    assert "/api/v1/cards" in response.json()["paths"]


async def test_unknown_route_uses_the_standard_error_envelope(anon_client):
    response = await anon_client.get("/api/v1/does-not-exist")
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "not_found"


async def test_validation_errors_use_the_standard_envelope(client):
    response = await client.post("/api/v1/cards", json={})
    assert response.status_code == 422

    error = response.json()["error"]
    assert error["code"] == "validation_error"
    assert error["details"]["errors"]
