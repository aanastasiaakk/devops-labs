# Звіт: лабораторна робота №3 — Kubernetes

Вивід команд збережено скриптом [`scripts/lab3-demo.sh`](../scripts/lab3-demo.sh) під час запуску на локальному кластері minikube
(Kubernetes v1.37.0, драйвер docker, macOS arm64).

| Пункт завдання | Файл | Результат |
|---|---|---|
| 2. Кластер, вузол, kube-system, metrics-server, ingress | [02-cluster.txt](02-cluster.txt) | вузол `Ready`, системні поди `Running`, доповнення увімкнено |
| 1. Дві версії образів | [01-images.txt](01-images.txt) | `1.0.0` і `1.1.0` для tasks-service, stats-service, frontend; `latest` не використовується |
| 5a–5b. Розгортання однією командою, перелік об'єктів | [05-deploy.txt](05-deploy.txt) | `kubectl apply -f k8s/`: 8 подів `Running` без перезапусків, PVC `Bound` |
| 5c–5d. Застосунок працює, ConfigMap і Secret у контейнерах | [05-app.txt](05-app.txt) | API створює і повертає задачі; змінні з ConfigMap/Secret присутні в контейнерах |
| 6a. Самовідновлення | [06ab-selfheal-scale.txt](06ab-selfheal-scale.txt) | видалений под замінено новим автоматично |
| 6b. Масштабування і розподіл трафіку | [06ab-selfheal-scale.txt](06ab-selfheal-scale.txt) | 4 репліки, 60 запитів розподілено між усіма 4 подами |
| 6c, 6e. Rolling update під навантаженням | [06cde-update-rollback.txt](06cde-update-rollback.txt), [06ce-requests.log](06ce-requests.log) | 1.0.0 → 1.1.0; **100 запитів, 0 невдалих** |
| 6d. Історія і відкат | [06cde-update-rollback.txt](06cde-update-rollback.txt) | ревізії з `CHANGE-CAUSE`, `rollout undo` повернув 1.0.0 |
| 7a–7b. ImagePullBackOff і пошук причини | [07-diagnostics.txt](07-diagnostics.txt) | тег `9.9.9` → `ImagePullBackOff`; у Events: `...:9.9.9: not found`; старі поди продовжують працювати |
| 7c. Логи і команди в контейнері | [07-diagnostics.txt](07-diagnostics.txt) | `kubectl logs`, `kubectl exec` |
| 7d. Виправлення | [07-diagnostics.txt](07-diagnostics.txt) | повернуто існуючий тег `1.1.0`, усі поди `Running` |

Скриншоти браузера: `minikube tunnel` в окремому терміналі, потім http://127.0.0.1.
