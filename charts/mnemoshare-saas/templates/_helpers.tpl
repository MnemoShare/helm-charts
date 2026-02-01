{{/*
Expand the name of the chart.
*/}}
{{- define "mnemoshare-saas.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name using customer ID.
*/}}
{{- define "mnemoshare-saas.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if .Values.customer.id }}
{{- printf "%s-%s" .Values.customer.id $name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "mnemoshare-saas.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "mnemoshare-saas.labels" -}}
helm.sh/chart: {{ include "mnemoshare-saas.chart" . }}
{{ include "mnemoshare-saas.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
mnemoshare.io/customer-id: {{ .Values.customer.id | quote }}
mnemoshare.io/tier: {{ .Values.tier | quote }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "mnemoshare-saas.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mnemoshare-saas.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "mnemoshare-saas.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "mnemoshare-saas.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Get the database name (auto-generate from customer ID if not set)
*/}}
{{- define "mnemoshare-saas.databaseName" -}}
{{- if .Values.database.name }}
{{- .Values.database.name }}
{{- else }}
{{- printf "mnemoshare-saas-%s" .Values.customer.id }}
{{- end }}
{{- end }}

{{/*
Get the S3 prefix for this customer
For dedicated buckets (Enterprise), no prefix needed
For shared bucket (all other tiers), use customer prefix
*/}}
{{- define "mnemoshare-saas.storagePrefix" -}}
{{- if .Values.storage.prefix }}
{{- .Values.storage.prefix }}
{{- else if or .Values.storage.dedicatedBucket (eq .Values.tier "enterprise") }}
{{- /* Enterprise tier with dedicated bucket: no prefix */ -}}
{{- "" }}
{{- else }}
{{- printf "customers/%s/" .Values.customer.id }}
{{- end }}
{{- end }}

{{/*
Get the S3 bucket name
For Enterprise tier, auto-generate dedicated bucket name if not specified
*/}}
{{- define "mnemoshare-saas.storageBucket" -}}
{{- if .Values.storage.bucket }}
{{- .Values.storage.bucket }}
{{- else if or .Values.storage.dedicatedBucket (eq .Values.tier "enterprise") }}
{{- printf "mnemoshare-%s" .Values.customer.id }}
{{- else }}
{{- "mnemoshare-saas" }}
{{- end }}
{{- end }}

{{/*
Get the customer's full URL
*/}}
{{- define "mnemoshare-saas.appUrl" -}}
{{- printf "https://%s.%s" .Values.customer.subdomain .Values.ingress.domainSuffix }}
{{- end }}

{{/*
Get tier-specific resource limits for app
*/}}
{{- define "mnemoshare-saas.appResources" -}}
{{- if .Values.app.resources }}
{{- toYaml .Values.app.resources }}
{{- else }}
{{- $tierConfig := index .Values.tiers .Values.tier }}
{{- toYaml $tierConfig.app.resources }}
{{- end }}
{{- end }}

{{/*
Get tier-specific replica count for app
*/}}
{{- define "mnemoshare-saas.appReplicas" -}}
{{- if .Values.app.replicas }}
{{- .Values.app.replicas }}
{{- else }}
{{- $tierConfig := index .Values.tiers .Values.tier }}
{{- $tierConfig.app.replicas }}
{{- end }}
{{- end }}

{{/*
Check if workflow worker should be enabled (tier-based or explicit)
*/}}
{{- define "mnemoshare-saas.workflowWorkerEnabled" -}}
{{- if .Values.workflowWorker.enabled -}}
true
{{- else -}}
{{- $tierConfig := index .Values.tiers .Values.tier -}}
{{- if $tierConfig.workflowWorker.enabled -}}
true
{{- else -}}
false
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Get tier-specific resource limits for workflow worker
*/}}
{{- define "mnemoshare-saas.workflowWorkerResources" -}}
{{- if .Values.workflowWorker.resources }}
{{- toYaml .Values.workflowWorker.resources }}
{{- else }}
{{- $tierConfig := index .Values.tiers .Values.tier }}
{{- if $tierConfig.workflowWorker.resources }}
{{- toYaml $tierConfig.workflowWorker.resources }}
{{- else }}
requests:
  cpu: 500m
  memory: 1Gi
limits:
  cpu: 2000m
  memory: 2Gi
{{- end }}
{{- end }}
{{- end }}

{{/*
Get tier-specific max replicas for autoscaling
*/}}
{{- define "mnemoshare-saas.maxReplicas" -}}
{{- $tierConfig := index .Values.tiers .Values.tier }}
{{- $tierConfig.autoscaling.maxReplicas }}
{{- end }}

{{/*
Secrets name helper
*/}}
{{- define "mnemoshare-saas.secretsName" -}}
{{ include "mnemoshare-saas.fullname" . }}-secrets
{{- end }}

{{/*
Extract Redis Sentinel addresses from URL
Format: redis+sentinel://:<password>@node-0:26379,node-1:26379,node-2:26379/mymaster/0
Returns: node-0:26379,node-1:26379,node-2:26379
*/}}
{{- define "mnemoshare-saas.redisSentinelAddresses" -}}
{{- $url := .Values.redis.url }}
{{- if $url }}
{{- $noProto := regexReplaceAll "^redis\\+sentinel://[^@]*@" $url "" }}
{{- $noMaster := regexReplaceAll "/mymaster.*$" $noProto "" }}
{{- $noMaster }}
{{- end }}
{{- end }}

{{/*
Extract Redis password from URL
Format: redis+sentinel://:<password>@node-0:26379,.../mymaster/0
Returns: password
*/}}
{{- define "mnemoshare-saas.redisPassword" -}}
{{- $url := .Values.redis.url -}}
{{- if $url -}}
{{- $afterProto := regexReplaceAll "^[^:]+://" $url "" -}}
{{- $authPart := regexFind "^[^@]+" $afterProto -}}
{{- if $authPart -}}
{{- $authPart | trimPrefix ":" -}}
{{- end -}}
{{- end -}}
{{- end }}
