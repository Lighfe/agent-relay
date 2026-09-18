"""Live integration test: hits a running relay over real HTTP against its
real database (no TestClient, no schema reset). Requires a server already
running, e.g. `uv run uvicorn main:app --port 8000`.

Point RELAY_BASE_URL at a different instance if needed; defaults to the
local dev server.
"""

from __future__ import annotations

import os
import uuid

import httpx
import pytest

BASE_URL = os.environ.get("RELAY_BASE_URL", "http://127.0.0.1:8000")


@pytest.fixture(scope="module")
def client():
    with httpx.Client(base_url=BASE_URL, timeout=10.0) as client:
        try:
            client.get("/health").raise_for_status()
        except httpx.HTTPError as exc:
            pytest.skip(f"relay not reachable at {BASE_URL}: {exc}")
        yield client


def register(client: httpx.Client, name: str) -> tuple[dict, dict[str, str]]:
    response = client.post("/api/v1/agents", json={"name": name})
    assert response.status_code == 201, response.text
    data = response.json()
    assert "agent_id" in data and "token" in data
    return data, {"Authorization": f"Bearer {data['token']}"}


def test_live_register_send_claim_complete_and_read_result(client: httpx.Client):
    sender, sender_headers = register(client, "live-alice-sender")
    recipient, recipient_headers = register(client, "live-bob-worker")

    idempotency_key = f"live-test-{uuid.uuid4().hex}"
    sent = client.post(
        "/api/v1/tasks",
        headers={**sender_headers, "Idempotency-Key": idempotency_key},
        json={"to": recipient["agent_id"], "input": "hello from alice"},
    )
    assert sent.status_code == 201, sent.text
    task_id = sent.json()["task_id"]
    assert sent.json()["status"] == "queued"

    claim = client.post(
        "/api/v1/tasks/claim",
        headers=recipient_headers,
        json={"worker_id": "live-bob-worker-1", "wait_seconds": 5},
    )
    assert claim.status_code == 200, claim.text
    claim_data = claim.json()
    assert claim_data["task_id"] == task_id
    assert claim_data["from"] == sender["agent_id"]
    assert claim_data["input"] == "hello from alice"
    assert claim_data["attempt"] == 1
    claim_token = claim_data["claim_token"]

    complete = client.post(
        f"/api/v1/tasks/{task_id}/complete",
        headers=recipient_headers,
        json={"claim_token": claim_token, "output": "HELLO FROM ALICE"},
    )
    assert complete.status_code == 200, complete.text
    assert complete.json() == {"task_id": task_id, "status": "completed"}

    result = client.get(f"/api/v1/tasks/{task_id}", headers=sender_headers)
    assert result.status_code == 200, result.text
    body = result.json()
    assert body["status"] == "completed"
    assert body["output"] == "HELLO FROM ALICE"
    assert body["error"] is None
    assert body["from"] == sender["agent_id"]
    assert body["to"] == recipient["agent_id"]
    assert body["finished_at"] is not None
