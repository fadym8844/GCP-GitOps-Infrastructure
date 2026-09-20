{{/*
Expand the name of the chart.
*/}}
{{- define "service.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "service.fullname" -}} 
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

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "service.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "service.labels" -}}
helm.sh/chart: {{ include "service.chart" . }}
{{ include "service.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "service.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "service.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "service.image.repository" -}}
{{- if .Values.image.repository }}
{{- .Values.image.repository }}
{{- else }}
{{- /* GCP fork: confirm core-platform-workload-prod matches the real project ID once terraform apply runs */ -}}
{{- printf "me-central2-docker.pkg.dev/core-platform-workload-prod/core-platform/core-platform-%s" .Release.Name }}
{{- end }}
{{- end }}

{{/*
Secret volumes
*/}}
{{- define "service.secrets.volumes" -}}
{{- $fullName := include "service.fullname" . -}}
{{- range $key, $value := .Values.secrets }}
- name: {{ $fullName }}-{{ $key }}
  secret:
    secretName: {{ $fullName }}-{{ $key }}
{{- if $value.defaultMode }}
    defaultMode: {{ $value.defaultMode }}
{{- end }}
{{- end }}
{{- end }}


{{/*
Secret data
*/}}
{{- define "service.secrets.volumeMounts" -}}
{{- $fullName := include "service.fullname" . -}}
{{- range $key, $value := .Values.secrets }}
- name: {{ $fullName }}-{{ $key }}
  mountPath: {{ $value.mountPath }}
{{- end }}
{{- end }}
