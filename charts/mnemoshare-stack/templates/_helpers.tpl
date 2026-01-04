{{/*
Expand the name of the chart.
*/}}
{{- define "mnemoshare-stack.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "mnemoshare-stack.fullname" -}}
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
Common labels
*/}}
{{- define "mnemoshare-stack.labels" -}}
helm.sh/chart: {{ include "mnemoshare-stack.name" . }}-{{ .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "mnemoshare-stack.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
PostgreSQL connection string
*/}}
{{- define "mnemoshare-stack.postgresqlDsn" -}}
{{- if .Values.postgresql.enabled }}
postgres://{{ .Values.postgresql.auth.username }}:{{ .Values.postgresql.auth.password }}@{{ .Release.Name }}-postgresql:5432/{{ .Values.postgresql.auth.database }}?sslmode=disable
{{- else if .Values.externalDatabase.dsn }}
{{- .Values.externalDatabase.dsn }}
{{- else }}
postgres://{{ .Values.externalDatabase.username }}:{{ .Values.externalDatabase.password }}@{{ .Values.externalDatabase.host }}:{{ .Values.externalDatabase.port }}/{{ .Values.externalDatabase.database }}?sslmode=require
{{- end }}
{{- end }}

{{/*
S3 endpoint
*/}}
{{- define "mnemoshare-stack.s3Endpoint" -}}
{{- if .Values.minio.enabled }}
{{- .Release.Name }}-minio:9000
{{- else }}
{{- .Values.externalStorage.endpoint }}
{{- end }}
{{- end }}

{{/*
S3 credentials
*/}}
{{- define "mnemoshare-stack.s3AccessKey" -}}
{{- if .Values.minio.enabled }}
{{- .Values.minio.auth.rootUser }}
{{- else }}
{{- .Values.externalStorage.accessKey }}
{{- end }}
{{- end }}

{{- define "mnemoshare-stack.s3SecretKey" -}}
{{- if .Values.minio.enabled }}
{{- .Values.minio.auth.rootPassword }}
{{- else }}
{{- .Values.externalStorage.secretKey }}
{{- end }}
{{- end }}

{{- define "mnemoshare-stack.s3Bucket" -}}
{{- if .Values.minio.enabled }}
{{- .Values.minio.defaultBuckets | default "mnemoshare-files" }}
{{- else }}
{{- .Values.externalStorage.bucket }}
{{- end }}
{{- end }}

{{- define "mnemoshare-stack.s3UseSSL" -}}
{{- if .Values.minio.enabled }}
false
{{- else }}
{{- .Values.externalStorage.useSSL | default true }}
{{- end }}
{{- end }}

{{/*
ClamAV ICAP URL
*/}}
{{- define "mnemoshare-stack.clamavUrl" -}}
{{- if .Values.clamav.enabled }}
icap://{{ include "mnemoshare-stack.fullname" . }}-clamav:1344/avscan
{{- else }}
""
{{- end }}
{{- end }}

{{/*
Generate a random string for secrets if not provided
*/}}
{{- define "mnemoshare-stack.jwtSecret" -}}
{{- if .Values.mnemoshare.jwt.secret }}
{{- .Values.mnemoshare.jwt.secret }}
{{- else }}
{{- randAlphaNum 64 }}
{{- end }}
{{- end }}

{{- define "mnemoshare-stack.encryptionKey" -}}
{{- if .Values.mnemoshare.encryption.key }}
{{- .Values.mnemoshare.encryption.key }}
{{- else }}
{{- randAlphaNum 32 }}
{{- end }}
{{- end }}
