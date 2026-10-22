{{/*
Egress building blocks. Invariant: every rendered egress rule carries explicit
`ports:`. Nothing here may emit an any-port rule (hack/check-egress.py enforces).
*/}}

{{- define "mnemoshare.np.privateExcept" -}}
- 10.0.0.0/8
- 172.16.0.0/12
- 192.168.0.0/16
- 169.254.0.0/16
- 100.64.0.0/10
{{- end -}}

{{/* Public internet minus private ranges, IMDS (169.254/16) and Tailscale CGNAT. */}}
{{- define "mnemoshare.np.publicPeer" -}}
- ipBlock:
    cidr: 0.0.0.0/0
    except:
      {{- include "mnemoshare.np.privateExcept" . | nindent 6 }}
{{- end -}}

{{/*
mnemoshare.np.rule - args: ports (list), public (bool), cidrs (list), anyDest (bool).
Peers: public => internet (plus cidrs); else cidrs only; else, only when anyDest,
no `to` (any destination, restricted to ports). Renders nothing without ports.
*/}}
{{- define "mnemoshare.np.rule" -}}
{{- $cidrs := .cidrs | default list -}}
{{- if and .ports (or .public $cidrs .anyDest) }}
- ports:
    {{- range .ports }}
    - protocol: TCP
      port: {{ . }}
    {{- end }}
  {{- if or .public $cidrs }}
  to:
    {{- range $cidrs }}
    - ipBlock:
        cidr: {{ . | quote }}
    {{- end }}
    {{- if .public }}
    {{- include "mnemoshare.np.publicPeer" . | nindent 4 }}
    {{- end }}
  {{- end }}
{{- end }}
{{- end -}}

{{/* Merge a legacy single `cidr` string and a `cidrs` list into one JSON list. */}}
{{- define "mnemoshare.np.cidrs" -}}
{{- $out := list -}}
{{- if .cidr }}{{ $out = append $out .cidr }}{{ end -}}
{{- range (.cidrs | default list) }}{{ $out = append $out . }}{{ end -}}
{{- $out | uniq | toJson -}}
{{- end -}}

{{/* Default database port by database.driver (JSON-free: prints the number). */}}
{{- define "mnemoshare.np.dbPort" -}}
{{- $np := .Values.networkPolicy -}}
{{- $d := .Values.database.driver | default "mongodb" -}}
{{- if and $np.database $np.database.port -}}{{ $np.database.port }}
{{- else if eq $d "mongodb" -}}{{ $np.mongodb.port | default 27017 }}
{{- else if eq $d "postgres" -}}5432
{{- else if eq $d "mysql" -}}3306
{{- else if eq $d "mssql" -}}1433
{{- else if eq $d "oracle" -}}1521
{{- else if eq $d "db2" -}}50000
{{- else if eq $d "sqlite" -}}0
{{- else -}}{{ fail (printf "networkPolicy: unknown database.driver %q (set networkPolicy.database.port to override)" $d) }}
{{- end -}}
{{- end -}}

{{/* Database egress. sqlite is local. No CIDR => that port to any destination. */}}
{{- define "mnemoshare.np.database" -}}
{{- $np := .Values.networkPolicy -}}
{{- $d := .Values.database.driver | default "mongodb" -}}
{{- if and (ne $d "sqlite") $np.mongodb.enabled (or (not $np.database) (ne ($np.database.enabled | toString) "false")) }}
# Database ({{ $d }})
{{- $c := dict "cidr" $np.mongodb.cidr "cidrs" (($np.database | default dict).cidrs) }}
{{- include "mnemoshare.np.rule" (dict "ports" (list (include "mnemoshare.np.dbPort" .)) "cidrs" (include "mnemoshare.np.cidrs" $c | fromJsonArray) "anyDest" true) }}
{{- end }}
{{- end -}}

{{/* Object storage: in-cluster MinIO, else S3-compatible endpoint. */}}
{{- define "mnemoshare.np.storage" -}}
{{- $np := .Values.networkPolicy -}}
{{- if .Values.minio.enabled }}
# In-cluster MinIO
- to:
    - podSelector:
        matchLabels:
          app.kubernetes.io/name: minio
  ports:
    - protocol: TCP
      port: 9000
{{- else if $np.s3.enabled }}
# S3-compatible object storage
{{- $cidrs := include "mnemoshare.np.cidrs" $np.s3 | fromJsonArray }}
{{- include "mnemoshare.np.rule" (dict "ports" ($np.s3.ports | default (list 443 9000)) "public" (not $cidrs) "cidrs" $cidrs) }}
{{- end }}
{{- end -}}

{{- define "mnemoshare.np.icap" -}}
{{- if eq (include "mnemoshare.icapMode" .) "inCluster" }}
# ClamAV ICAP (embedded)
- to:
    - podSelector:
        matchLabels:
          app.kubernetes.io/name: clamav
  ports:
    - protocol: TCP
      port: 1344
{{- else if eq (include "mnemoshare.icapMode" .) "external" }}
# ClamAV ICAP (external)
- to:
    {{- if and .Values.networkPolicy.icap .Values.networkPolicy.icap.namespace }}
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: {{ .Values.networkPolicy.icap.namespace }}
    {{- else }}
    - namespaceSelector: {}
    {{- end }}
    {{- range ((.Values.networkPolicy.icap | default dict).cidrs | default list) }}
    - ipBlock:
        cidr: {{ . | quote }}
    {{- end }}
  ports:
    - protocol: TCP
      port: 1344
{{- end }}
{{- end -}}

{{- define "mnemoshare.np.redis" -}}
{{- if eq (include "mnemoshare.redisMode" .) "inCluster" }}
# Redis (embedded)
- to:
    - podSelector:
        matchLabels:
          app.kubernetes.io/name: redis
  ports:
    - protocol: TCP
      port: 6379
{{- else if eq (include "mnemoshare.redisMode" .) "external" }}
# Redis (external); Sentinel port is needed for redis-sentinel:// discovery
{{- $r := (.Values.networkPolicy.redis | default dict) }}
{{- $ports := list (.Values.redis.external.port | default 6379) }}
{{- if .Values.redis.external.sentinelPort }}{{ $ports = append $ports .Values.redis.external.sentinelPort }}{{ end }}
{{- include "mnemoshare.np.rule" (dict "ports" $ports "cidrs" (include "mnemoshare.np.cidrs" $r | fromJsonArray) "anyDest" true) }}
{{- end }}
{{- end -}}

{{/* In-cluster rich-media / Tika / Presidio. targetPort, not Service port. */}}
{{- define "mnemoshare.np.dlpServices" -}}
{{- if .Values.richMedia.url }}
# Rich-media file-preview service
- to:
    {{- if and .Values.networkPolicy.richMedia .Values.networkPolicy.richMedia.namespace }}
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: {{ .Values.networkPolicy.richMedia.namespace }}
    {{- else }}
    - namespaceSelector: {}
    {{- end }}
  ports:
    - protocol: TCP
      port: {{ .Values.networkPolicy.richMedia.port | default 8080 }}
{{- end }}
{{- if .Values.dlp.tikaUrl }}
# Apache Tika
- to:
    {{- if and .Values.networkPolicy.tika .Values.networkPolicy.tika.namespace }}
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: {{ .Values.networkPolicy.tika.namespace }}
    {{- else }}
    - namespaceSelector: {}
    {{- end }}
  ports:
    - protocol: TCP
      port: {{ .Values.networkPolicy.tika.port | default 9998 }}
{{- end }}
{{- if .Values.dlp.presidioUrl }}
# Presidio
- to:
    {{- if and .Values.networkPolicy.presidio .Values.networkPolicy.presidio.namespace }}
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: {{ .Values.networkPolicy.presidio.namespace }}
    {{- else }}
    - namespaceSelector: {}
    {{- end }}
  ports:
    - protocol: TCP
      port: {{ .Values.networkPolicy.presidio.port | default 3000 }}
{{- end }}
{{- end -}}

{{- define "mnemoshare.np.dns" -}}
# DNS
- to:
    - namespaceSelector: {}
      podSelector:
        matchLabels:
          k8s-app: kube-dns
  ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
{{- end -}}

{{- define "mnemoshare.np.stepCA" -}}
# Step CA (for mTLS)
#
# ⚠ The two Step-CA deployments carry OPPOSITE labels. Verified against the
# rendered chart and the live platform CA — do not "harmonise" these:
#
#   chart-deployed (inCluster)  name=mnemoshare  component=step-ca
#   platform CA     (external)  name=step-ca     component=certificate-authority
#
# inCluster: the chart deploys Step-CA into THIS namespace, so a bare
# podSelector — which only ever matches the policy's own namespace — is right.
# It must select on COMPONENT: step-ca-deployment.yaml labels its pods with
# mnemoshare.selectorLabels (name=mnemoshare) plus component=step-ca, so the
# previous `name: step-ca` matched zero pods and this rule allowed nothing.
{{- if eq (include "mnemoshare.stepCAMode" .) "inCluster" }}
- to:
    - podSelector:
        matchLabels:
          app.kubernetes.io/component: step-ca
  ports:
    - protocol: TCP
      port: 9000
{{- end }}
{{- $stepCANP := .Values.networkPolicy.stepCA | default dict }}
{{- if and (eq (include "mnemoshare.stepCAMode" .) "external") $stepCANP.namespace }}
# external: a tenant consumes a SHARED platform Step-CA that lives in its own
# namespace. "external" means external to this RELEASE — the CA is still
# in-cluster, at step-ca.<namespace>.svc.cluster.local:9000. So it needs a
# cross-NAMESPACE allow. Neither existing branch provides one: the inCluster
# podSelector above is same-namespace only, and the broad 0.0.0.0/0 rules
# deliberately except RFC1918 (the cluster pod/service CIDRs) as an SSRF gate.
# Without this rule the sign request is silently dropped, so it surfaces as a
# 20s timeout rather than a refusal, and every PAdES signature degrades to
# unsealed (MNS-1118).
#
# namespaceSelector AND podSelector in ONE `to` entry, matching the
# licenseServer block: both must match, so this grants 9000 to the CA pods
# rather than to every pod in that namespace. The label here is
# `name: step-ca` — the PLATFORM CA's label, which is the inverse of the
# chart-deployed one above. Override networkPolicy.stepCA.podLabel if a
# platform CA is ever labelled differently; empty disables the pod narrowing
# and falls back to namespace-only.
- to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: {{ $stepCANP.namespace }}
      {{- /* hasKey, not `default`: Helm's default() treats "" as absent, so
             `podLabel: ""` would still render the selector and the documented
             escape hatch would not work. */ -}}
      {{- $podLabel := "step-ca" }}
      {{- if hasKey $stepCANP "podLabel" }}{{ $podLabel = $stepCANP.podLabel }}{{ end }}
      {{- if $podLabel }}
      podSelector:
        matchLabels:
          app.kubernetes.io/name: {{ $podLabel }}
      {{- end }}
  ports:
    - protocol: TCP
      port: {{ $stepCANP.port | default 9000 }}
{{- end }}
{{- end -}}

{{- define "mnemoshare.np.licenseServer" -}}
{{- $ls := .Values.networkPolicy.licenseServer -}}
{{- if $ls.enabled }}
# License server (public endpoint, or ingress-controller hairpin)
{{- $cidrs := include "mnemoshare.np.cidrs" $ls | fromJsonArray }}
{{- include "mnemoshare.np.rule" (dict "ports" (list 443) "public" (not $cidrs) "cidrs" $cidrs) }}
- to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: {{ .Values.networkPolicy.ingressNamespace | default "ingress-nginx" }}
  ports:
    - protocol: TCP
      port: 443
{{- if $ls.internalNamespace }}
# In-cluster license server. 8443 is the Service's targetPort: Cilium enforces
# egress against targetPort, and the public-URL fallback lands there.
- to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: {{ $ls.internalNamespace }}
      podSelector:
        matchLabels:
          app.kubernetes.io/name: license-server
  ports:
    - protocol: TCP
      port: {{ $ls.internalPort | default 8090 }}
    {{- if $ls.externalTargetPort }}
    - protocol: TCP
      port: {{ $ls.externalTargetPort }}
    {{- end }}
{{- end }}
{{- end }}
{{- end -}}

{{- define "mnemoshare.np.keyguard" -}}
# KeyGuard federation listener (MSC-381). The federation-sidecar mints AWS
# web-identity tokens against the idp-lite federation listener (mTLS). The
# sidecar has a readiness probe, so without this egress it times out and
# holds the WHOLE pod out of service — on a single-replica tenant that is a
# full outage. Listener port == targetPort (8443), so no Cilium translation.
{{- if .Values.keyguard.enabled }}
- to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: {{ .Values.keyguard.federationNamespace | default "mnemoshare-aws-sso" }}
  ports:
    - protocol: TCP
      port: {{ .Values.keyguard.federationPort | default 8443 }}
{{- end }}
{{- end -}}

{{/*
Outbound mail: SMTP relays (customer-configured) on smtp.ports.
*/}}
{{- define "mnemoshare.np.smtp" -}}
{{- if .Values.networkPolicy.smtp.enabled }}
# SMTP relays
{{- include "mnemoshare.np.rule" (dict "ports" (.Values.networkPolicy.smtp.ports | default (list 25 465 587 2525)) "public" true "cidrs" (.Values.networkPolicy.smtp.cidrs | default list)) }}
{{- end }}
{{- end -}}

{{/*
Customer-facing egress ports for a component (JSON list). The API pod hosts the
engines when no external workflow-worker exists, so it inherits the worker list.
Deprecated networkPolicy.workflows.enabled appends workflows.customerEgressPorts (never any-port).
args: root, component (api|workflowWorker|ices|emailGateway|inboundGateway)
*/}}
{{- define "mnemoshare.np.customerPorts" -}}
{{- $np := .root.Values.networkPolicy -}}
{{- $own := (index $np .component | default dict).customerEgressPorts | default list -}}
{{- $ports := $own -}}
{{- if and (eq .component "api") (or (include "mnemoshare.apiEmbeddedWorkers" .root) (not .root.Values.workflowWorker.enabled)) -}}
{{- $ports = concat $ports ($np.workflowWorker.customerEgressPorts | default list) -}}
{{- end -}}
{{- if and (has .component (list "api" "workflowWorker")) $np.workflows $np.workflows.enabled -}}
{{- $ports = concat $ports ($np.workflows.customerEgressPorts | default list) -}}
{{- end -}}
{{- $ports | uniq | toJson -}}
{{- end -}}

{{- define "mnemoshare.np.customer" -}}
{{- $np := .root.Values.networkPolicy -}}
{{- $ce := $np.customerEgress | default dict -}}
{{- $public := ne ($ce.publicInternet | toString) "false" -}}
{{- $own := (index $np .component | default dict).customerEgressCIDRs | default list -}}
{{- $cidrs := concat ($ce.cidrs | default list) $own | uniq -}}
# Customer-facing destinations (connectors, webhooks, SIEM, LLM): listed ports only
{{- include "mnemoshare.np.rule" (dict "ports" (include "mnemoshare.np.customerPorts" . | fromJsonArray) "public" $public "cidrs" $cidrs) }}
{{- $ftp := ($np.workflows | default dict).ftpPassive | default dict -}}
{{- $workerClass := or (eq .component "workflowWorker") (and (eq .component "api") (or (include "mnemoshare.apiEmbeddedWorkers" .root) (not .root.Values.workflowWorker.enabled))) -}}
{{- if and $ftp.enabled $workerClass }}
{{- if not $ftp.cidrs }}{{ fail "networkPolicy.workflows.ftpPassive.cidrs is required when ftpPassive.enabled=true (no public-any fallback)" }}{{ end }}
{{- $pr := $ftp.portRange | default dict }}
# FTP/FTPS passive data connections: server-chosen high ports, restricted to the listed servers
- ports:
    - protocol: TCP
      port: {{ $pr.start | default 1024 }}
      endPort: {{ $pr.end | default 65535 }}
  to:
    {{- range $ftp.cidrs }}
    - ipBlock:
        cidr: {{ . | quote }}
    {{- end }}
{{- end }}
{{- end -}}

{{- define "mnemoshare.np.https" -}}
{{- if or .Values.sendgrid.apiKey (eq .Values.platformEmail.transport "ses") .Values.platformEmail.ses.region .Values.sesAdmin.region }}
# SendGrid / AWS SES API
{{- include "mnemoshare.np.rule" (dict "ports" (list 443) "public" true) }}
{{- end }}
{{- if .Values.networkPolicy.oauth.enabled }}
# OAuth/SSO providers
{{- include "mnemoshare.np.rule" (dict "ports" (list 443) "public" true) }}
{{- end }}
{{- end -}}

{{/*
mnemoshare.workloadEgressRules - egress for pods running the app binary with
engines (api, workflow-worker, ices). The API hosts the engines when there is no
external worker, so the destination set is identical; only customer ports differ.
args: root, component
*/}}
{{- define "mnemoshare.workloadEgressRules" -}}
{{- $r := .root -}}
{{- include "mnemoshare.np.dns" $r }}
{{ include "mnemoshare.np.database" $r }}
{{ include "mnemoshare.np.storage" $r }}
{{ include "mnemoshare.np.icap" $r }}
{{ include "mnemoshare.np.redis" $r }}
{{ include "mnemoshare.np.dlpServices" $r }}
{{ include "mnemoshare.np.stepCA" $r }}
{{ include "mnemoshare.np.licenseServer" $r }}
{{ include "mnemoshare.np.keyguard" $r }}
{{ include "mnemoshare.np.https" $r }}
{{ include "mnemoshare.np.smtp" $r }}
{{ include "mnemoshare.np.customer" . }}
{{ include "mnemoshare.np.apiPods" $r }}
{{ include "mnemoshare.np.extraEgress" . }}
{{- end -}}

{{/* Calls to the api Service (API_BASE_URL / MNEMOSHARE_API_URL); Service port 80 lands on targetPort. */}}
{{- define "mnemoshare.np.apiPods" -}}
# MnemoShare API pods (intra-release)
- to:
    - podSelector:
        matchLabels:
          {{- include "mnemoshare.selectorLabels" . | nindent 10 }}
          app.kubernetes.io/component: api
  ports:
    - protocol: TCP
      port: {{ .Values.service.targetPort }}
    {{- if .Values.mtls.enabled }}
    - protocol: TCP
      port: {{ .Values.mtls.port | default 8443 }}
    {{- end }}
{{- end -}}

{{/* Operator-supplied raw egress rules for destinations the chart cannot model; hack/check-render.py still requires ports. args: root, component */}}
{{- define "mnemoshare.np.extraEgress" -}}
{{- with (index .root.Values.networkPolicy .component | default dict).extraEgress }}
# networkPolicy.{{ $.component }}.extraEgress
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
mnemoshare.np.fallbacks - JSON list of {id, rule, set} for every egress rule that
fell back to "its port(s) to any destination" because no destination was
configured. Single source for NOTES.txt and the networkPolicy.strict gate: keep
each condition identical to the template that renders the fallback rule.
*/}}
{{- define "mnemoshare.np.fallbacks" -}}
{{- $out := list -}}
{{- $np := .Values.networkPolicy -}}
{{- if $np.enabled -}}
{{- $d := .Values.database.driver | default "mongodb" -}}
{{- if and (ne $d "sqlite") $np.mongodb.enabled (or (not $np.database) (ne ($np.database.enabled | toString) "false")) -}}
{{- $c := dict "cidr" $np.mongodb.cidr "cidrs" (($np.database | default dict).cidrs) -}}
{{- if not (include "mnemoshare.np.cidrs" $c | fromJsonArray) -}}
{{- $out = append $out (dict "id" "database" "rule" (printf "database egress (port %s) to any destination" (include "mnemoshare.np.dbPort" .)) "set" "networkPolicy.database.cidrs") -}}
{{- end -}}
{{- end -}}
{{- if eq (include "mnemoshare.redisMode" .) "external" -}}
{{- if not (include "mnemoshare.np.cidrs" ($np.redis | default dict) | fromJsonArray) -}}
{{- $out = append $out (dict "id" "redis" "rule" "external Redis/Sentinel egress to any destination" "set" "networkPolicy.redis.cidrs") -}}
{{- end -}}
{{- end -}}
{{- if and .Values.emailGateway .Values.emailGateway.enabled -}}
{{- $relayMongo := false -}}
{{- $facts := include "mnemoshare.emailGateway" . | fromJson -}}
{{- range $facts.profile.external_universes }}{{- if eq .id "email-relay-mongo" }}{{- $relayMongo = true }}{{- end }}{{- end -}}
{{- if and (or $relayMongo .Values.emailGateway.relay.db.networkPolicyPort) (not .Values.emailGateway.relay.db.networkPolicyCIDRs) -}}
{{- $out = append $out (dict "id" "email-relay-db" "rule" (printf "email relay database egress (port %v) to any destination" .Values.emailGateway.relay.db.networkPolicyPort) "set" "emailGateway.relay.db.networkPolicyCIDRs") -}}
{{- end -}}
{{- end -}}
{{- $fm := .Values.formatMigrations -}}
{{- if ne $fm.mode "operator" -}}
{{- if and (eq $fm.mode "automatic") (not $fm.networkPolicy.databaseCIDRs) -}}
{{- $out = append $out (dict "id" "format-migration-database" "rule" "format-migration hook database egress to any destination" "set" "formatMigrations.networkPolicy.databaseCIDRs") -}}
{{- end -}}
{{- if not $fm.networkPolicy.kubernetesApiTargets -}}
{{- $out = append $out (dict "id" "format-migration-kube-api" "rule" "format-migration hook Kubernetes API egress (443, 6443) to any destination" "set" "formatMigrations.networkPolicy.kubernetesApiTargets") -}}
{{- end -}}
{{- end -}}
{{- if and .Values.sandbox.enabled (not .Values.sandbox.runner.egress.kubernetesApiTargets) -}}
{{- $out = append $out (dict "id" "sandbox-kube-api" "rule" "sandbox runner Kubernetes API egress (443, 6443) to any destination" "set" "sandbox.runner.egress.kubernetesApiTargets") -}}
{{- end -}}
{{- end -}}
{{- $out | toJson -}}
{{- end -}}
