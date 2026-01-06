{{/*
Expand the name of the chart.
*/}}
{{- define "mnemoshare.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "mnemoshare.fullname" -}}
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
{{- define "mnemoshare.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "mnemoshare.labels" -}}
helm.sh/chart: {{ include "mnemoshare.chart" . }}
{{ include "mnemoshare.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "mnemoshare.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mnemoshare.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "mnemoshare.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "mnemoshare.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Generate JWT secret - use provided value or auto-generate
*/}}
{{- define "mnemoshare.jwtSecret" -}}
{{- if .Values.jwt.secret }}
{{- .Values.jwt.secret }}
{{- else }}
{{- randAlphaNum 64 }}
{{- end }}
{{- end }}

{{/*
Generate encryption key - use provided value or auto-generate (must be exactly 32 bytes)
*/}}
{{- define "mnemoshare.encryptionKey" -}}
{{- if .Values.encryption.key }}
{{- .Values.encryption.key }}
{{- else }}
{{- randAlphaNum 32 }}
{{- end }}
{{- end }}
