{{/*
Шаблон пода tasks-service (spec.template). Спільний для Deployment (tasks-deployment.yaml)
і Rollout (tasks-rollout.yaml, ЛР-6): под однаковий за будь-якої стратегії розгортання,
різниться лише об'єкт, який ним керує.
*/}}
{{- define "task-manager.tasksPodTemplate" -}}
{{- $c := dict "ctx" $ "component" "tasks-service" }}
{{- $v := .Values.tasksService }}
{{- $pgHost := include "task-manager.componentName" (dict "ctx" $ "component" "postgres") -}}
metadata:
  labels:
    {{- include "task-manager.componentLabels" $c | nindent 4 }}
  annotations:
    checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
spec:
  terminationGracePeriodSeconds: 30
  initContainers:
    - name: wait-for-postgres
      image: {{ include "task-manager.postgresImage" . }}
      imagePullPolicy: IfNotPresent
      command: ["sh", "-c", "until pg_isready -h {{ $pgHost }} -p {{ .Values.postgresql.service.port }}; do echo 'waiting for postgres'; sleep 2; done"]
      resources:
        requests:
          cpu: 10m
          memory: 16Mi
        limits:
          cpu: 100m
          memory: 64Mi
  containers:
    - name: tasks-service
      image: {{ include "task-manager.image" (dict "ctx" $ "image" $v.image) }}
      imagePullPolicy: {{ .Values.image.pullPolicy }}
      ports:
        - containerPort: {{ $v.containerPort }}
      env:
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef:
              name: {{ include "task-manager.secretName" . }}
              key: DATABASE_URL
      lifecycle:
        preStop:
          exec:
            command: ["sleep", "10"]
      resources:
        {{- toYaml $v.resources | nindent 8 }}
      readinessProbe:
        httpGet:
          path: /ready
          port: {{ $v.containerPort }}
        initialDelaySeconds: 3
        periodSeconds: 5
      livenessProbe:
        httpGet:
          path: /health
          port: {{ $v.containerPort }}
        initialDelaySeconds: 30
        periodSeconds: 10
{{- end }}
