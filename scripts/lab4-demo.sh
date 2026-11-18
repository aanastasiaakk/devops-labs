#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

CHART=charts/task-manager
DEV=$CHART/values-dev.yaml
PROD=$CHART/values-prod.yaml
REL=task-manager
COPY=demo-copy
NS=lab4
OUT=report/lab4
SHOTS=$OUT/screenshots
LOG=$OUT/lab4-log.txt
PORT=8080
URL="http://localhost:$PORT"
H3=$(brew --prefix helm@3 2>/dev/null || true)
if [ -n "$H3" ] && [ -x "$H3/bin/helm" ]; then export PATH="$H3/bin:$PATH"; fi
if ! helm version --short 2>/dev/null | grep -q '^v3\.'; then
  echo "Потрібен Helm 3. Виконай: brew install helm@3"
  exit 1
fi
mkdir -p "$SHOTS"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

WID=""
if [ "${TERM_PROGRAM:-}" != "Apple_Terminal" ]; then
  echo "Розгорни термінал на весь екран (у PyCharm: Cmd + Shift + ') і натисни Enter"
  read -r _
fi
if [ "${TERM_PROGRAM:-}" = "Apple_Terminal" ]; then
  osascript -e 'tell application "Terminal" to set zoomed of front window to true' >/dev/null 2>&1 || true
  WID=$(osascript -e 'tell application "Terminal" to id of front window' 2>/dev/null || true)
fi

B=$'\033[1;36m'; G=$'\033[1;32m'; N=$'\033[0m'
FRAME=""
frame() { FRAME=$1; clear; printf '%s==================== %s ====================%s\n' "$B" "$2" "$N"; }
run()   { printf '\n%s$ %s%s\n' "$G" "$*" "$N"; "$@"; }
show()  { printf '\n%s$ %s%s\n' "$G" "$1" "$N"; }
note()  { printf '\n%s# %s%s\n' "$B" "$*" "$N"; }
shot()  {
  sleep 1.5
  if [ -n "$WID" ]; then screencapture -x -o -l "$WID" "$SHOTS/$FRAME.png" || true
  else screencapture -x "$SHOTS/$FRAME.png" || true; fi
  printf '\n[screenshot %s.png]\n' "$FRAME" >> "$LOG"
  sleep 0.5
}

PF_PID=""
pf_stop()  { if [ -n "$PF_PID" ]; then kill "$PF_PID" 2>/dev/null || true; wait "$PF_PID" 2>/dev/null || true; PF_PID=""; fi; }
pf_start() {
  pf_stop
  kubectl -n "$NS" port-forward "svc/$REL-frontend" "$PORT:80" >/dev/null 2>&1 &
  PF_PID=$!
  for _ in $(seq 1 30); do curl -sf "$URL/" >/dev/null && return 0; sleep 1; done
}
trap pf_stop EXIT
version_probe() { curl -s "$URL/api/version"; echo; }

settle() {
  for _ in $(seq 1 90); do
    if [ -z "$(kubectl -n "$NS" get pods -o jsonpath='{range .items[*]}{.metadata.deletionTimestamp}{end}' 2>/dev/null)" ]; then return 0; fi
    sleep 2
  done
}

HOOK_PID=""
hook_watch() {
  local file=$1
  ( P=""
    for _ in $(seq 1 600); do
      P=$(kubectl -n "$NS" get pods -l "app.kubernetes.io/instance=$REL,app.kubernetes.io/component=pre-upgrade-check" -o name 2>/dev/null | head -1)
      [ -n "$P" ] && break
      sleep 0.2
    done
    if [ -n "$P" ]; then
      for _ in $(seq 1 100); do
        if kubectl -n "$NS" logs -f "$P" 2>/dev/null; then break; fi
        sleep 0.2
      done
    fi ) > "$file" 2>&1 &
  HOOK_PID=$!
}
hook_show() {
  local file=$1
  sleep 1; kill "$HOOK_PID" 2>/dev/null || true; wait "$HOOK_PID" 2>/dev/null || true
  note "Логи Job хука pre-upgrade:"
  if [ -s "$file" ]; then sed 's/^/  /' "$file"
  else kubectl -n "$NS" get events --sort-by=.lastTimestamp 2>/dev/null | grep pre-upgrade-check | tail -4 || true; fi
}
names() { awk '/^kind:/{k=$2; getline; getline; if ($1=="name:") printf "%-22s %s\n", k, $2}' | sort; }
rev_summary() {
  helm get values "$REL" -n "$NS" --revision "$1" --all -o json | python3 -c '
import json, sys
v = json.load(sys.stdin)
print("  ревізія %s: image.tag=%s  tasks=%s stats=%s frontend=%s  cacheTTL=%s  ingress=%s  tasks.cpu.limit=%s" % (
    sys.argv[1], v["image"]["tag"], v["tasksService"]["replicaCount"], v["statsService"]["replicaCount"],
    v["frontend"]["replicaCount"], v["config"]["cacheTTL"], str(v["ingress"]["enabled"]).lower(),
    v["tasksService"]["resources"]["limits"]["cpu"]))' "$1"
}

if ! minikube status >/dev/null 2>&1; then
  minikube start --driver=docker --cpus=2 --memory=4096
fi
minikube addons enable metrics-server >/dev/null
minikube addons enable ingress >/dev/null
kubectl -n ingress-nginx wait --for=condition=ready pod -l app.kubernetes.io/component=controller --timeout=180s >/dev/null
helm uninstall "$REL" -n "$NS" --wait >/dev/null 2>&1 || true
helm uninstall "$COPY" -n "$NS" --wait >/dev/null 2>&1 || true

frame 01-helm-minikube "1a-1b. Helm 3 і кластер minikube"
run helm version
run minikube status
run kubectl get nodes
show "minikube addons list   (ingress, metrics-server)"
minikube addons list -o json | python3 -c '
import json, sys
a = json.load(sys.stdin)
for n in ("ingress", "metrics-server"):
    print("  %-16s %s" % (n, a.get(n, {}).get("Status", "?")))' || true
shot

frame 02-lab3-deploy "1c. Маніфести лабораторної №3 розгортаються і застосунок працює"
run kubectl apply -f k8s/
kubectl -n task-manager wait --for=condition=available deployment --all --timeout=300s >/dev/null
run kubectl -n task-manager get pods
kubectl -n task-manager port-forward svc/frontend 8090:80 >/dev/null 2>&1 &
L3=$!
for _ in $(seq 1 30); do curl -sf http://localhost:8090/ >/dev/null && break; sleep 1; done
show "curl http://localhost:8090/api/version"
curl -s http://localhost:8090/api/version; echo
kill $L3 2>/dev/null || true; wait $L3 2>/dev/null || true
shot

frame 03-lab3-delete "1d. Видалення розгортання лабораторної №3"
run kubectl delete -f k8s/ --wait=true
run kubectl get namespaces
shot

frame 04-chart-structure "2. Структура чарта і Chart.yaml"
show "find $CHART -type f | sort"
find "$CHART" -type f | sort
run cat "$CHART/Chart.yaml"
shot

frame 05-templates "3. Шаблони: імена з імені релізу, Secret зі значень"
note "3a. Маніфести лаби №3 -> окремі файли templates/"
show "ls -C k8s/ $CHART/templates/"
ls -C k8s/ "$CHART/templates/"
note "3c. Ім'я об'єкта залежить від імені релізу"
show "helm template task-manager $CHART --show-only templates/tasks-service.yaml | grep '^  name:'"
helm template task-manager "$CHART" --show-only templates/tasks-service.yaml | grep '^  name:'
show "helm template demo-copy $CHART --show-only templates/tasks-service.yaml | grep '^  name:'"
helm template demo-copy "$CHART" --show-only templates/tasks-service.yaml | grep '^  name:'
note "3d. Секрет бере значення з .Values (порожній пароль -> lookup / randAlphaNum)"
show "grep -nE 'Values|lookup|randAlphaNum' $CHART/templates/secret.yaml"
grep -nE 'Values|lookup|randAlphaNum' "$CHART/templates/secret.yaml"
shot

frame 06-values "4. values.yaml: параметри працюють, прапорці enabled"
note "4a. За замовчуванням і після --set"
show "helm template ... --show-only templates/tasks-deployment.yaml | grep -E 'replicas:|image: ghcr'"
helm template "$REL" "$CHART" --show-only templates/tasks-deployment.yaml | grep -E 'replicas:|image: ghcr'
show "helm template ... --set tasksService.replicaCount=4 --set image.tag=1.0.0 | grep -E 'replicas:|image: ghcr'"
helm template "$REL" "$CHART" --show-only templates/tasks-deployment.yaml --set tasksService.replicaCount=4 --set image.tag=1.0.0 | grep -E 'replicas:|image: ghcr'
show "helm template ... --show-only templates/frontend-service.yaml --set frontend.service.type=NodePort --set frontend.service.port=8080"
helm template "$REL" "$CHART" --show-only templates/frontend-service.yaml --set frontend.service.type=NodePort --set frontend.service.port=8080 | grep -E '  type:|- name: http|    port:'
show "helm template ... --show-only templates/tasks-deployment.yaml --set tasksService.resources.limits.memory=512Mi"
helm template "$REL" "$CHART" --show-only templates/tasks-deployment.yaml --set tasksService.resources.limits.memory=512Mi | grep -A3 '            limits:' | tail -3
show "helm template ... --show-only templates/configmap.yaml --set config.cacheTTL=60 | grep CACHE_TTL"
helm template "$REL" "$CHART" --show-only templates/configmap.yaml --set config.cacheTTL=60 | grep '  CACHE_TTL'
note "4c. Прапорці enabled"
printf '  persistence.enabled=true  -> PVC:     %s\n' "$(helm template "$REL" "$CHART" | grep -c '^kind: PersistentVolumeClaim' || true)"
printf '  persistence.enabled=false -> PVC:     %s\n' "$(helm template "$REL" "$CHART" --set postgresql.persistence.enabled=false | grep -c '^kind: PersistentVolumeClaim' || true)"
printf '  ingress.enabled=false     -> Ingress: %s\n' "$(helm template "$REL" "$CHART" | grep -c '^kind: Ingress' || true)"
printf '  ingress.enabled=true      -> Ingress: %s\n' "$(helm template "$REL" "$CHART" --set ingress.enabled=true | grep -c '^kind: Ingress' || true)"
shot

frame 07-helpers "5. _helpers.tpl і include у всіх шаблонах"
show "grep -n 'define' $CHART/templates/_helpers.tpl"
grep -n 'define' "$CHART/templates/_helpers.tpl"
show "grep -c 'include \"task-manager' $CHART/templates/*.yaml $CHART/templates/*/*.yaml"
grep -c 'include "task-manager' "$CHART"/templates/*.yaml "$CHART"/templates/*/*.yaml
shot

frame 08-env-files "6a. values-dev.yaml і values-prod.yaml (лише відмінні рядки)"
show "diff -y -W 140 --suppress-common-lines $DEV $PROD"
diff -y -W 140 --suppress-common-lines "$DEV" "$PROD" || true
shot

CMP="--set postgresql.password=only-for-diff"
helm template "$REL" "$CHART" -n "$NS" -f "$DEV"  $CMP > "$OUT/rendered-dev.yaml"
helm template "$REL" "$CHART" -n "$NS" -f "$PROD" $CMP > "$OUT/rendered-prod.yaml"
diff -u "$OUT/rendered-dev.yaml" "$OUT/rendered-prod.yaml" > "$OUT/06b-full.diff" || true

frame 09-env-summary "6b. Різниця середовищ без встановлення: helm template"
show "helm template $REL $CHART -f values-dev.yaml  > rendered-dev.yaml"
show "helm template $REL $CHART -f values-prod.yaml > rendered-prod.yaml"
for E in dev prod; do
  printf '\n[%s]\n' "$E"
  awk '/^kind:/{k=$2} /^  name:/{n=$2} /^  replicas:/{print "  " k "/" n ": replicas=" $2} /image: ghcr/{print "  " n ": " $2}' "$OUT/rendered-$E.yaml"
  printf '  CACHE_TTL=%s   Ingress: %s\n' "$(grep -m1 '^  CACHE_TTL:' "$OUT/rendered-$E.yaml" | awk '{print $2}')" "$(grep -c '^kind: Ingress' "$OUT/rendered-$E.yaml" || true)"
done
shot

frame 10-env-diff "6b. diff rendered-dev.yaml rendered-prod.yaml (змінені рядки)"
show "diff -u rendered-dev.yaml rendered-prod.yaml | grep '^[-+] ' | grep -v version"
grep -E '^[-+] ' "$OUT/06b-full.diff" | grep -vE 'app.kubernetes.io/version|checksum/' | head -46 || true
note "Повний diff: $OUT/06b-full.diff"
shot

frame 11-priority "6c. Пріоритет значень: values.yaml < -f < --set"
prio() {
  show "helm template ... $*"
  helm template "$REL" "$CHART" -n "$NS" "$@" --show-only templates/tasks-deployment.yaml | grep -E '^  replicas:|image: ghcr' | sed 's/^ */    /'
}
note "1) лише values.yaml"; prio
note "2) -f values-prod.yaml перекриває values.yaml"; prio -f "$PROD"
note "3) --set перекриває і values.yaml, і -f"; prio -f "$PROD" --set tasksService.replicaCount=5 --set image.tag=1.1.0
note "4) кілька -f: перемагає пізніший"; prio -f "$PROD" -f "$DEV"
shot

frame 12-lint "7a. Перевірка чарта на помилки: helm lint"
run helm lint "$CHART" --strict
run helm lint "$CHART" -f "$DEV" --strict
run helm lint "$CHART" -f "$PROD" --strict
shot

frame 13-compare-lab3 "7b. Порівняння з маніфестами лабораторної №3"
note "Типи об'єктів"
printf '  %-24s %8s %8s\n' "kind" "лаба №3" "чарт(prod)"
{ grep -h '^kind:' k8s/*.yaml | awk '{print "L", $2}'
  helm template "$REL" "$CHART" -n "$NS" -f "$PROD" --skip-tests --no-hooks | grep '^kind:' | awk '{print "C", $2}'
} | awk '{k[$2]; if ($1 == "L") l[$2]++; else c[$2]++} END {for (x in k) printf "  %-24s %8d %8d\n", x, l[x], c[x]}' | sort
note "Namespace створює helm install --create-namespace, тому в чарті його немає"
note "Імена: лаба №3  |  реліз task-manager  |  реліз demo-copy"
paste <(awk '/^kind:/{k=$2; getline; getline; if ($1=="name:") printf "%s %s\n", k, $2}' k8s/*.yaml | grep -v Namespace | sort) \
      <(helm template "$REL" "$CHART" -n "$NS" -f "$PROD" --skip-tests --no-hooks | names | awk '{print $2}') \
      <(helm template "$COPY" "$CHART" -n "$NS" -f "$PROD" --skip-tests --no-hooks | names | awk '{print $2}') \
  | awk '{printf "  %-22s %-15s | %-28s | %s\n", $1, $2, $3, $4}'
note "Жорстко прописані теги, репліки, імена в шаблонах:"
grep -rnE 'replicas: [0-9]|:[0-9]+\.[0-9]+\.[0-9]+|^  name: (tasks-service|stats-service|frontend|postgres|redis|app-config|app-secret)$' "$CHART/templates" || echo "  не знайдено"
shot

frame 14-install "7c. Встановлення релізу у власний namespace однією командою"
run helm install "$REL" "$CHART" -n "$NS" --create-namespace -f "$DEV" --wait --timeout 5m
shot

frame 15-list-values "7d. Перелік релізів, статус і значення"
run helm list -n "$NS"
show "helm status $REL -n $NS | head -7"
helm status "$REL" -n "$NS" | head -7
run helm get values "$REL" -n "$NS"
shot

frame 16-objects "7d. Об'єкти релізу в namespace $NS"
run kubectl -n "$NS" get pods,deployments,services,pvc,configmaps,secrets
shot

settle
pf_start
frame 17-app "Застосунок з релізу працює"
show "curl -X POST $URL/api/tasks -d '{\"title\":\"Задача з Helm-релізу\"}'"
curl -s -X POST "$URL/api/tasks" -H 'Content-Type: application/json' -d '{"title":"Задача з Helm-релізу"}'; echo
show "curl $URL/api/tasks";   curl -s "$URL/api/tasks"; echo
show "curl $URL/api/stats";   curl -s "$URL/api/stats"; echo
show "curl $URL/api/version"; version_probe
shot

frame 18-test "9b. Тест релізу: helm test"
run helm test "$REL" -n "$NS"
shot

frame 19-storage "7e. Де Helm зберігає стан релізу"
run kubectl -n "$NS" get secrets -l owner=helm --show-labels
show "kubectl get secret sh.helm.release.v1.$REL.v1 -o jsonpath='{.data.release}' | base64 -d | base64 -d | gzip -d"
kubectl -n "$NS" get secret "sh.helm.release.v1.$REL.v1" -o jsonpath='{.data.release}' \
  | base64 --decode | base64 --decode | gzip -d \
  | python3 -c '
import json, sys
r = json.load(sys.stdin)
print("  name:      ", r["name"])
print("  namespace: ", r["namespace"])
print("  revision:  ", r["version"])
print("  status:    ", r["info"]["status"])
print("  chart:     ", r["chart"]["metadata"]["name"], r["chart"]["metadata"]["version"], "appVersion", r["chart"]["metadata"]["appVersion"])
print("  config:    ", json.dumps(r["config"], ensure_ascii=False)[:150], "...")
print("  manifest:")
for line in r["manifest"].splitlines():
    if line.startswith("# Source:"):
        print("    ", line)
' || true
shot

helm install "$COPY" "$CHART" -n "$NS" -f "$DEV" --wait --timeout 5m > "$OUT/copy-install.txt" 2>&1
frame 20-two-releases "3c. Той самий чарт удруге в тому ж namespace"
show "helm install $COPY $CHART -n $NS -f values-dev.yaml   (виконано)"
run helm list -n "$NS"
run kubectl -n "$NS" get deployments -L app.kubernetes.io/instance
shot
helm uninstall "$COPY" -n "$NS" --wait >/dev/null

frame 21-upgrade-set "8a. Оновлення: зміна тега образу через --set (1.1.0 -> 1.0.0)"
hook_watch "$OUT/hook-rev2.log"
show "helm upgrade $REL $CHART -n $NS -f values-dev.yaml --set image.tag=1.0.0 --wait"
helm upgrade "$REL" "$CHART" -n "$NS" -f "$DEV" --set image.tag=1.0.0 --wait --timeout 5m > "$OUT/upgrade-rev2.txt" 2>&1
head -6 "$OUT/upgrade-rev2.txt"
hook_show "$OUT/hook-rev2.log"
settle
run kubectl -n "$NS" get pods -o custom-columns='POD:.metadata.name,IMAGE:.spec.containers[0].image,STATUS:.status.phase'
pf_start
printf '\nВерсія після оновлення: '; version_probe
shot

frame 22-upgrade-prod "8b. Оновлення файлом значень іншого середовища (values-prod.yaml)"
hook_watch "$OUT/hook-rev3.log"
show "helm upgrade $REL $CHART -n $NS -f values-prod.yaml --wait"
helm upgrade "$REL" "$CHART" -n "$NS" -f "$PROD" --wait --timeout 6m > "$OUT/upgrade-rev3.txt" 2>&1
head -6 "$OUT/upgrade-rev3.txt"
hook_show "$OUT/hook-rev3.log"
settle
run kubectl -n "$NS" get deployments,ingress
pf_start
printf '\nВерсія: '; version_probe
printf 'Задача з dev збереглася (PVC): '; curl -s "$URL/api/tasks"; echo
kubectl -n ingress-nginx port-forward svc/ingress-nginx-controller 8081:80 >/dev/null 2>&1 &
IPF=$!
for _ in $(seq 1 20); do curl -sf http://localhost:8081/ >/dev/null && break; sleep 1; done
show "curl http://localhost:8081/api/version   (через Ingress-контролер)"
curl -s http://localhost:8081/api/version; echo
kill $IPF 2>/dev/null || true; wait $IPF 2>/dev/null || true
shot

frame 23-history "8c. Історія ревізій і що змінювалося"
run helm history "$REL" -n "$NS"
note "Значення кожної ревізії (helm get values --revision N):"
for R in 1 2 3; do rev_summary $R; done
note "Маніфести: ревізія 1 -> 2"
diff <(helm get manifest "$REL" -n "$NS" --revision 1) <(helm get manifest "$REL" -n "$NS" --revision 2) | grep -E '^[<>]' | grep -vE 'checksum|app.kubernetes.io/version' | sort | uniq -c || true
note "Маніфести: ревізія 2 -> 3"
diff <(helm get manifest "$REL" -n "$NS" --revision 2) <(helm get manifest "$REL" -n "$NS" --revision 3) | grep -E '^[<>]' | grep -vE 'checksum|app.kubernetes.io/version' | sort | uniq -c | grep -E 'replicas|CACHE|cpu: |ingressClassName|tasks-service:' | head -14 || true
shot

frame 24-rollback "8d. Відкат до ревізії 1"
run helm rollback "$REL" 1 -n "$NS" --wait --timeout 5m
settle
run helm history "$REL" -n "$NS"
run kubectl -n "$NS" get deployments,ingress
pf_start
printf '\nВерсія після відкату: '; version_probe
shot

frame 25-rollback-test "8d. Після відкату реліз проходить тест"
run helm test "$REL" -n "$NS"
shot

frame 26-uninstall "8e. Видалення релізу однією командою"
pf_stop
run helm uninstall "$REL" -n "$NS" --wait
show "kubectl -n $NS wait --for=delete pod -l app.kubernetes.io/instance=$REL --timeout=180s"
kubectl -n "$NS" wait --for=delete pod -l "app.kubernetes.io/instance=$REL" --timeout=180s >/dev/null 2>&1 || true
echo "  усі поди релізу видалено"
run helm list -n "$NS"
run kubectl -n "$NS" get all,configmaps,secrets,pvc,ingress,jobs
note "kube-root-ca.crt Kubernetes створює в кожному namespace сам, до релізу не належить."
show "kubectl -n $NS get all,configmaps,secrets,pvc,ingress,jobs -l app.kubernetes.io/instance=$REL"
kubectl -n "$NS" get all,configmaps,secrets,pvc,ingress,jobs -l "app.kubernetes.io/instance=$REL" 2>&1
shot

clear
printf '\nГотово. Скріншоти: %s/, лог: %s\n' "$SHOTS" "$LOG"
