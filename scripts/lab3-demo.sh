#!/usr/bin/env bash
# Лабораторна №3: розгортання Task Manager у minikube і демонстрація керування життєвим циклом.
# Запуск з кореня проєкту:  ./scripts/lab3-demo.sh
# Вивід кожного етапу зберігається в report/ (для звіту, пункти 5-7).
set -euo pipefail

NS=task-manager
REG=ghcr.io/aanastasiaakk/devops-labs
OUT=report
PORT=8080
URL="http://localhost:$PORT"
mkdir -p "$OUT"

title() { printf '\n\n========== %s ==========\n' "$1"; }
run()   { printf '\n$ %s\n' "$*"; "$@"; }
version_probe() { curl -s "$URL/api/version"; echo; }

# ---------------------------------------------------------------- 2. Кластер
{
  title "2. Локальний кластер minikube"
  if ! minikube status >/dev/null 2>&1; then
    run minikube start --driver=docker --cpus=2 --memory=4096
  fi
  run minikube addons enable metrics-server
  run minikube addons enable ingress
  run kubectl get nodes -o wide
  run kubectl get pods -n kube-system
} 2>&1 | tee "$OUT/02-cluster.txt"

# ---------------------------------------------------------------- 1. Образи
# За замовчуванням кластер сам завантажує образи 1.0.0 / 1.1.0 з GHCR (їх публікує CI за git-тегами v1.0.0 / v1.1.0).
# Запасний варіант без інтернету: LOCAL_IMAGES=1 ./scripts/lab3-demo.sh - зібрати образи локально і завантажити в minikube.
if [ "${LOCAL_IMAGES:-0}" = "1" ]; then
{
  title "1. Локальне збирання двох версій образів і завантаження в minikube"
  for V in 1.0.0 1.1.0; do
    run docker buildx build --load -q --build-arg APP_VERSION=$V -t $REG/tasks-service:$V ./tasks-service
    run docker buildx build --load -q --build-arg APP_VERSION=$V -t $REG/stats-service:$V ./stats-service
    run docker buildx build --load -q -t $REG/frontend:$V ./frontend
    for SVC in tasks-service stats-service frontend; do
      run minikube image load --overwrite=true $REG/$SVC:$V
    done
  done
  printf '\n$ minikube image ls | grep devops-labs\n'
  minikube image ls | grep devops-labs | sort
} 2>&1 | tee "$OUT/01-images.txt"
fi

# ---------------------------------------------------------------- 5. Розгортання
{
  title "5a. Застосування всіх маніфестів однією командою (з нуля)"
  # Прибираємо результат попереднього запуску, щоб розгортання йшло на чистому namespace
  if kubectl get namespace $NS >/dev/null 2>&1; then
    run kubectl delete namespace $NS --wait=true
  fi
  run kubectl apply -f k8s/
  run kubectl -n $NS wait --for=condition=available deployment --all --timeout=300s
  title "1. Образи, які кластер завантажив (тег версії, не latest)"
  run kubectl -n $NS get pods -o custom-columns='POD:.metadata.name,IMAGE:.spec.containers[0].image'
  printf '\n$ kubectl get events | grep Pulled\n'
  kubectl -n $NS get events --sort-by=.lastTimestamp | grep -E "Pulled|Pulling" | grep devops-labs | head -6 || true

  title "5b. Створені об'єкти"
  run kubectl -n $NS get pods,deployments,replicasets,services,ingress,pvc,configmaps,secrets -o wide
} 2>&1 | tee "$OUT/05-deploy.txt"

# Доступ до застосунку з хоста для перевірок у скрипті (браузер - через minikube tunnel)
kubectl -n $NS port-forward svc/frontend $PORT:80 >/dev/null 2>&1 &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do curl -sf "$URL/" >/dev/null && break; sleep 1; done

{
  title "5c. Застосунок відповідає"
  run curl -s -o /dev/null -w 'GET / -> HTTP %{http_code}\n' "$URL/"
  printf '\n$ curl -X POST %s/api/tasks\n' "$URL"
  curl -s -X POST "$URL/api/tasks" -H 'Content-Type: application/json' -d '{"title":"Перевірка з Kubernetes"}'; echo
  printf '\n$ curl %s/api/tasks\n' "$URL"; curl -s "$URL/api/tasks"; echo
  printf '\n$ curl %s/api/stats\n' "$URL"; curl -s "$URL/api/stats"; echo
  title "5d. Значення з ConfigMap і Secret у контейнерах"
  printf '\n$ kubectl exec deploy/stats-service -- env | grep -E "TASKS_URL|REDIS_URL|CACHE_TTL"\n'
  kubectl -n $NS exec deploy/stats-service -- env | grep -E "TASKS_URL|REDIS_URL|CACHE_TTL"
  printf '\n$ kubectl exec deploy/tasks-service -- printenv DATABASE_URL\n'
  kubectl -n $NS exec deploy/tasks-service -- printenv DATABASE_URL
  printf '\n$ kubectl exec deploy/postgres -- printenv POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD\n'
  kubectl -n $NS exec deploy/postgres -- printenv POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD
} 2>&1 | tee "$OUT/05-app.txt"

# ---------------------------------------------------------------- 6. Життєвий цикл
{
  title "6a. Самовідновлення: видаляємо под tasks-service"
  run kubectl -n $NS get pods -l app=tasks-service
  VICTIM=$(kubectl -n $NS get pods -l app=tasks-service -o jsonpath='{.items[0].metadata.name}')
  run kubectl -n $NS delete pod "$VICTIM"
  run kubectl -n $NS wait --for=condition=available deployment/tasks-service --timeout=120s
  sleep 3
  run kubectl -n $NS get pods -l app=tasks-service

  title "6b. Масштабування до 4 реплік і розподіл трафіку"
  run kubectl -n $NS scale deployment tasks-service --replicas=4
  run kubectl -n $NS rollout status deployment/tasks-service --timeout=120s
  run kubectl -n $NS get pods -l app=tasks-service -o wide
  sleep 5   # даємо kube-proxy час додати нові поди в маршрутизацію сервісу
  printf '\n60 запитів до /api/version - які поди відповідали:\n'
  for _ in $(seq 1 60); do curl -s "$URL/api/version" | sed -E 's/.*"pod":"([^"]+)".*/\1/'; echo; done | sort | uniq -c
} 2>&1 | tee "$OUT/06ab-selfheal-scale.txt"

{
  title "6c/6e. Rolling update 1.0.0 -> 1.1.0 під безперервним навантаженням"
  LOG="$OUT/06ce-requests.log"; : > "$LOG"
  ( while true; do
      printf '%s %s\n' "$(date +%T)" "$(curl -s -m 2 -w ' HTTP=%{http_code}' "$URL/api/version" || true)" >> "$LOG"
      sleep 0.3
    done ) &
  LOAD_PID=$!
  sleep 2
  run kubectl -n $NS set image deployment/tasks-service tasks-service=$REG/tasks-service:1.1.0
  run kubectl -n $NS annotate deployment/tasks-service kubernetes.io/change-cause="update image to 1.1.0" --overwrite
  run kubectl -n $NS rollout status deployment/tasks-service --timeout=180s
  sleep 3
  kill $LOAD_PID 2>/dev/null || true; wait $LOAD_PID 2>/dev/null || true
  run kubectl -n $NS get pods -l app=tasks-service
  run kubectl -n $NS get replicasets -l app=tasks-service
  printf '\nЗапитів під час оновлення: %s\n' "$(wc -l < "$LOG" | tr -d ' ')"
  printf 'Успішних (HTTP 200): %s\n' "$(grep -c 'HTTP=200' "$LOG" || true)"
  printf 'Невдалих: %s\n' "$(grep -vc 'HTTP=200' "$LOG" || true)"
  printf 'Версії у відповідях:\n'; sed -E 's/.*"version":"([^"]+)".*/\1/' "$LOG" | grep -E '^[0-9]' | sort | uniq -c
  printf '\nПерехід версій (перші і останні рядки журналу):\n'; head -3 "$LOG"; echo '...'; tail -3 "$LOG"

  title "6d. Історія оновлень і відкат"
  run kubectl -n $NS rollout history deployment/tasks-service
  run kubectl -n $NS rollout undo deployment/tasks-service
  run kubectl -n $NS annotate deployment/tasks-service kubernetes.io/change-cause="rollback to 1.0.0" --overwrite
  run kubectl -n $NS rollout status deployment/tasks-service --timeout=180s
  run kubectl -n $NS rollout history deployment/tasks-service
  printf '\nВерсія після відкату: '; version_probe
} 2>&1 | tee "$OUT/06cde-update-rollback.txt"

# ---------------------------------------------------------------- 7. Діагностика
{
  title "7a. Неіснуючий тег образу 9.9.9"
  run kubectl -n $NS set image deployment/tasks-service tasks-service=$REG/tasks-service:9.9.9
  printf '\nЧекаємо, поки kubelet спробує завантажити образ...\n'
  BAD=""
  for _ in $(seq 1 30); do
    BAD=$(kubectl -n $NS get pods -l app=tasks-service \
          -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' \
          | awk '$2 ~ /ImagePullBackOff/ {print $1; exit}')
    [ -n "$BAD" ] && break
    sleep 3
  done
  run kubectl -n $NS get pods -l app=tasks-service
  printf '\nПод з помилкою: %s\n' "$BAD"
  printf 'Старі поди продовжують обслуговувати запити (maxUnavailable: 0): '; version_probe

  title "7b. Причина: опис пода і події"
  run kubectl -n $NS describe pod "$BAD"
  run kubectl -n $NS get events --field-selector involvedObject.name="$BAD" --sort-by=.lastTimestamp

  title "7c. Логи контейнера і команди всередині контейнера"
  run kubectl -n $NS logs deploy/tasks-service --tail=15
  run kubectl -n $NS exec deploy/tasks-service -- sh -c 'echo "hostname: $(hostname)"; echo "APP_VERSION=$APP_VERSION"; ls /app; python --version'
  printf '\n(Інтерактивний вхід: kubectl -n %s exec -it deploy/tasks-service -- sh)\n' "$NS"

  title "7d. Виправлення: повертаємо існуючий тег 1.1.0"
  run kubectl -n $NS set image deployment/tasks-service tasks-service=$REG/tasks-service:1.1.0
  run kubectl -n $NS annotate deployment/tasks-service kubernetes.io/change-cause="fix: back to existing tag 1.1.0" --overwrite
  run kubectl -n $NS rollout status deployment/tasks-service --timeout=180s
  run kubectl -n $NS get pods -l app=tasks-service
  printf '\nВерсія: '; version_probe

  title "Підсумок"
  run kubectl -n $NS scale deployment tasks-service --replicas=2
  run kubectl -n $NS rollout status deployment/tasks-service --timeout=120s
  run kubectl -n $NS get pods,deployments,services,ingress,pvc
  run kubectl -n $NS top pods || true
} 2>&1 | tee "$OUT/07-diagnostics.txt"

printf '\nГотово. Вивід усіх етапів збережено в %s/\n' "$OUT"
printf 'Відкрити застосунок у браузері: в окремому терміналі "minikube tunnel", потім http://127.0.0.1\n'
