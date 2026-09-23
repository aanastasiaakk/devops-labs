from unittest.mock import patch

import fakeredis
from fastapi.testclient import TestClient

from app import main
from app.main import app, compute_stats

client = TestClient(app)

SAMPLE = [
    {"id": 1, "title": "a", "done": True},
    {"id": 2, "title": "b", "done": False},
    {"id": 3, "title": "c", "done": True},
    {"id": 4, "title": "d", "done": False},
]


def test_compute_stats():
    assert compute_stats(SAMPLE) == {"total": 4, "done": 2, "open": 2, "percent_done": 50.0}


def test_compute_stats_empty():
    assert compute_stats([]) == {"total": 0, "done": 0, "open": 0, "percent_done": 0.0}


def test_stats_endpoint_uses_cache():
    main.cache = fakeredis.FakeRedis(decode_responses=True)
    with patch.object(main, "fetch_tasks", return_value=SAMPLE) as fetch:
        first = client.get("/stats").json()
        second = client.get("/stats").json()
    assert first["cached"] is False
    assert second["cached"] is True
    assert second["total"] == 4
    fetch.assert_called_once()  # другий запит узяли з кешу, а не з tasks-service


def test_health():
    assert client.get("/health").json() == {"status": "ok"}
