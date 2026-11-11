{{/* Database env shared by every gateway pod that opens the application database. */}}
{{- define "mnemoshare.databaseEnv" -}}
- name: DB_DRIVER
  value: {{ .Values.database.driver | default "mongodb" | quote }}
{{- if eq (.Values.database.driver | default "mongodb") "mongodb" }}
- name: MONGODB_URI
  valueFrom:
    secretKeyRef:
      name: {{ if .Values.existingSecrets.mongodb }}{{ .Values.existingSecrets.mongodb }}{{ else }}{{ include "mnemoshare.fullname" . }}-secrets{{ end }}
      key: mongodb-uri
- name: MONGODB_DATABASE
  value: {{ .Values.mongodb.external.database | quote }}
{{- else if eq .Values.database.driver "postgres" }}
- name: POSTGRES_DSN
  valueFrom:
    secretKeyRef:
      name: {{ if .Values.existingSecrets.postgres }}{{ .Values.existingSecrets.postgres }}{{ else }}{{ include "mnemoshare.fullname" . }}-secrets{{ end }}
      key: postgres-dsn
{{- end }}
{{- end -}}

{{/* Object storage env shared by every gateway pod that opens the application bucket. */}}
{{- define "mnemoshare.storageEnv" -}}
{{- if .Values.minio.enabled -}}
# MinIO is enabled - use internal MinIO service endpoint
- name: S3_ENDPOINT
  value: "{{ include "mnemoshare.fullname" . }}-minio:9000"
- name: S3_REGION
  value: "us-east-1"
- name: S3_BUCKET
  value: {{ .Values.s3.bucket | default "mnemoshare" | quote }}
- name: S3_USE_SSL
  value: "false"
- name: S3_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ if .Values.minio.existingSecret }}{{ .Values.minio.existingSecret }}{{ else }}{{ include "mnemoshare.fullname" . }}-minio{{ end }}
      key: rootUser
- name: S3_SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: {{ if .Values.minio.existingSecret }}{{ .Values.minio.existingSecret }}{{ else }}{{ include "mnemoshare.fullname" . }}-minio{{ end }}
      key: rootPassword
{{- else -}}
# External S3-compatible storage
- name: S3_ENDPOINT
  value: {{ .Values.s3.endpoint | quote }}
- name: S3_REGION
  value: {{ .Values.s3.region | quote }}
- name: S3_BUCKET
  value: {{ .Values.s3.bucket | quote }}
- name: S3_USE_SSL
  value: {{ .Values.s3.useSSL | quote }}
- name: S3_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ if .Values.existingSecrets.s3 }}{{ .Values.existingSecrets.s3 }}{{ else }}{{ include "mnemoshare.fullname" . }}-secrets{{ end }}
      key: s3-access-key
- name: S3_SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: {{ if .Values.existingSecrets.s3 }}{{ .Values.existingSecrets.s3 }}{{ else }}{{ include "mnemoshare.fullname" . }}-secrets{{ end }}
      key: s3-secret-key
{{- end }}
{{- end -}}
