import os

os.environ["DATABASE_URL"] = "sqlite://"

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.database import Base, get_db
from app.main import app

engine = create_engine("sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool)
TestingSession = sessionmaker(bind=engine)


def override_get_db():
    db = TestingSession()
    try:
        yield db
    finally:
        db.close()


app.dependency_overrides[get_db] = override_get_db


@pytest.fixture(autouse=True)
def clean_db():
    Base.metadata.create_all(bind=engine)
    yield
    Base.metadata.drop_all(bind=engine)


client = TestClient(app)


def test_health():
    assert client.get("/health").json() == {"status": "ok"}


def test_create_and_list():
    r = client.post("/tasks", json={"title": "Зробити лабу"})
    assert r.status_code == 201
    assert r.json()["done"] is False
    tasks = client.get("/tasks").json()
    assert len(tasks) == 1
    assert tasks[0]["title"] == "Зробити лабу"


def test_empty_title_rejected():
    assert client.post("/tasks", json={"title": ""}).status_code == 422


def test_mark_done():
    task_id = client.post("/tasks", json={"title": "A"}).json()["id"]
    r = client.patch(f"/tasks/{task_id}", json={"done": True})
    assert r.status_code == 200
    assert r.json()["done"] is True


def test_delete():
    task_id = client.post("/tasks", json={"title": "B"}).json()["id"]
    assert client.delete(f"/tasks/{task_id}").status_code == 204
    assert client.get("/tasks").json() == []


def test_not_found():
    assert client.patch("/tasks/999", json={"done": True}).status_code == 404
    assert client.delete("/tasks/999").status_code == 404
