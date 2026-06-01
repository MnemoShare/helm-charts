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
Common labels.

Emits the standard k8s recommended labels plus any user-supplied
.Values.commonLabels entries. commonLabels are deliberately NOT included
in selectorLabels: spec.selector.matchLabels is immutable on Deployment/
StatefulSet, so injecting extra labels there would break in-place upgrades
for any chart consumer (especially tenants being migrated from the
operator's old mnemoshare-saas chart).
*/}}
{{- define "mnemoshare.labels" -}}
helm.sh/chart: {{ include "mnemoshare.chart" . }}
{{ include "mnemoshare.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Selector labels — DO NOT add fields here without a migration plan.
Selector labels land in spec.selector.matchLabels which is immutable.
*/}}
{{- define "mnemoshare.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mnemoshare.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Deployment-mode helpers for optional in-cluster dependencies.

Each helper resolves the effective mode for a dependency from either the
explicit .Values.<dep>.mode field (preferred) or the legacy .enabled /
.external.enabled flags (backwards compatibility). Three possible outputs:

  inCluster — chart should render the dependency's workload templates
  external  — chart should NOT render workloads; consumer reads .external.url
  disabled  — dependency is not configured at all

Default values produce identical gate decisions to the pre-1.20 chart:
  redis.enabled=true             → inCluster      (was: rendered)
  redis.external.enabled=true    → external       (was: not rendered)
  neither                        → disabled       (was: not rendered)
  clamav.enabled=true            → inCluster
  clamav.external.enabled=true   → external
  neither                        → disabled
  stepCA.enabled=true            → inCluster
  stepCA.enabled=false           → disabled

So existing consumers see byte-identical renders. New consumers (and the
operator) should set .Values.<dep>.mode explicitly.
*/}}
{{- define "mnemoshare.redisMode" -}}
{{- if .Values.redis.mode -}}
{{- .Values.redis.mode -}}
{{- else if .Values.redis.enabled -}}
inCluster
{{- else if and .Values.redis.external .Values.redis.external.enabled -}}
external
{{- else -}}
disabled
{{- end -}}
{{- end }}

{{- define "mnemoshare.icapMode" -}}
{{- if .Values.clamav.mode -}}
{{- .Values.clamav.mode -}}
{{- else if .Values.clamav.enabled -}}
inCluster
{{- else if and .Values.clamav.external .Values.clamav.external.enabled -}}
external
{{- else -}}
disabled
{{- end -}}
{{- end }}

{{- define "mnemoshare.stepCAMode" -}}
{{- if .Values.stepCA.mode -}}
{{- .Values.stepCA.mode -}}
{{- else if .Values.stepCA.enabled -}}
inCluster
{{- else -}}
disabled
{{- end -}}
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
Generate JWT EC private key (ECDSA P-256) - use provided value or auto-generate
*/}}
{{- define "mnemoshare.jwtECKey" -}}
{{- if .Values.jwt.ecPrivateKey }}
{{- .Values.jwt.ecPrivateKey }}
{{- else }}
{{- genPrivateKey "ecdsa" }}
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

{{/*
Public MCP server URL used for OAuth callback construction and frontend
callback-host validation. Resolution order:
  1. mcp.externalUrl (explicit override)
  2. https://<first mcp.ingress.hosts[].host> if ingress is enabled
  3. empty (OAuth handler will not be registered — same as pre-OAuth behavior)
*/}}
{{- define "mnemoshare.mcpExternalUrl" -}}
{{- if .Values.mcp.externalUrl -}}
{{- .Values.mcp.externalUrl | trimSuffix "/" -}}
{{- else if and .Values.mcp.ingress.enabled .Values.mcp.ingress.hosts -}}
{{- $first := index .Values.mcp.ingress.hosts 0 -}}
{{- if $first.host -}}
{{- printf "https://%s" $first.host -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
mnemoshare.integrationEnv emits env vars for the cross-service integration
surface that cmd/api AND cmd/worker (background engine) both need: rich-media
thumbnails, Apache Tika text extraction, Presidio NER, AI-powered DLP, and
the KMS envelope flag. ICAP is handled separately in each consumer because
the api Deployment has historically rendered DEFAULT_ICAP_* from the chart's
ClamAV block; this helper only emits the integrations that are net-new to
the worker post-MNI-27.

Usage:
  env:
    {{- include "mnemoshare.integrationEnv" . | nindent 8 }}

Values consumed (all optional — only emitted when set):
  - .Values.richMedia.url, .Values.richMedia.apiKey OR .Values.richMedia.existingSecret
  - .Values.dlp.tikaUrl
  - .Values.dlp.presidioUrl, .Values.dlp.presidioApiKey
  - .Values.dlp.aiEnabled, .Values.dlp.aiProvider, .Values.dlp.aiModel
  - .Values.dlp.aiApiKey OR .Values.dlp.existingAISecret
  - .Values.kms.envelopeEnabled
*/}}
{{- define "mnemoshare.integrationEnv" -}}
{{- with .Values.richMedia -}}
{{- if .url }}
- name: RICH_MEDIA_URL
  value: {{ .url | quote }}
{{- end }}
{{- if .existingSecret }}
- name: RICH_MEDIA_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .existingSecret }}
      key: rich-media-api-key
{{- else if .apiKey }}
- name: RICH_MEDIA_API_KEY
  value: {{ .apiKey | quote }}
{{- end }}
{{- end }}
{{- with .Values.dlp -}}
{{- if .tikaUrl }}
- name: TIKA_URL
  value: {{ .tikaUrl | quote }}
{{- end }}
{{- if .presidioUrl }}
- name: PRESIDIO_ENABLED
  value: "true"
- name: PRESIDIO_URL
  value: {{ .presidioUrl | quote }}
{{- if .presidioApiKey }}
- name: PRESIDIO_API_KEY
  value: {{ .presidioApiKey | quote }}
{{- end }}
{{- end }}
- name: DLP_AI_ENABLED
  value: {{ .aiEnabled | default false | quote }}
{{- if .aiProvider }}
- name: AI_PROVIDER
  value: {{ .aiProvider | quote }}
{{- end }}
{{- if .aiModel }}
- name: AI_MODEL
  value: {{ .aiModel | quote }}
{{- end }}
{{- if .existingAISecret }}
- name: AI_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .existingAISecret }}
      key: ai-api-key
{{- else if .aiApiKey }}
- name: AI_API_KEY
  value: {{ .aiApiKey | quote }}
{{- end }}
{{- end }}
{{- /* KMS_ENVELOPE_ENABLED is emitted unconditionally; users who override
       .Values.kms to {} or nil still get the safe default so the worker
       decrypt path for existing v2-encrypted files is preserved. */}}
{{- $envelope := true }}
{{- if and .Values.kms (hasKey .Values.kms "envelopeEnabled") }}
{{- $envelope = .Values.kms.envelopeEnabled }}
{{- end }}
- name: KMS_ENVELOPE_ENABLED
  value: {{ $envelope | quote }}
{{- end }}
