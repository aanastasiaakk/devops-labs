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
kubectl -n ingress-nginx wait --for=condition=ready pod -l app.kubernetes.io/component=controller --timeout=180s

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

---

# Лабораторна робота №4 — Пакування застосунку в Helm-чарт

Маніфести з `k8s/` (лаба №3) переписано у власний Helm-чарт `charts/task-manager/`. Чарт розгортає той самий застосунок і той самий набір об'єктів, але всі змінні параметри винесено у значення, тож один чарт обслуговує кілька середовищ.

## Структура чарта

```
charts/task-manager/
├── Chart.yaml              # ім'я, опис, version, appVersion
├── values.yaml             # значення за замовчуванням (= dev)
├── values-dev.yaml         # середовище розробки
├── values-prod.yaml        # середовище prod
├── .helmignore
└── templates/
    ├── _helpers.tpl        # іменовані шаблони: імена об'єктів, мітки, образ
    ├── NOTES.txt           # підказка після встановлення
    ├── configmap.yaml      # ← k8s/01-configmap.yaml (+ конфіг nginx)
    ├── secret.yaml         # ← k8s/02-secret.yaml
    ├── postgres-pvc.yaml   # ← k8s/10-postgres-pvc.yaml   (postgresql.persistence.enabled)
    ├── postgres-deployment.yaml, postgres-service.yaml
    ├── redis-deployment.yaml, redis-service.yaml
    ├── tasks-deployment.yaml, tasks-service.yaml
    ├── stats-deployment.yaml, stats-service.yaml
    ├── frontend-deployment.yaml, frontend-service.yaml
    ├── ingress.yaml        # ← k8s/60-ingress.yaml       (ingress.enabled)
    ├── hooks/pre-upgrade-db-check.yaml   # хук pre-upgrade (завдання 9b)
    └── tests/test-app.yaml               # тест релізу для helm test (завдання 9b)
```

`k8s/00-namespace.yaml` у чарт не перенесено: namespace створює команда `helm install --create-namespace`. Helm не рекомендує описувати в чарті namespace, у який ставиться сам реліз.

## version і appVersion

| Поле | Значення | Що означає в цьому проєкті |
|---|---|---|
| `version` | `0.1.0` | Версія **чарта**: шаблонів, values, хуків. Збільшується, коли змінюємо сам чарт (додали параметр, виправили шаблон), навіть якщо код застосунку не змінився. |
| `appVersion` | `1.1.0` | Версія **застосунку**, тобто тег образів `tasks-service`, `stats-service`, `frontend` у GHCR (CI публікує їх за git-тегами `v1.0.0`, `v1.1.0`). Якщо `image.tag` порожній, чарт бере саме цей тег. |

Наприклад, якщо виправити помилку в шаблоні без зміни коду, отримаємо `version: 0.1.1`, а `appVersion` лишиться `1.1.0`. Якщо вийде новий образ `1.2.0`, буде `appVersion: "1.2.0"` і нова версія чарта.

## Імена об'єктів

Імена будуються з імені релізу (шаблон `task-manager.fullname` у `_helpers.tpl`):

| Реліз | Приклад імен |
|---|---|
| `task-manager` | `task-manager-tasks-service`, `task-manager-postgres`, `task-manager-config` |
| `demo-copy` | `demo-copy-task-manager-tasks-service`, `demo-copy-task-manager-postgres`, … |

Тому чарт можна встановити двічі в один кластер і навіть в один namespace. Адреси сервісів у ConfigMap і конфіг nginx для frontend теж генеруються з цих імен.

## Параметри values

| Параметр | За замовчуванням (dev) | prod | Опис |
|---|---|---|---|
| `image.tag` | `1.1.0` | `1.0.0` | Спільний тег образів трьох сервісів (`""` → `appVersion`) |
| `image.pullPolicy` | `IfNotPresent` | | Політика завантаження образів |
| `tasksService.replicaCount` | `1` | `3` | Кількість реплік tasks-service |
| `tasksService.image.repository` | `ghcr.io/aanastasiaakk/devops-labs/tasks-service` | | Репозиторій образу |
| `tasksService.image.tag` | `""` | | Окремий тег лише для цього сервісу |
| `tasksService.containerPort` | `8000` | | Порт застосунку в контейнері |
| `tasksService.service.type` / `.port` | `ClusterIP` / `8000` | | Тип і порт Service |
| `tasksService.resources` | 50m/96Mi → 250m/192Mi | 100m/128Mi → 500m/256Mi | requests → limits |
| `statsService.replicaCount` | `1` | `2` | Кількість реплік stats-service |
| `statsService.image.repository` / `.tag` | `…/stats-service` / `""` | | Образ |
| `statsService.service.type` / `.port` | `ClusterIP` / `8001` | | Тип і порт Service |
| `statsService.resources` | 25m/64Mi → 150m/128Mi | 50m/96Mi → 300m/192Mi | requests → limits |
| `frontend.replicaCount` | `1` | `2` | Кількість реплік frontend |
| `frontend.image.repository` / `.tag` | `…/frontend` / `""` | | Образ |
| `frontend.service.type` / `.port` | `ClusterIP` / `80` | | Тип і порт Service |
| `frontend.resources` | 25m/32Mi → 100m/64Mi | 50m/32Mi → 200m/64Mi | requests → limits |
| `postgresql.image.repository` / `.tag` | `postgres` / `16-alpine` | | Образ бази |
| `postgresql.replicaCount` | `1` | | Має лишатися 1 (диск ReadWriteOnce) |
| `postgresql.database` / `.username` | `tasks` / `app` | | Назва бази і користувач |
| `postgresql.password` | `""` | `""` | Порожній → випадковий пароль при встановленні, при оновленнях той самий. Не записувати у файли, лише `--set` |
| `postgresql.service.port` | `5432` | | Порт Service бази |
| `postgresql.persistence.enabled` | `true` | `true` | Створювати PVC (`false` → `emptyDir`) |
| `postgresql.persistence.size` / `.accessMode` / `.storageClass` | `1Gi` / `ReadWriteOnce` / `""` | | Параметри PVC |
| `postgresql.resources` | 50m/128Mi → 250m/256Mi | 100m/256Mi → 500m/512Mi | requests → limits |
| `redis.image.repository` / `.tag` | `redis` / `7-alpine` | | Образ Redis |
| `redis.replicaCount` / `redis.service.port` | `1` / `6379` | | Репліки і порт |
| `redis.resources` | 25m/32Mi → 100m/64Mi | 50m/64Mi → 200m/128Mi | requests → limits |
| `config.cacheTTL` | `5` | `30` | Час життя кешу статистики (CACHE_TTL), с |
| `ingress.enabled` | `false` | `true` | Створювати Ingress |
| `ingress.className` / `.host` / `.path` | `nginx` / `""` / `/` | | Клас контролера, хост (`""` = будь-який), шлях |
| `ingress.annotations` | `{}` | | Додаткові анотації Ingress |
| `hooks.preUpgradeCheck.enabled` | `true` | | Хук pre-upgrade з перевіркою бази |
| `tests.image.repository` / `.tag` | `curlimages/curl` / `8.11.1` | | Образ пода для `helm test` |
| `nameOverride` / `fullnameOverride` | `""` | | Перевизначення імен об'єктів |

## Пріоритет значень

Від найслабшого до найсильнішого:

1. `values.yaml` у чарті (значення за замовчуванням);
2. файли `-f` / `--values` (якщо файлів кілька, перемагає пізніший);
3. прапорці `--set` (перекривають і values.yaml, і файли).

Значення зливаються по ключах: файл `-f` замінює лише ті ключі, які в ньому є, решта береться з `values.yaml`.

```bash
helm template task-manager charts/task-manager -f charts/task-manager/values-prod.yaml \
  --set tasksService.replicaCount=5 --show-only templates/tasks-deployment.yaml | grep replicas
#   replicas: 5     (values.yaml: 1, values-prod.yaml: 3, --set: 5)
```

## Встановлення

Передумови: `brew install helm`, запущений minikube з аддоном ingress (`minikube addons enable ingress`).

```bash
# dev
helm install task-manager ./charts/task-manager -n lab4 --create-namespace \
  -f charts/task-manager/values-dev.yaml

# prod (Ingress, 3 репліки tasks-service, стабільна версія 1.0.0)
helm install task-manager ./charts/task-manager -n lab4-prod --create-namespace \
  -f charts/task-manager/values-prod.yaml

# Те саме з власним паролем бази (пароль лише в командному рядку, не у файлі)
helm install task-manager ./charts/task-manager -n lab4-prod --create-namespace \
  -f charts/task-manager/values-prod.yaml --set postgresql.password="$DB_PASSWORD"
```

Після встановлення Helm виводить `NOTES.txt` з командою, як відкрити застосунок:
- dev: `kubectl -n lab4 port-forward svc/task-manager-frontend 8080:80` → http://localhost:8080
- prod: `minikube tunnel` → http://127.0.0.1

## Основні команди

```bash
helm lint charts/task-manager -f charts/task-manager/values-prod.yaml      # перевірка чарта
helm template task-manager charts/task-manager -f charts/task-manager/values-dev.yaml   # маніфести без встановлення
helm list -n lab4                                  # релізи
helm status task-manager -n lab4                   # статус
helm get values task-manager -n lab4 [--all]       # значення релізу
helm upgrade task-manager charts/task-manager -n lab4 -f charts/task-manager/values-dev.yaml --set image.tag=1.0.0
helm history task-manager -n lab4                  # ревізії
helm rollback task-manager 1 -n lab4               # відкат до ревізії 1
helm test task-manager -n lab4                     # тест релізу
helm uninstall task-manager -n lab4                # видалення
kubectl -n lab4 get secrets -l owner=helm          # де Helm зберігає стан релізу
```

## Хук і тест (завдання 9b)

- **`templates/hooks/pre-upgrade-db-check.yaml`** — Job з анотацією `helm.sh/hook: pre-upgrade`. Перед кожним `helm upgrade` він перевіряє, що PostgreSQL доступна, і виводить кількість задач у базі. Якщо Job падає, Helm скасовує оновлення, і реліз лишається на попередній ревізії. Після успіху Helm видаляє Job сам (`hook-delete-policy: before-hook-creation,hook-succeeded`).
- **`templates/tests/test-app.yaml`** — под з анотацією `helm.sh/hook: test`. Команда `helm test` запускає його, і под через frontend перевіряє весь ланцюжок: сторінку, `/api/tasks` (tasks-service + база), `/api/stats` (stats-service + Redis) і `/api/version`.

## Демонстрація

```bash
./scripts/lab4-demo.sh check     # без кластера: lint, різниця dev/prod, пріоритет значень, порівняння з лабою №3
./scripts/lab4-demo.sh cluster   # install, upgrade (--set і prod), history, rollback, test, uninstall
```

Вивід кожного етапу зберігається в `report/lab4/`.

---

# Лабораторна робота №5 — GitOps: розгортання через Argo CD

Розгортання переведено з ручного `helm upgrade --install` на GitOps: бажаний стан кластера описаний у Git,
а Argo CD у кластері сам приводить кластер до нього. Обрано варіант **b**: конфігурація лежить у цьому ж
репозиторії (`aanastasiaakk/devops-labs`, публічний, тож `argocd repo add` не потрібен).

## Структура

```
bootstrap/root.yaml           # кореневий Application (App of Apps), застосовується вручну ОДИН раз
argocd-apps/task-manager.yaml # Application для чарту, ним керує root
charts/task-manager/          # чарт з ЛР-4 (перенесено з chart/)
  values-minikube.yaml        # значення для minikube: тег образів, репліки, existingSecret
scripts/lab5-demo.sh          # демонстрація всіх пунктів по етапах, вивід у report/lab5/
```

- **CI** (`.github/workflows/ci.yml`): `on.push.paths-ignore` для `bootstrap/`, `argocd-apps/`, `charts/` —
  зміна тегу в Git не запускає збірку образів. Push тегу `v*` збирає образи завжди (на теги фільтр шляхів не діє).
- **Секрети**: у `values-minikube.yaml` задано `existingSecret: task-manager-db`, тож шаблон Secret не рендериться,
  а Deployment-и беруть пароль із Secret, створеного вручну (`./scripts/lab5-demo.sh secret`). Пароля в Git немає,
  і Argo CD не видаляє цей Secret навіть з `prune`, бо він не з Git.
- **Хуки ЛР-4**: `pre-upgrade` Argo CD перетворює на `PreSync` і запускав би перед кожною синхронізацією, зокрема першою,
  коли бази ще немає; хук `test` Argo CD не підтримує. Для minikube обидва вимкнено у values.
- **progressDeadlineSeconds: 90** — Deployment з неіснуючим образом за 90 с стає невдалим, і Argo CD показує `Degraded`.

## Версія застосунку

- `GET /version` у tasks-service (з 1.2.0) і поле `version` у `/health` (усі версії).
- Через фронтенд: `curl localhost:8081/api/version`; з 1.2.0 версія видна на сторінці зеленою міткою біля заголовка.
- Версію в образ вшиває CI з git-тегу (`--build-arg APP_VERSION`): тег `v1.2.0` → образи `ghcr.io/aanastasiaakk/devops-labs/*:1.2.0`.

## Порядок виконання

```bash
./scripts/lab5-demo.sh check       # helm lint/template з values-minikube.yaml
./scripts/lab5-demo.sh argocd      # minikube, Argo CD у namespace argocd, CLI, новий пароль admin
./scripts/lab5-demo.sh secret      # Secret з паролем БД
./scripts/lab5-demo.sh bootstrap   # kubectl apply -f bootstrap/root.yaml -> Synced / Healthy
./scripts/lab5-demo.sh release     # tag 1.1.0 -> 1.2.0: commit + push, Argo CD перерозгортає сам
./scripts/lab5-demo.sh drift       # kubectl scale без selfHeal -> OutOfSync, 5 реплік лишаються
./scripts/lab5-demo.sh selfheal    # selfHeal: true комітом -> kubectl scale повертається до 2
./scripts/lab5-demo.sh degraded    # tag 9.9.9 -> Synced + Degraded (ImagePullBackOff)
./scripts/lab5-demo.sh revert      # git revert -> Healthy; git log і argocd app history
./scripts/lab5-demo.sh ui          # port-forward: Argo CD на 8080, застосунок на 8081
```

Відкат робиться комітом (`git revert`), а не `argocd app rollback`: з увімкненою автосинхронізацією Argo CD
одразу повернув би стан із Git.
