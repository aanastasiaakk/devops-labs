{{- define "task-manager.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "task-manager.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "task-manager.componentName" -}}
{{- printf "%s-%s" (include "task-manager.fullname" .ctx) .component | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "task-manager.configName" -}}
{{- printf "%s-config" (include "task-manager.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Ім'я Secret з паролем БД. Якщо задано existingSecret (ЛР-5, GitOps), чарт Secret не створює,
а всі Deployment посилаються на Secret, створений вручну в кластері: паролів у Git немає.
*/}}
{{- define "task-manager.secretName" -}}
{{- if .Values.existingSecret }}
{{- .Values.existingSecret }}
{{- else }}
{{- printf "%s-secret" (include "task-manager.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "task-manager.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "task-manager.selectorLabels" -}}
app.kubernetes.io/name: {{ include "task-manager.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "task-manager.labels" -}}
helm.sh/chart: {{ include "task-manager.chart" . }}
{{ include "task-manager.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | default .Chart.AppVersion | toString | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: task-manager
{{- end }}

{{- define "task-manager.componentSelectorLabels" -}}
{{ include "task-manager.selectorLabels" .ctx }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{- define "task-manager.componentLabels" -}}
{{ include "task-manager.labels" .ctx }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{- define "task-manager.image" -}}
{{- $tag := .image.tag | default .ctx.Values.image.tag | default .ctx.Chart.AppVersion }}
{{- printf "%s:%s" .image.repository (toString $tag) }}
{{- end }}

{{- define "task-manager.postgresImage" -}}
{{- printf "%s:%s" .Values.postgresql.image.repository (toString .Values.postgresql.image.tag) }}
{{- end }}
