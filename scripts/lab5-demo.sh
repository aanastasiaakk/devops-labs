#!/usr/bin/env bash
# Лабораторна №5: GitOps-розгортання Task Manager через Argo CD.
#
# Запуск з кореня репозиторію, по етапах (кожен етап = пункт лабораторної):
#   ./scripts/lab5-demo.sh check      # п.1   перевірка чарту і values-minikube.yaml без кластера
#   ./scripts/lab5-demo.sh argocd     # п.3   minikube + Argo CD + CLI, зміна пароля admin
#   ./scripts/lab5-demo.sh secret     # п.1   Secret з паролем БД (створюється вручну, не з Git)
#   ./scripts/lab5-demo.sh bootstrap  # п.4   kubectl apply -f bootstrap/root.yaml, Synced/Healthy
#   ./scripts/lab5-demo.sh release    # п.5   тег 1.1.0 -> 1.2.0 комітом, Argo CD сам оновлює
#   ./scripts/lab5-demo.sh drift      # п.6a  kubectl scale без selfHeal -> OutOfSync
#   ./scripts/lab5-demo.sh selfheal   # п.6a  selfHeal: true комітом, kubectl scale повертається
#   ./scripts/lab5-demo.sh degraded   # п.6b  неіснуючий тег 9.9.9 -> Synced + Degraded
#   ./scripts/lab5-demo.sh revert     # п.6c  git revert -> Healthy, git log, argocd app history
#   ./scripts/lab5-demo.sh ui         # port-forward до Argo CD (8080) і застосунку (8081) для браузера
#
# Етапи release, selfheal, degraded і revert самі роблять commit і push у main:
# у GitOps саме коміт у Git змінює кластер. Вивід і скриншоти терміналу - у report/lab5/.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=task-manager
NS=task-manager
SECRET=task-manager-db
CHART=charts/task-manager
VALUES=$CHART/values-minikube.yaml
APPFILE=argocd-apps/task-manager.yaml
REG=ghcr.io/aanastasiaakk/devops-labs
ARGO_PORT=8080
APP_PORT=8081
OUT=report/lab5
SHOTS=$OUT/screenshots
STAGE=${1:-help}

mkdir -p "$SHOTS"
LOG=$OUT/$STAGE.txt
if [ "$STAGE" != help ] && [ "$STAGE" != ui ]; then
  : > "$LOG"
  exec > >(tee -a "$LOG") 2>&1
fi

B=$'\033[1;36m'; G=$'\033[1;32m'; Y=$'\033[1;33m'; N=$'\033[0m'
title() { printf '\n%s==================== %s ====================%s\n' "$B" "$*" "$N"; }
run()   { printf '\n%s$ %s%s\n' "$G" "$*" "$N"; "$@"; }
note()  { printf '\n%s# %s%s\n' "$Y" "$*" "$N"; }
pause() { printf '\n%s>>> %s (Enter - далі)%s\n' "$Y" "$*" "$N"; read -r _ </dev/tty; }

# Скриншот вікна терміналу (macOS). Імена файлів = етап і пункт лабораторної.
WID=""
if [ "${TERM_PROGRAM:-}" = "Apple_Terminal" ]; then
  WID=$(osascript -e 'tell application "Terminal" to id of front window' 2>/dev/null || true)
fi
shot() {
  sleep 1
  if [ -n "$WID" ]; then screencapture -x -o -l "$WID" "$SHOTS/$1.png" 2>/dev/null || true
  else screencapture -x "$SHOTS/$1.png" 2>/dev/null || true; fi
  echo "[screenshot $1.png]" >> "$LOG"
}
# Скриншот інтерфейсу Argo CD: відкриває сторінку, чекає, поки ти підготуєш вигляд, знімає весь екран.
ui_shot() {
  local name=$1 path=$2 hint=$3
  open "https://localhost:$ARGO_PORT$path" 2>/dev/null || true
  pause "Браузер: $hint. Коли на екрані потрібний стан"
  screencapture -x "$SHOTS/$name.png" 2>/dev/null || true
  echo "[screenshot $name.png]" >> "$LOG"
}

# ---------------------------------------------------------------- допоміжне
app_state() {   # "<sync>/<health>/<revision>" Application task-manager
  kubectl -n argocd get application "$APP" \
    -o jsonpath='{.status.sync.status}/{.status.health.status}/{.status.sync.revision}' 2>/dev/null || true
}
refresh() {     # те саме, що кнопка Refresh в інтерфейсі: не чекати опитування Git (до 3 хв)
  for a in "$@"; do argocd app get "$a" --refresh >/dev/null 2>&1 || \
    kubectl -n argocd annotate application "$a" argocd.argoproj.io/refresh=normal --overwrite >/dev/null; done
}
wait_state() {  # wait_state <sync> <health> [revision] [timeout]
  local want_sync=$1 want_health=$2 want_rev=${3:-} timeout=${4:-300} t=0 s=""
  printf 'Чекаю на стан %s / %s%s ' "$want_sync" "$want_health" "${want_rev:+ (коміт ${want_rev:0:7})}"
  while [ $t -lt "$timeout" ]; do
    s=$(app_state)
    IFS=/ read -r sync health rev <<<"$s"
    if [ "$sync" = "$want_sync" ] && [ "$health" = "$want_health" ] && { [ -z "$want_rev" ] || [ "$rev" = "$want_rev" ]; }; then
      printf '\n%sOK: %s / %s, коміт %s%s\n' "$G" "$sync" "$health" "${rev:0:7}" "$N"; return 0
    fi
    printf '.'; sleep 5; t=$((t + 5))
  done
  printf '\nНе дочекалась (зараз: %s)\n' "$s"; return 1
}
version_probe() {  # окремий короткий port-forward: старі поди після оновлення зникають
  kubectl -n "$NS" port-forward "svc/$APP-frontend" 18081:80 >/dev/null 2>&1 &
  local pf=$!
  for _ in $(seq 1 20); do curl -sf localhost:18081/ >/dev/null && break; sleep 1; done
  printf '\n%s$ curl localhost:%s/api/version%s\n' "$G" "$APP_PORT" "$N"
  curl -s localhost:18081/api/version; echo
  kill $pf 2>/dev/null || true; wait $pf 2>/dev/null || true
}
current_tag() { sed -n 's/^  tag: "\(.*\)"/\1/p' "$VALUES" | head -1; }
set_tag()     { sed -i '' "s/^  tag: \".*\"/  tag: \"$1\"/" "$VALUES"; }
git_ready() {   # GitOps-коміти робимо в main, з якої читає Argo CD
  local br; br=$(git rev-parse --abbrev-ref HEAD)
  if [ "$br" != main ]; then echo "Потрібна гілка main (зараз $br): git checkout main"; exit 1; fi
  run git pull --ff-only
}
git_push() {    # git_push "<повідомлення>" <файли...>
  local msg=$1; shift
  run git add "$@"
  run git commit -m "$msg"
  run git push
  REV=$(git rev-parse HEAD)
}
image_exists() { docker manifest inspect "$REG/tasks-service:$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------- етапи
case "$STAGE" in

check)
  title "п.1  Репозиторій конфігурації: структура і чарт"
  run find bootstrap argocd-apps "$CHART" -maxdepth 1
  H3=$(brew --prefix helm@3 2>/dev/null || true)
  if [ -n "$H3" ] && [ -x "$H3/bin/helm" ]; then export PATH="$H3/bin:$PATH"; fi
  run helm lint "$CHART" -f "$VALUES"
  helm template "$APP" "$CHART" -n "$NS" -f "$VALUES" > "$OUT/rendered-minikube.yaml"
  note "Що рендерить чарт для Argo CD (kind і ім'я):"
  grep -E '^(kind|  name):' "$OUT/rendered-minikube.yaml" | paste - - | sort | uniq
  note "Secret у Git немає (existingSecret), образи з тегом $(current_tag):"
  grep -c '^kind: Secret' "$OUT/rendered-minikube.yaml" || true
  grep 'image: ghcr' "$OUT/rendered-minikube.yaml" | sort | uniq
  shot 01-check
  ;;

argocd)
  title "п.3  minikube і Argo CD"
  minikube status >/dev/null 2>&1 || run minikube start --driver=docker --cpus=2 --memory=4096
  run kubectl get nodes
  kubectl get namespace argocd >/dev/null 2>&1 || run kubectl create namespace argocd
  run kubectl apply -n argocd --server-side --force-conflicts \
    -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
  note "Чекаю, поки всі компоненти Argo CD запустяться (2-5 хв)"
  run kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=600s
  run kubectl -n argocd wait --for=condition=available deployment --all --timeout=600s
  run kubectl -n argocd get pods
  command -v argocd >/dev/null || run brew install argocd
  run argocd version --client --short
  shot 03a-argocd-pods

  pkill -f "port-forward svc/argocd-server" 2>/dev/null || true
  kubectl -n argocd port-forward svc/argocd-server $ARGO_PORT:443 >/dev/null 2>&1 &
  sleep 3
  if kubectl -n argocd get secret argocd-initial-admin-secret >/dev/null 2>&1; then
    INIT=$(argocd admin initial-password -n argocd | head -1)
    printf '\nПочатковий пароль admin (у лог не пишеться): %s\n' "$INIT" > /dev/tty
    printf '\n%s$ argocd login localhost:%s --username admin --password *** --insecure%s\n' "$G" "$ARGO_PORT" "$N"
    argocd login localhost:$ARGO_PORT --username admin --password "$INIT" --insecure
    note "Зміна пароля admin. Current password: вставити пароль вище; New password: свій новий пароль"
    argocd account update-password
    run kubectl -n argocd delete secret argocd-initial-admin-secret
  else
    note "Початковий пароль уже змінено. Вхід із твоїм паролем:"
    argocd login localhost:$ARGO_PORT --username admin --insecure
  fi
  run argocd account get-user-info
  shot 03b-argocd-login
  ui_shot 03c-argocd-ui / "увійди як admin з новим паролем (попередження про сертифікат: Advanced -> Proceed)"
  ;;

secret)
  title "п.1  Secret з паролем БД (поза Git)"
  if helm list -n "$NS" -q 2>/dev/null | grep -q .; then
    note "У namespace $NS є Helm-реліз з ЛР-4. Два джерела правди не потрібні - видаляю його:"
    run helm uninstall "$APP" -n "$NS"
  fi
  kubectl get namespace "$NS" >/dev/null 2>&1 || run kubectl create namespace "$NS"
  if kubectl -n "$NS" get secret "$SECRET" >/dev/null 2>&1; then
    note "Secret $SECRET уже існує, залишаю (з ним уже ініціалізована база)"
  else
    PW=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)
    printf '\n%s$ kubectl -n %s create secret generic %s --from-literal=POSTGRES_PASSWORD=*** --from-literal=DATABASE_URL=postgresql://app:***@%s-postgres:5432/tasks%s\n' "$G" "$NS" "$SECRET" "$APP" "$N"
    kubectl -n "$NS" create secret generic "$SECRET" \
      --from-literal=POSTGRES_PASSWORD="$PW" \
      --from-literal=DATABASE_URL="postgresql://app:$PW@$APP-postgres:5432/tasks"
    unset PW
  fi
  run kubectl -n "$NS" describe secret "$SECRET"
  shot 01-secret
  ;;

bootstrap)
  title "п.4  App of Apps: єдиний ручний kubectl apply"
  git fetch -q origin
  run git log --oneline -1 origin/main
  run cat bootstrap/root.yaml
  run kubectl apply -f bootstrap/root.yaml
  note "Далі все бере з Git сам Argo CD: root створює Application task-manager з argocd-apps/"
  for _ in $(seq 1 30); do kubectl -n argocd get application "$APP" >/dev/null 2>&1 && break; sleep 2; done
  wait_state Synced Healthy "" 600
  run argocd app list
  run argocd app get "$APP"
  run kubectl -n "$NS" get pods,svc,pvc
  note "Helm-релізу немає: Argo CD використовує Helm лише для рендерингу шаблонів"
  run helm list -n "$NS"
  version_probe
  shot 04-bootstrap
  ui_shot 04a-ui-root /applications/argocd/root "дерево root -> Application task-manager"
  ui_shot 04b-ui-tree /applications/argocd/$APP "дерево об'єктів task-manager, Synced / Healthy"
  ;;

release)
  NEW=${2:-1.2.0}
  title "п.5  Реліз $NEW через Git"
  git_ready
  if ! image_exists "$NEW"; then
    echo "Образу $REG/tasks-service:$NEW ще немає. Спершу: git tag v$NEW && git push origin v$NEW і дочекатися CI."
    exit 1
  fi
  note "Зараз розгорнуто $(current_tag):"
  version_probe
  set_tag "$NEW"
  run git diff
  git_push "Release task-manager $NEW" "$VALUES"
  refresh "$APP"
  note "Argo CD побачив новий коміт: OutOfSync -> автосинхронізація -> нові поди"
  run argocd app get "$APP"
  wait_state Synced Healthy "$REV" 300
  run kubectl -n "$NS" rollout status deployment/$APP-tasks-service --timeout=180s
  run kubectl -n "$NS" get pods -o custom-columns=POD:.metadata.name,IMAGE:.spec.containers[0].image,STATUS:.status.phase
  version_probe
  shot 05-release
  ;;

drift)
  title "п.6a  Дрейф без selfHeal"
  run grep -n selfHeal "$APPFILE"
  run kubectl -n "$NS" scale deployment "$APP-tasks-service" --replicas=5
  sleep 10; refresh "$APP"; sleep 3
  run argocd app get "$APP"
  run kubectl -n "$NS" get deployment "$APP-tasks-service"
  note "OutOfSync, але реплік лишається 5: без selfHeal Argo CD лише показує розбіжність"
  shot 06a-drift
  ui_shot 06a-ui-outofsync /applications/argocd/$APP "OutOfSync на Deployment tasks-service (кнопка DIFF показує replicas 5 проти 2)"
  ;;

selfheal)
  title "п.6a  selfHeal: true комітом"
  git_ready
  sed -i '' 's/selfHeal: false .*/selfHeal: true               # ЛР-5 п.6a: ручні зміни в кластері Argo CD повертає до стану з Git/' "$APPFILE"
  run git diff
  git_push "Enable selfHeal for task-manager" "$APPFILE"
  refresh root
  note "root застосовує зміну Application сам; Argo CD одразу повертає 2 репліки замість 5"
  for _ in $(seq 1 30); do
    [ "$(kubectl -n argocd get application "$APP" -o jsonpath='{.spec.syncPolicy.automated.selfHeal}')" = true ] && break; sleep 2
  done
  wait_state Synced Healthy "" 180
  run kubectl -n "$NS" get deployment "$APP-tasks-service"
  note "Ще раз змінюю кластер вручну:"
  run kubectl -n "$NS" scale deployment "$APP-tasks-service" --replicas=5
  for i in 1 2 3 4 5 6; do sleep 3; kubectl -n "$NS" get deployment "$APP-tasks-service" --no-headers; done
  run argocd app get "$APP"
  shot 06a-selfheal
  ;;

degraded)
  title "п.6b  Неіснуючий тег: Synced, але Degraded"
  git_ready
  set_tag 9.9.9
  run git diff
  git_push "Release task-manager 9.9.9 (тег не існує)" "$VALUES"
  refresh "$APP"
  note "Маніфест у кластері = маніфест у Git (Synced), але нові поди не можуть завантажити образ"
  wait_state Synced Progressing "$REV" 120 || true
  run kubectl -n "$NS" get pods
  note "Через progressDeadlineSeconds (90 с) Deployment позначається як невдалий -> Degraded"
  wait_state Synced Degraded "$REV" 240
  run argocd app get "$APP"
  run kubectl -n "$NS" get pods
  version_probe
  note "Старі поди продовжують відповідати (maxUnavailable: 0), користувачі не постраждали"
  shot 06b-degraded
  ui_shot 06b-ui-degraded /applications/argocd/$APP "Synced + Degraded, поди ImagePullBackOff"
  ;;

revert)
  title "п.6c  Відкат комітом: git revert"
  git_ready
  BAD=$(git log --format=%H --grep="9.9.9" -1)
  run git log --oneline -6
  run git revert --no-edit "$BAD"
  run git push
  REV=$(git rev-parse HEAD)
  refresh "$APP"
  wait_state Synced Healthy "$REV" 300
  run git log --oneline -6
  run argocd app history "$APP"
  run kubectl -n "$NS" get pods
  version_probe
  shot 06c-revert
  ui_shot 06c-ui-history /applications/argocd/$APP "Synced / Healthy; кнопка HISTORY AND ROLLBACK - кожна синхронізація прив'язана до коміту"
  ;;

ui)
  pkill -f "port-forward svc/argocd-server" 2>/dev/null || true
  pkill -f "port-forward svc/$APP-frontend" 2>/dev/null || true
  nohup kubectl -n argocd port-forward svc/argocd-server $ARGO_PORT:443 >/dev/null 2>&1 &
  nohup kubectl -n "$NS" port-forward svc/$APP-frontend $APP_PORT:80 >/dev/null 2>&1 &
  sleep 2
  echo "Argo CD:   https://localhost:$ARGO_PORT  (admin / твій пароль)"
  echo "Застосунок: http://localhost:$APP_PORT   (після оновлення подів перезапусти: ./scripts/lab5-demo.sh ui)"
  ;;

*)
  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
  ;;
esac
