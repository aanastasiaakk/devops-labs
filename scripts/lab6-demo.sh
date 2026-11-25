#!/usr/bin/env bash
# Лабораторна №6: progressive delivery (canary) з Argo Rollouts під керуванням Argo CD.
#
# Продовження ЛР-5: той самий кластер minikube, Argo CD і root (App of Apps).
# Запуск з кореня репозиторію, по етапах (кожен етап = пункт лабораторної):
#   ./scripts/lab6-demo.sh check       # п.2-3 helm lint/template: Rollout замість Deployment, стратегія canary
#   ./scripts/lab6-demo.sh images      # п.4   образи 1.3.0, 1.4.0, 1.5.0 у GHCR (git-теги v* -> CI)
#   ./scripts/lab6-demo.sh controller  # п.1   argocd-apps/argo-rollouts.yaml комітом -> Synced/Healthy, CRD, плагін
#   ./scripts/lab6-demo.sh rollout     # п.2   Rollout у чарті комітом: Deployment tasks-service -> Rollout
#   ./scripts/lab6-demo.sh release     # п.4   тег 1.2.0 -> 1.3.0: пауза 20 % (Suspended) -> promote -> Healthy
#   ./scripts/lab6-demo.sh abort       # п.5   тег 1.3.0 -> 1.4.0: пауза -> abort -> Synced + Degraded
#   ./scripts/lab6-demo.sh revert      # п.5   git revert коміту з 1.4.0 -> Healthy, працює 1.3.0
#   ./scripts/lab6-demo.sh watch       # (окремий термінал) kubectl argo rollouts get rollout --watch
#   ./scripts/lab6-demo.sh traffic     # (окремий термінал) безперервний цикл запитів /version зсередини кластера
#   ./scripts/lab6-demo.sh dashboard   # (окремий термінал) веб-інтерфейс Argo Rollouts на http://localhost:3100
#   ./scripts/lab6-demo.sh ui          # port-forward до Argo CD (8080) і застосунку (8081) для браузера
#
# Етапи controller, rollout, release, abort і revert самі роблять commit і push у main:
# Argo CD читає саме main. Вивід і скриншоти - у report/lab6/.
# Перед release/abort варто відкрити в окремих терміналах watch і traffic (або dashboard).
set -euo pipefail
cd "$(dirname "$0")/.."

APP=task-manager
NS=task-manager
ROLLOUT=$APP-tasks-service                 # Rollout і Service tasks-service мають однакове ім'я
SVC_URL=http://$ROLLOUT:8000/version       # запити зсередини кластера, через Service (усі поди)
CHART=charts/task-manager
VALUES=$CHART/values-minikube.yaml
RO_APP=argo-rollouts
RO_APPFILE=argocd-apps/argo-rollouts.yaml
APPFILE=argocd-apps/task-manager.yaml
REG=ghcr.io/aanastasiaakk/devops-labs
CURL_IMAGE=curlimages/curl:8.11.1
ARGO_PORT=8080
APP_PORT=8081
V_RELEASE=1.3.0                            # п.4 реліз
V_ABORT=1.4.0                              # п.5 реліз, який скасовуємо
V_SPARE=1.5.0                              # запасний образ для захисту
OUT=report/lab6
SHOTS=$OUT/screenshots
STAGE=${1:-help}

mkdir -p "$SHOTS"
LOG=$OUT/$STAGE.txt
case "$STAGE" in help|ui|watch|traffic|dashboard) ;; *)
  : > "$LOG"
  exec > >(tee -a "$LOG") 2>&1 ;;
esac

B=$'\033[1;36m'; G=$'\033[1;32m'; Y=$'\033[1;33m'; N=$'\033[0m'
title() { printf '\n%s==================== %s ====================%s\n' "$B" "$*" "$N"; }
run()   { printf '\n%s$ %s%s\n' "$G" "$*" "$N"; "$@"; }
note()  { printf '\n%s# %s%s\n' "$Y" "$*" "$N"; }
pause() { printf '\n%s>>> %s (Enter - далі)%s\n' "$Y" "$*" "$N"; read -r _ </dev/tty; }

# Скриншот вікна терміналу (macOS), як у ЛР-5
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
# Скриншот браузера: відкриває сторінку, чекає, поки ти підготуєш вигляд, знімає весь екран
ui_shot() {
  local name=$1 url=$2 hint=$3
  open "$url" 2>/dev/null || true
  pause "Браузер: $hint. Коли на екрані потрібний стан"
  screencapture -x "$SHOTS/$name.png" 2>/dev/null || true
  echo "[screenshot $name.png]" >> "$LOG"
}
ARGO_UI=https://localhost:$ARGO_PORT/applications/argocd/$APP
RO_UI=http://localhost:3100/rollouts/rollout/$NS/$ROLLOUT

# ---------------------------------------------------------------- допоміжне
use_helm3() {
  local h3; h3=$(brew --prefix helm@3 2>/dev/null || true)
  if [ -n "$h3" ] && [ -x "$h3/bin/helm" ]; then export PATH="$h3/bin:$PATH"; fi
}
app_state() {   # "<sync>/<health>/<revision>" Application
  kubectl -n argocd get application "${2:-$APP}" \
    -o jsonpath='{.status.sync.status}/{.status.health.status}/{.status.sync.revision}' 2>/dev/null || true
}
refresh() {     # те саме, що кнопка Refresh: не чекати опитування Git (до 3 хв)
  for a in "$@"; do argocd app get "$a" --refresh >/dev/null 2>&1 || \
    kubectl -n argocd annotate application "$a" argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true; done
}
wait_state() {  # wait_state <sync> <health> [revision] [timeout] [application]
  local want_sync=$1 want_health=$2 want_rev=${3:-} timeout=${4:-300} app=${5:-$APP} t=0 s=""
  printf 'Чекаю %s: %s / %s%s ' "$app" "$want_sync" "$want_health" "${want_rev:+ (коміт ${want_rev:0:7})}"
  while [ $t -lt "$timeout" ]; do
    s=$(app_state "" "$app")
    IFS=/ read -r sync health rev <<<"$s"
    if [ "$sync" = "$want_sync" ] && [ "$health" = "$want_health" ] && { [ -z "$want_rev" ] || [ "$rev" = "$want_rev" ]; }; then
      printf '\n%sOK: %s / %s, коміт %s%s\n' "$G" "$sync" "$health" "${rev:0:7}" "$N"; return 0
    fi
    printf '.'; sleep 5; t=$((t + 5))
  done
  printf '\nНе дочекалась (зараз: %s)\n' "$s"; return 1
}
ro_phase() { kubectl -n "$NS" get rollout "$ROLLOUT" -o jsonpath='{.status.phase}' 2>/dev/null || true; }
wait_phase() {  # wait_phase <Healthy|Paused|Degraded|Progressing> [timeout]
  local want=$1 timeout=${2:-300} t=0 p=""
  printf 'Чекаю Rollout: %s ' "$want"
  while [ $t -lt "$timeout" ]; do
    p=$(ro_phase)
    if [ "$p" = "$want" ]; then printf '\n%sOK: Rollout %s%s\n' "$G" "$p" "$N"; return 0; fi
    printf '.'; sleep 3; t=$((t + 3))
  done
  printf '\nНе дочекалась (зараз: %s)\n' "$p"; return 1
}
ro_get() { run kubectl argo rollouts get rollout "$ROLLOUT" -n "$NS"; }
# Вибірка запитів зсередини кластера: port-forward іде в ОДИН под і розподілу не покаже
sample() {      # sample [кількість]
  local n=${1:-40}
  note "$n запитів до $SVC_URL з пода всередині кластера (скільки відповідей від кожної версії):"
  kubectl -n "$NS" run "curl-sample-$RANDOM" --rm -i --quiet --restart=Never --image="$CURL_IMAGE" -- \
    sh -c "for i in \$(seq 1 $n); do curl -s --max-time 2 $SVC_URL; echo; sleep 0.2; done" 2>/dev/null \
    | grep -o '"version":"[^"]*"' | sort | uniq -c || true
}
current_tag() { sed -n 's/^  tag: "\(.*\)"/\1/p' "$VALUES" | head -1; }
set_tag()     { sed -i '' "s/^  tag: \".*\"/  tag: \"$1\"/" "$VALUES"; }
git_ready() {   # GitOps-коміти робимо в main, з якої читає Argo CD
  local br; br=$(git rev-parse --abbrev-ref HEAD)
  if [ "$br" != main ]; then echo "Потрібна гілка main (зараз $br): git checkout main"; exit 1; fi
  run git pull --ff-only --rebase=false || { echo "git pull не вдався. Закоміть або сховай (git stash) лише ЧУЖІ зміни і повтори"; exit 1; }
}
git_push() {    # git_push "<повідомлення>" <файли...>
  local msg=$1; shift
  run git add "$@"
  run git commit -m "$msg"
  run git push
  REV=$(git rev-parse HEAD)
}
image_exists() { docker manifest inspect "$REG/tasks-service:$1" >/dev/null 2>&1; }
need_plugin() {
  command -v kubectl-argo-rollouts >/dev/null || { echo "Немає плагіна: ./scripts/lab6-demo.sh controller (або brew install argoproj/tap/kubectl-argo-rollouts)"; exit 1; }
}
release_to() {  # release_to <версія> "<повідомлення коміту>"
  local v=$1 msg=$2
  image_exists "$v" || { echo "Образу $REG/tasks-service:$v немає: спершу ./scripts/lab6-demo.sh images"; exit 1; }
  git_ready
  note "Поточна версія: $(current_tag), стан Rollout: $(ro_phase)"
  set_tag "$v"
  run git diff
  git_push "$msg" "$VALUES"
  refresh "$APP"
}

# ---------------------------------------------------------------- етапи
case "$STAGE" in

check)
  title "п.2-3  Чарт: Rollout замість Deployment, стратегія canary"
  use_helm3
  run helm lint "$CHART" -f "$VALUES"
  helm template "$APP" "$CHART" -n "$NS" -f "$VALUES" > "$OUT/rendered-minikube.yaml"
  note "Що рендерить чарт для Argo CD (kind і ім'я). Для tasks-service - Rollout, Deployment немає:"
  grep -E '^(kind|  name):' "$OUT/rendered-minikube.yaml" | paste - - | sort | uniq
  note "Стратегія з values-minikube.yaml:"
  sed -n '/^kind: Rollout/,$p' "$OUT/rendered-minikube.yaml" | sed -n '/^  strategy:/,/^---/p' | grep -v '^---'
  note "Без rollout.enabled (як у ЛР-5) той самий чарт дає звичайний Deployment:"
  helm template "$APP" "$CHART" -n "$NS" -f "$VALUES" --set rollout.enabled=false \
    | grep -E '^(kind|  name):' | paste - - | grep tasks-service
  note "Варіант blue-green (п.3b) теж підтримується: з'являється Service ...-preview"
  helm template "$APP" "$CHART" -n "$NS" -f "$VALUES" --set rollout.strategy.canary=null \
    --set rollout.strategy.blueGreen.autoPromotionEnabled=false --set rollout.strategy.blueGreen.scaleDownDelaySeconds=30 \
    > "$OUT/rendered-bluegreen.yaml"
  grep -E '^(kind|  name):' "$OUT/rendered-bluegreen.yaml" | paste - - | grep tasks-service
  sed -n '/^kind: Rollout/,$p' "$OUT/rendered-bluegreen.yaml" | sed -n '/^  strategy:/,/^---/p' | grep -v '^---'
  note "Под у Rollout і в Deployment однаковий (спільний хелпер task-manager.tasksPodTemplate):"
  diff <(helm template "$APP" "$CHART" -n "$NS" -f "$VALUES" -s templates/tasks-rollout.yaml | sed -n '/^  template:/,/^  strategy:/p' | sed '$d') \
       <(helm template "$APP" "$CHART" -n "$NS" -f "$VALUES" --set rollout.enabled=false -s templates/tasks-deployment.yaml | sed -n '/^  template:/,$p') \
    && echo "OK: шаблони пода збігаються"
  shot 01-check
  ;;

images)
  title "п.4  Образи кількох версій у GHCR"
  note "Образи збирає CI з git-тегу v*: тег v1.3.0 -> ghcr.io/.../tasks-service:1.3.0 з APP_VERSION=1.3.0"
  git_ready
  NEW=()
  for v in $V_RELEASE $V_ABORT $V_SPARE; do
    if image_exists "$v"; then echo "образ $v уже є"; continue; fi
    git rev-parse "v$v" >/dev/null 2>&1 || run git tag -a "v$v" -m "Release $v (ЛР-6)"
    NEW+=("v$v")
  done
  if [ ${#NEW[@]} -gt 0 ]; then
    run git push origin "${NEW[@]}"
    note "CI збирає образи (5-10 хв). Хід: https://github.com/aanastasiaakk/devops-labs/actions"
    for v in $V_RELEASE $V_ABORT $V_SPARE; do
      printf 'Чекаю образ %s ' "$v"
      for _ in $(seq 1 120); do image_exists "$v" && break; printf '.'; sleep 10; done
      image_exists "$v" && printf ' %sOK%s\n' "$G" "$N" || { printf ' немає\n'; exit 1; }
    done
  fi
  for v in 1.2.0 $V_RELEASE $V_ABORT $V_SPARE; do
    printf '%-6s ' "$v"; docker manifest inspect "$REG/tasks-service:$v" >/dev/null 2>&1 && echo "є у GHCR" || echo "НЕМАЄ"
  done
  shot 04a-images
  ;;

controller)
  title "п.1  Контролер Argo Rollouts через Argo CD"
  use_helm3
  run helm repo add argo https://argoproj.github.io/argo-helm --force-update
  run helm repo update argo
  run helm search repo argo/argo-rollouts
  note "У $RO_APPFILE вписана версія $(sed -n 's/^ *targetRevision: \([^ ]*\).*/\1/p' "$RO_APPFILE")"
  git_ready
  run git diff -- "$APPFILE"
  git_push "Add Argo Rollouts" "$RO_APPFILE" "$APPFILE" scripts/lab6-demo.sh README.md
  refresh root
  note "root бачить новий файл в argocd-apps/ і створює Application argo-rollouts (sync-wave -1)"
  for _ in $(seq 1 30); do kubectl -n argocd get application "$RO_APP" >/dev/null 2>&1 && break; sleep 2; done
  wait_state Synced Healthy "" 300 "$RO_APP"
  run argocd app get "$RO_APP"
  run kubectl -n argo-rollouts get pods
  run sh -c "kubectl get crd | grep argoproj"
  note "retry у task-manager: синхронізація, що прийде раніше за CRD, повториться сама"
  run sh -c "kubectl -n argocd get application $APP -o jsonpath='{.spec.syncPolicy.retry}'; echo"
  command -v kubectl-argo-rollouts >/dev/null || run brew install argoproj/tap/kubectl-argo-rollouts
  run kubectl argo rollouts version
  shot 01-controller
  ui_shot 01-ui-controller https://localhost:$ARGO_PORT/applications "плитки root, argo-rollouts і task-manager - усі Synced / Healthy"
  ;;

rollout)
  title "п.2  Rollout у Helm-чарті"
  if [ "$(app_state "" "$RO_APP" | cut -d/ -f2)" != Healthy ]; then
    echo "Спершу контролер: ./scripts/lab6-demo.sh controller (argo-rollouts має бути Healthy)"; exit 1
  fi
  need_plugin
  git_ready
  run git status --short "$CHART"
  run git diff --stat -- "$CHART"
  git_push "Rollout (canary) for tasks-service, chart 0.3.0" "$CHART"
  refresh "$APP"
  note "Перший перехід: Argo CD видаляє Deployment (prune) і створює Rollout, короткий простій - нормально"
  wait_state Synced Healthy "$REV" 420
  wait_phase Healthy 300
  run kubectl -n "$NS" get rollout,deployment
  ro_get
  sample 20
  shot 02-rollout
  ui_shot 02-ui-rollout "$ARGO_UI" "у дереві task-manager-tasks-service тепер Rollout -> ReplicaSet -> 5 подів"
  ;;

release)
  title "п.4  Canary-реліз $V_RELEASE через Git"
  need_plugin
  note "Для показу відкрий в окремих терміналах: ./scripts/lab6-demo.sh watch і ./scripts/lab6-demo.sh traffic"
  release_to "$V_RELEASE" "Release task-manager $V_RELEASE (canary)"
  note "Rollout помітив новий шаблон пода: крок setWeight 20 -> 1 под нової версії з 5, далі pause: {}"
  wait_phase Paused 300
  wait_state Synced Suspended "$REV" 120 || true
  ro_get
  run argocd app get "$APP"
  sample 40
  note "Приблизно кожна п'ята відповідь - $V_RELEASE (1 под із 5)"
  shot 04b-paused
  ui_shot 04b-ui-suspended "$ARGO_UI" "Health: Suspended; відкрий Rollout - видно дві ReplicaSet (стара 4 поди, нова 1)"
  pause "Зараз promote: реліз піде далі (60 % -> 30 с -> 80 % -> 30 с -> 100 %)"
  run kubectl argo rollouts promote "$ROLLOUT" -n "$NS"
  sleep 8; ro_get
  sample 20
  wait_phase Healthy 300
  wait_state Synced Healthy "$REV" 120
  ro_get
  run argocd app get "$APP"
  sample 20
  shot 04c-promoted
  ;;

abort)
  title "п.5  Скасування релізу $V_ABORT: abort"
  need_plugin
  release_to "$V_ABORT" "Release task-manager $V_ABORT (буде скасовано)"
  wait_phase Paused 300
  ro_get
  sample 30
  shot 05a-paused
  pause "Зараз abort: трафік повністю повернеться на стабільну $V_RELEASE"
  run kubectl argo rollouts abort "$ROLLOUT" -n "$NS"
  wait_phase Degraded 120
  ro_get
  note "Маніфест у кластері = Git (там $V_ABORT) -> Synced; але реліз скасовано і працює стара версія -> Degraded"
  wait_state Synced Degraded "$REV" 120 || true
  run argocd app get "$APP"
  sample 20
  shot 05b-aborted
  ui_shot 05b-ui-degraded "$ARGO_UI" "Synced + Degraded; на Rollout повідомлення RolloutAborted"
  ;;

revert)
  title "п.5  Завершення через Git: git revert"
  need_plugin
  git_ready
  BAD=$(git log --format=%H --grep="Release task-manager $V_ABORT" -1)
  [ -n "$BAD" ] || { echo "Не знайдено коміт із $V_ABORT"; exit 1; }
  run git log --oneline -6
  run git revert --no-edit "$BAD"
  run git push
  REV=$(git rev-parse HEAD)
  refresh "$APP"
  note "Шаблон пода в Git знову = стабільна ReplicaSet ($V_RELEASE): нових подів не потрібно, Rollout -> Healthy"
  wait_phase Healthy 300
  wait_state Synced Healthy "$REV" 180
  ro_get
  run argocd app get "$APP"
  run git log --oneline -6
  sample 20
  shot 05c-revert
  ui_shot 05c-ui-healthy "$ARGO_UI" "Synced / Healthy, Rollout на $V_RELEASE"
  ;;

watch)
  need_plugin
  exec kubectl argo rollouts get rollout "$ROLLOUT" -n "$NS" --watch
  ;;

traffic)
  echo "Цикл запитів до $SVC_URL з пода в кластері (Ctrl+C - зупинити, под видалиться сам)"
  exec kubectl -n "$NS" run curl --rm -it --restart=Never --image="$CURL_IMAGE" -- \
    sh -c "while true; do curl -s --max-time 2 $SVC_URL; echo; sleep 0.5; done"
  ;;

dashboard)
  need_plugin
  echo "Argo Rollouts dashboard: $RO_UI"
  ( sleep 3; open "$RO_UI" 2>/dev/null || true ) &
  exec kubectl argo rollouts dashboard
  ;;

ui)
  pkill -f "port-forward svc/argocd-server" 2>/dev/null || true
  pkill -f "port-forward svc/$APP-frontend" 2>/dev/null || true
  nohup kubectl -n argocd port-forward svc/argocd-server $ARGO_PORT:443 >/dev/null 2>&1 &
  nohup kubectl -n "$NS" port-forward svc/$APP-frontend $APP_PORT:80 >/dev/null 2>&1 &
  sleep 2
  echo "Argo CD:    https://localhost:$ARGO_PORT  (admin / твій пароль)"
  echo "Застосунок: http://localhost:$APP_PORT"
  ;;

*)
  sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
  ;;
esac
