# Лабораторна робота №1 — Віртуалізація та контейнеризація

[![CI](https://github.com/aanastasiaakk/devops-labs/actions/workflows/ci.yml/badge.svg)](https://github.com/aanastasiaakk/devops-labs/actions/workflows/ci.yml)

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

---

# Лабораторна робота №2 — Continuous Integration

CI налаштовано в **GitHub Actions**: `.github/workflows/ci.yml`.

## Коли запускається
- кожна зміна в Pull Request у `main`;
- push у `main` або `develop`;
- вручну з вкладки **Actions** (`workflow_dispatch`).

## Завдання (jobs)

```
Lint (tasks-service) ─┐
Lint (stats-service) ─┤
Lint (frontend) ──────┤
Build & Test (tasks-service) ─┼──► Docker image (tasks-service)
Build & Test (stats-service) ─┤    Docker image (stats-service)
Build & Test (frontend) ──────┘    Docker image (frontend)
```

| Job | Кроки |
|---|---|
| Lint | Ruff (`ruff check` + `ruff format --check`) для Python, HTMLHint для фронтенду |
| Build & Test (Python) | встановлення залежностей з кешем pip → `compileall` → `pytest` |
| Build & Test (frontend) | перевірка конфігу `nginx -t` → запуск nginx і перевірка, що сторінка віддається |
| Docker image | збирання образу з Dockerfile → сканування Trivy (HIGH/CRITICAL) → публікація в GHCR (тільки push) |

- Однотипні сервіси об'єднано через `matrix`, `fail-fast: false` — падіння одного не скасовує інші.
- Lint і тести — блокуючі: будь-яка помилка робить статус PR червоним.
- Образи: `ghcr.io/aanastasiaakk/devops-labs/<service>`, теги `sha-<commit>` і `latest` (тільки для `main`).
- Авторизація в реєстрі — через вбудований секрет `GITHUB_TOKEN`, паролів у репозиторії немає.

## Перевірка опублікованого образу

```bash
docker pull ghcr.io/aanastasiaakk/devops-labs/stats-service:latest
docker run --rm -p 8001:8001 ghcr.io/aanastasiaakk/devops-labs/stats-service:latest
# http://localhost:8001/health -> {"status":"ok"}
```

## Лінтер локально

```bash
pip install ruff==0.8.4
cd tasks-service && ruff check . && ruff format --check .
```

---

# Лабораторна робота №3 — Розгортання в Kubernetes

Застосунок описано маніфестами Kubernetes у каталозі [`k8s/`](k8s/) (один файл на об'єкт) і розгорнуто в локальному кластері **minikube**.

## Об'єкти

| Файл | Об'єкт | Призначення |
|---|---|---|
| `00-namespace.yaml` | Namespace `task-manager` | окремий простір імен для всіх об'єктів проєкту |
| `01-configmap.yaml` | ConfigMap `app-config` | несекретні параметри |
| `02-secret.yaml` | Secret `app-secret` | пароль і рядок підключення до БД |
| `10-postgres-pvc.yaml` | PersistentVolumeClaim `postgres-data` | постійне сховище PostgreSQL (1Gi) |
| `11-postgres-deployment.yaml` | Deployment `postgres` | база даних (1 репліка, стратегія Recreate) |
| `12-postgres-service.yaml` | Service `postgres` (ClusterIP) | `postgres:5432` |
| `20-redis-deployment.yaml` | Deployment `redis` | кеш |
| `21-redis-service.yaml` | Service `redis` (ClusterIP) | `redis:6379` |
| `30-tasks-deployment.yaml` | Deployment `tasks-service` | API задач, 2 репліки, rolling update |
| `31-tasks-service.yaml` | Service `tasks-service` (ClusterIP) | `tasks-service:8000` |
| `40-stats-deployment.yaml` | Deployment `stats-service` | статистика, 2 репліки |
| `41-stats-service.yaml` | Service `stats-service` (ClusterIP) | `stats-service:8001` |
| `50-frontend-deployment.yaml` | Deployment `frontend` | nginx + сторінка, 2 репліки |
| `51-frontend-service.yaml` | Service `frontend` (ClusterIP) | `frontend:80` |
| `60-ingress.yaml` | Ingress `task-manager` | доступ з хоста: `/` → `frontend:80` |

Кожен Deployment має узгоджені `labels`/`selector`, `requests`/`limits` для CPU і пам'яті, `livenessProbe` і `readinessProbe`.
У tasks-service readiness-проба `/ready` перевіряє з'єднання з базою, liveness-проба `/health` — що процес живий.
Сервіси застосунку оновлюються стратегією `RollingUpdate` з `maxSurge: 1`, `maxUnavailable: 0` — без простою.
init-контейнер `wait-for-postgres` у tasks-service чекає готовності бази перед стартом API.
Хук `preStop` (`sleep 10`) дає старому поду дообслужити запити, поки його прибирають з маршрутизації, тому під час оновлення не губиться жоден запит.

## Параметри конфігурації

**ConfigMap `app-config`**

| Ключ | Значення | Хто використовує |
|---|---|---|
| `POSTGRES_DB` | `tasks` | postgres |
| `POSTGRES_USER` | `app` | postgres |
| `TASKS_URL` | `http://tasks-service:8000` | stats-service |
| `REDIS_URL` | `redis://redis:6379/0` | stats-service |
| `CACHE_TTL` | `10` (секунд) | stats-service |

**Secret `app-secret`** (навчальні значення, не від реальних систем)

| Ключ | Хто використовує |
|---|---|
| `POSTGRES_PASSWORD` | postgres |
| `DATABASE_URL` | tasks-service |

## Версії образів

Образи публікуються в GitHub Container Registry пайплайном CI за git-тегами:
`git tag v1.0.0 && git push origin v1.0.0` → `ghcr.io/aanastasiaakk/devops-labs/<service>:1.0.0` (аналогічно `v1.1.0` → `1.1.0`).
Образи мультиплатформні (`linux/amd64`, `linux/arm64`), тег `latest` у маніфестах не використовується.
Версія передається при збиранні (`--build-arg APP_VERSION=...`) і видна у відповіді `/api/version` разом з іменем пода.

## Порядок розгортання

```bash
# 1. Кластер
minikube start --driver=docker --cpus=2 --memory=4096
minikube addons enable metrics-server
minikube addons enable ingress

# 2. Образи завантажуються з GHCR автоматично під час розгортання.
#    Запасний варіант без інтернету - зібрати локально:  LOCAL_IMAGES=1 ./scripts/lab3-demo.sh

# 3. Розгортання однією командою
kubectl apply -f k8s/
kubectl -n task-manager get pods,deploy,rs,svc,ingress,pvc

# 4. Доступ з браузера (в окремому терміналі), потім http://127.0.0.1
minikube tunnel
```

## Демонстрація

Скрипт [`scripts/lab3-demo.sh`](scripts/lab3-demo.sh) виконує всі етапи (кластер, образи, розгортання, самовідновлення, масштабування, rolling update, відкат, діагностика ImagePullBackOff) і зберігає вивід команд у [`report/`](report/).

```bash
./scripts/lab3-demo.sh
```

Видалити все: `kubectl delete namespace task-manager`.
