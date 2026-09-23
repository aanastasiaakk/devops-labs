"""Stats service: рахує статистику задач.

Бере список задач із tasks-service по HTTP і кешує результат у Redis на кілька секунд.
Це приклад взаємодії двох мікросервісів та інфраструктурного елемента (кешу).
"""
import json
import os

import httpx
import redis
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware

TASKS_URL = os.getenv("TASKS_URL", "http://localhost:8000")
REDIS_URL = os.getenv("REDIS_URL", "redis://localhost:6379/0")
CACHE_TTL = int(os.getenv("CACHE_TTL", "5"))
CACHE_KEY = "stats"

app = FastAPI(title="Stats service")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

cache = redis.Redis.from_url(REDIS_URL, decode_responses=True)


def compute_stats(tasks: list[dict]) -> dict:
    total = len(tasks)
    done = sum(1 for t in tasks if t.get("done"))
    return {
        "total": total,
        "done": done,
        "open": total - done,
        "percent_done": round(done * 100 / total, 1) if total else 0.0,
    }


def fetch_tasks() -> list[dict]:
    try:
        r = httpx.get(f"{TASKS_URL}/tasks", timeout=5)
        r.raise_for_status()
        return r.json()
    except httpx.HTTPError as e:
        raise HTTPException(status_code=502, detail=f"tasks-service unavailable: {e}")


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/stats")
def stats():
    try:
        cached = cache.get(CACHE_KEY)
    except redis.RedisError:
        cached = None  # якщо Redis недоступний — просто працюємо без кешу
    if cached:
        return {**json.loads(cached), "cached": True}

    result = compute_stats(fetch_tasks())
    try:
        cache.setex(CACHE_KEY, CACHE_TTL, json.dumps(result))
    except redis.RedisError:
        pass
    return {**result, "cached": False}
