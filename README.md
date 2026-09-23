# Лабораторна робота №1 — Віртуалізація та контейнеризація

Простий **Task Manager** з мікросервісною архітектурою, повністю запакований у Docker.

## Архітектура

```
 Браузер ──► frontend (nginx, :8080)
               ├── /api/tasks ──► tasks-service (FastAPI, :8000) ──► db (PostgreSQL)
               └── /api/stats ──► stats-service (FastAPI, :8001) ──► redis (кеш)
                                         └──────► tasks-service (HTTP)
```

| Сервіс | Що робить | Технології |
|---|---|---|
| `tasks-service` | CRUD API для задач (створити, список, відмітити, видалити) | Python, FastAPI, SQLAlchemy |
| `stats-service` | Рахує статистику задач, кешує результат на 5 с | Python, FastAPI, httpx, Redis |
| `frontend` | Вебсторінка + проксі на API | nginx, HTML/JS |
| `db` | Зберігає задачі | PostgreSQL 16 |
| `redis` | Кеш для статистики | Redis 7 |

## Як це відповідає завданню

1. **Проєкт**: вебзастосунок, працює з БД (PostgreSQL) та інфраструктурним елементом (Redis), має тести, складається з кількох частин.
2. **Dockerfile**: окремий для кожної частини: `tasks-service/Dockerfile`, `stats-service/Dockerfile`, `frontend/Dockerfile`.
3. **docker-compose.yml**: піднімає весь проєкт однією командою (5 контейнерів).
4. **GitHub**: інструкція нижче.

## Запуск

Потрібен встановлений [Docker Desktop](https://www.docker.com/products/docker-desktop/).

```bash
docker compose up --build
```

Після запуску:
- Застосунок: http://localhost:8080
- Swagger-документація tasks-service: http://localhost:8000/docs
- Swagger-документація stats-service: http://localhost:8001/docs

Зупинити: `Ctrl+C` або `docker compose down` (з `-v`, щоб видалити і дані бази).

## Тести

Запуск тестів усередині контейнерів:

```bash
docker compose run --rm tasks-service pytest -v
docker compose run --rm stats-service pytest -v
```

Або локально без Docker:

```bash
cd tasks-service && pip install -r requirements.txt && pytest -v
```

- `tasks-service/tests`: 6 тестів API (SQLite у пам'яті замість Postgres).
- `stats-service/tests`: 4 тести (підрахунок статистики, кешування через fakeredis).

## Корисні команди Docker

```bash
docker compose ps                    # які контейнери запущені
docker compose logs -f tasks-service # логи сервісу
docker compose exec db psql -U app -d tasks -c "select * from tasks;"  # заглянути в БД
docker images                        # зібрані образи
```

## Заливка на GitHub

1. Створити порожній репозиторій на https://github.com/new (без README).
2. У папці проєкту:

```bash
git init
git add .
git commit -m "Lab 1: dockerized microservices app"
git branch -M main
git remote add origin https://github.com/<твій-логін>/lab1-devops.git
git push -u origin main
```
