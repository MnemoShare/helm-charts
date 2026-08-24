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
{{/*
Validates that a deployment-mode string is one of the three accepted values.
Bail loudly at install/template time if not — silently mis-typed modes
(e.g. "incluster" / "in-cluster" / "InCluster") would otherwise cause
every gate to evaluate false, no workloads to render, and no error.

`inCluster` being camelCase while `external` / `disabled` are lowercase
makes this error-prone, so the validator is strict on exact match.

Usage: pass a dict {mode: <string>, field: <values-path>} for the error message.
*/}}
{{- define "mnemoshare.validateMode" -}}
{{- $mode := .mode -}}
{{- $field := .field -}}
{{- if and $mode (not (has $mode (list "inCluster" "external" "disabled"))) -}}
{{- fail (printf "%s must be one of: inCluster, external, disabled (got %q). Note: inCluster is camelCase; external and disabled are lowercase." $field $mode) -}}
{{- end -}}
{{- end }}

{{- define "mnemoshare.redisMode" -}}
{{- include "mnemoshare.validateMode" (dict "mode" .Values.redis.mode "field" "redis.mode") -}}
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
{{- include "mnemoshare.validateMode" (dict "mode" .Values.clamav.mode "field" "clamav.mode") -}}
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
{{- include "mnemoshare.validateMode" (dict "mode" .Values.stepCA.mode "field" "stepCA.mode") -}}
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
{{- /* DATA_PLANE_KMS_* (MSC-391). Defaults to the app's builtin MKEK when
       provider is unset; SaaS tenants populate provider=aws_kms +
       keyID=alias/msaas/<id> via the operator. Without these, the app
       defaults to provider="" = Builtin, which means an envelopeEnabled=true
       tenant SILENTLY routes through the builtin MKEK derived from
       ENCRYPTION_KEY instead of the per-tenant CMK — bypassing the entire
       KeyGuard isolation model. All four are emitted only when set, so
       legacy / self-hosted installs without an explicit KMS block are
       unaffected. */}}
{{- if and .Values.kms .Values.kms.dataPlaneProvider }}
- name: DATA_PLANE_KMS_PROVIDER
  value: {{ .Values.kms.dataPlaneProvider | quote }}
{{- end }}
{{- if and .Values.kms .Values.kms.dataPlaneKeyID }}
- name: DATA_PLANE_KMS_KEY_ID
  value: {{ .Values.kms.dataPlaneKeyID | quote }}
{{- end }}
{{- if and .Values.kms .Values.kms.dataPlaneRegion }}
- name: DATA_PLANE_KMS_REGION
  value: {{ .Values.kms.dataPlaneRegion | quote }}
{{- end }}
{{- if and .Values.kms .Values.kms.dataPlaneLogicalKeyID }}
- name: DATA_PLANE_KMS_LOGICAL_KEY_ID
  value: {{ .Values.kms.dataPlaneLogicalKeyID | quote }}
{{- end }}
{{- if and .Values.kms .Values.kms.jwtSignerType }}
- name: JWT_SIGNER_TYPE
  value: {{ .Values.kms.jwtSignerType | quote }}
{{- end }}
{{- if and .Values.kms .Values.kms.jwtSigningKeyID }}
- name: JWT_SIGNING_KEY_ID
  value: {{ .Values.kms.jwtSigningKeyID | quote }}
{{- end }}
{{- /* PADES_SIGNING_* (MNS-664/MNS-723). BYOK PAdES document signing with a
       customer-owned CMK reached cross-account by assuming the role in the
       customer's account. Emitted only when set; unset leaves the app on its
       in-pod software signer. ExternalID is optional (confused-deputy guard). */}}
{{- if and .Values.kms .Values.kms.padesSignerType }}
- name: PADES_SIGNER_TYPE
  value: {{ .Values.kms.padesSignerType | quote }}
{{- end }}
{{- if and .Values.kms .Values.kms.padesSigningKeyID }}
- name: PADES_SIGNING_KEY_ID
  value: {{ .Values.kms.padesSigningKeyID | quote }}
{{- end }}
{{- if and .Values.kms .Values.kms.padesSigningRegion }}
- name: PADES_SIGNING_KMS_REGION
  value: {{ .Values.kms.padesSigningRegion | quote }}
{{- end }}
{{- if and .Values.kms .Values.kms.padesRoleARN }}
- name: PADES_SIGNING_KMS_ROLE_ARN
  value: {{ .Values.kms.padesRoleARN | quote }}
{{- end }}
{{- if and .Values.kms .Values.kms.padesExternalID }}
- name: PADES_SIGNING_KMS_EXTERNAL_ID
  value: {{ .Values.kms.padesExternalID | quote }}
{{- end }}
{{- end }}

{{/*
Threat-feed env for the ICES threat-scanning lane. Emits nothing unless
.Values.threatFeed.enabled is true, so pods on installs that don't opt in
carry no THREATFEED_* vars at all. When enabled, the abuse.ch feeds
(URLhaus, Feodo Tracker) are each independently gate-able, and an optional
custom feed can be pointed at any URL. Feeds are refreshed on an interval.

Usage:
  env:
    {{- include "mnemoshare.threatfeedEnv" . | nindent 8 }}

Values consumed (only when .Values.threatFeed.enabled):
  - .Values.threatFeed.refreshSec
  - .Values.threatFeed.urlhaus.enabled, .Values.threatFeed.urlhaus.url
  - .Values.threatFeed.feodo.enabled, .Values.threatFeed.feodo.url
  - .Values.threatFeed.custom.url, .kind, .name
*/}}
{{- define "mnemoshare.threatfeedEnv" -}}
{{- if .Values.threatFeed.enabled }}
- name: THREATFEED_ENABLED
  value: "true"
- name: THREATFEED_REFRESH_SEC
  value: {{ .Values.threatFeed.refreshSec | default 3600 | quote }}
{{- if .Values.threatFeed.urlhaus.enabled }}
- name: THREATFEED_URLHAUS_ENABLED
  value: "true"
{{- if .Values.threatFeed.urlhaus.url }}
- name: THREATFEED_URLHAUS_URL
  value: {{ .Values.threatFeed.urlhaus.url | quote }}
{{- end }}
{{- end }}
{{- if .Values.threatFeed.feodo.enabled }}
- name: THREATFEED_FEODO_ENABLED
  value: "true"
{{- if .Values.threatFeed.feodo.url }}
- name: THREATFEED_FEODO_URL
  value: {{ .Values.threatFeed.feodo.url | quote }}
{{- end }}
{{- end }}
{{- if .Values.threatFeed.custom.url }}
- name: THREATFEED_CUSTOM_URL
  value: {{ .Values.threatFeed.custom.url | quote }}
{{- if .Values.threatFeed.custom.kind }}
- name: THREATFEED_CUSTOM_KIND
  value: {{ .Values.threatFeed.custom.kind | quote }}
{{- end }}
{{- if .Values.threatFeed.custom.name }}
- name: THREATFEED_CUSTOM_NAME
  value: {{ .Values.threatFeed.custom.name | quote }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Tiered platform-email + SES env (MNS-954). Shared by the api Deployment and any
background engine that sends platform email (worker, ices) — they MUST match the
api's surface or the engine silently can't send.
*/}}
{{- define "mnemoshare.platformEmailEnv" -}}
{{- if .Values.platformEmail.transport }}
- name: PLATFORM_EMAIL_TRANSPORT
  value: {{ .Values.platformEmail.transport | quote }}
{{- end }}
{{- if .Values.platformEmail.fromAddress }}
- name: PLATFORM_EMAIL_FROM_ADDRESS
  value: {{ .Values.platformEmail.fromAddress | quote }}
- name: PLATFORM_EMAIL_FROM_NAME
  value: {{ .Values.platformEmail.fromName | quote }}
{{- end }}
{{- if .Values.platformEmail.ses.region }}
- name: PLATFORM_EMAIL_SES_REGION
  value: {{ .Values.platformEmail.ses.region | quote }}
{{- end }}
{{- if or .Values.platformEmail.ses.accessKeyId .Values.existingSecrets.platformEmailSes }}
- name: PLATFORM_EMAIL_SES_ACCESS_KEY_ID
  valueFrom:
    secretKeyRef:
      name: {{ if .Values.existingSecrets.platformEmailSes }}{{ .Values.existingSecrets.platformEmailSes }}{{ else }}{{ include "mnemoshare.fullname" . }}-secrets{{ end }}
      key: platform-email-ses-access-key-id
- name: PLATFORM_EMAIL_SES_SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: {{ if .Values.existingSecrets.platformEmailSes }}{{ .Values.existingSecrets.platformEmailSes }}{{ else }}{{ include "mnemoshare.fullname" . }}-secrets{{ end }}
      key: platform-email-ses-secret-key
{{- end }}
{{- if .Values.sesAdmin.region }}
- name: SES_ADMIN_REGION
  value: {{ .Values.sesAdmin.region | quote }}
{{- end }}
{{- if .Values.sesAdmin.roleArn }}
- name: SES_ADMIN_ROLE_ARN
  value: {{ .Values.sesAdmin.roleArn | quote }}
{{- end }}
{{- if or .Values.sesAdmin.accessKeyId .Values.existingSecrets.sesAdmin }}
- name: SES_ADMIN_ACCESS_KEY_ID
  valueFrom:
    secretKeyRef:
      name: {{ if .Values.existingSecrets.sesAdmin }}{{ .Values.existingSecrets.sesAdmin }}{{ else }}{{ include "mnemoshare.fullname" . }}-secrets{{ end }}
      key: ses-admin-access-key-id
- name: SES_ADMIN_SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: {{ if .Values.existingSecrets.sesAdmin }}{{ .Values.existingSecrets.sesAdmin }}{{ else }}{{ include "mnemoshare.fullname" . }}-secrets{{ end }}
      key: ses-admin-secret-key
{{- end }}
{{- if .Values.sesEvents.snsTopicArn }}
- name: SES_EVENTS_SNS_TOPIC_ARN
  value: {{ .Values.sesEvents.snsTopicArn | quote }}
{{- end }}
{{- if or .Values.sesEvents.webhookToken .Values.existingSecrets.sesEvents }}
- name: SES_EVENTS_WEBHOOK_TOKEN
  valueFrom:
    secretKeyRef:
      name: {{ if .Values.existingSecrets.sesEvents }}{{ .Values.existingSecrets.sesEvents }}{{ else }}{{ include "mnemoshare.fullname" . }}-secrets{{ end }}
      key: ses-events-webhook-token
{{- end }}
{{- end }}

{{/*
Mail-monitoring env for whichever engine hosts it (worker when embedded, or the
standalone ices pod). Webhook URLs default to <appUrl>/api/v1/integrations/cloud/webhook/*.
*/}}
{{- define "mnemoshare.mailMonitoringEnv" -}}
{{- if .Values.mailMonitoring.enabled }}
{{- $base := trimSuffix "/" (.Values.appUrl | default "") -}}
{{- /* Gate each URL independently: an explicitly-set webhook URL must emit
       even when appUrl (and thus $base) is empty. */ -}}
{{- if or $base .Values.mailMonitoring.googleWebhookUrl }}
- name: GOOGLE_WEBHOOK_URL
  value: {{ .Values.mailMonitoring.googleWebhookUrl | default (printf "%s/api/v1/integrations/cloud/webhook/google" $base) | quote }}
{{- end }}
{{- if or $base .Values.mailMonitoring.microsoftWebhookUrl }}
- name: MICROSOFT_WEBHOOK_URL
  value: {{ .Values.mailMonitoring.microsoftWebhookUrl | default (printf "%s/api/v1/integrations/cloud/webhook/microsoft" $base) | quote }}
{{- end }}
- name: GOOGLE_MAIL_ENROLLMENT_INTERVAL_SEC
  value: {{ .Values.mailMonitoring.enrollmentIntervalSec | default 60 | quote }}
- name: GOOGLE_INTERNAL_MAIL_INTERVAL_SEC
  value: {{ .Values.mailMonitoring.internalMailIntervalSec | default 60 | quote }}
- name: GOOGLE_INTERNAL_MAIL_WATCH_INTERVAL_SEC
  value: {{ .Values.mailMonitoring.internalMailWatchIntervalSec | default 90 | quote }}
{{- end }}
{{- end }}

{{/*
API callback env for a background engine (worker/ices) that calls the app API.
Emitted ONLY when explicitly configured (apiUrl / apiKey / existingAPIKeySecret)
so SaaS tenants whose reconciler injects these via ConfigMap are untouched.
apiUrl defaults to the in-cluster service; the key comes from a secret when
existingAPIKeySecret is set, else an inline apiKey.
*/}}
{{- define "mnemoshare.workerApiCallbackEnv" -}}
{{- if or .Values.workflowWorker.apiUrl .Values.workflowWorker.apiKey .Values.workflowWorker.existingAPIKeySecret }}
- name: MNEMOSHARE_API_URL
  value: {{ .Values.workflowWorker.apiUrl | default (printf "http://%s:%v/api/v1" (include "mnemoshare.fullname" .) .Values.service.port) | quote }}
{{- if .Values.workflowWorker.existingAPIKeySecret }}
- name: MNEMOSHARE_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.workflowWorker.existingAPIKeySecret }}
      key: {{ .Values.workflowWorker.apiKeySecretKey | default "gateway-api-key" }}
{{- else if .Values.workflowWorker.apiKey }}
- name: MNEMOSHARE_API_KEY
  value: {{ .Values.workflowWorker.apiKey | quote }}
{{- end }}
{{- end }}
{{- end }}
