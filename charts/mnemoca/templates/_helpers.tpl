{{- define "mnemoca.name" -}}
{{- .Chart.Name -}}
{{- end -}}

{{- define "mnemoca.fullname" -}}
{{- if contains .Chart.Name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "mnemoca.labels" -}}
app.kubernetes.io/name: {{ include "mnemoca.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.image.tag | default .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "mnemoca.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mnemoca.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "mnemoca.image" -}}
{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}
{{- end -}}

{{/* Environment shared by the server pods and the init Job. */}}
{{- define "mnemoca.env" -}}
- name: MNEMOCA_DATA
  value: /data
- name: MNEMOCA_DB
  value: {{ .Values.storage.backend | quote }}
- name: MNEMOCA_PASSPHRASE
  valueFrom:
    secretKeyRef:
      name: {{ required "ca.existingSecret is required (Secret with key \"passphrase\")" .Values.ca.existingSecret }}
      key: passphrase
{{- if eq .Values.storage.backend "mongo" }}
- name: MNEMOCA_MONGO_DATABASE
  value: {{ .Values.storage.mongo.database | quote }}
{{- if .Values.storage.mongo.existingSecret }}
- name: MNEMOCA_MONGO_URI
  valueFrom:
    secretKeyRef:
      name: {{ .Values.storage.mongo.existingSecret }}
      key: uri
{{- else }}
- name: MNEMOCA_MONGO_URI
  value: {{ required "storage.mongo.uri or storage.mongo.existingSecret is required in mongo mode" .Values.storage.mongo.uri | quote }}
{{- end }}
{{- end }}
{{- with .Values.extraEnv }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/* Server args. */}}
{{- define "mnemoca.serveArgs" -}}
- serve
- --listen=:{{ .Values.service.port }}
{{- if .Values.ca.externalURL }}
- --external-url={{ .Values.ca.externalURL }}
{{- end }}
{{- if .Values.ca.acmeEAB }}
- --acme-eab
{{- end }}
{{- end -}}
