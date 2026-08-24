{{/*
mnemoshare.workloadEgressRules — SINGLE SOURCE OF TRUTH for the egress rules
shared by every MnemoShare workload that runs the app binary and therefore
needs the exact same outbound reachability: the API pods (api-egress) AND the
external workflow-worker pods (workflow-worker-egress).

WHY THIS EXISTS (read before editing — this decision has been re-discovered the
hard way more than once, most recently MSA-46):

  The "worker" binary is the SAME process the API embeds. Depending on tier it
  runs in one of two topologies, but its egress needs are IDENTICAL to the API's:

    team          -> NO external worker. The API pod hosts every engine
                     in-process (FILTERED_PROCESS=*, MNS-1159): background
                     (virus scan / DLP / email queueing), messaging (the
                     workflows engine, license-gated OFF on this tier but
                     hosted), and kmsrotation (rotate/rewrap). Any egress a
                     new engine needs on this tier belongs in api-egress —
                     component=api IS the worker here.
    business      -> "workflows" feature ON but still EMBEDDED in the API pod.
                     Again covered by api-egress.
    business_plus -> "workflows" scaled OUT: a dedicated workflow-worker
                     StatefulSet (component=workflow-worker) using Redis for
                     leader election + task assignment. THESE PODS ARE NOT
                     component=api, so api-egress does NOT select them, and the
                     default-deny policy (which selects ALL mnemoshare pods)
                     blackholes their egress unless a matching worker policy
                     exists. That was MSA-46: worker pods could not reach
                     Mongo / Redis / ICAP / rich-media / the KeyGuard federation
                     listener, so scans and workflow steps silently failed.
    enterprise    -> same as business_plus, more replicas.

  RULE: the external workflow-worker's egress policy MUST mirror the API's,
  because it does everything the API's background engine does (Mongo, S3,
  ClamAV/ICAP, Redis, rich-media/Tika/Presidio, Step-CA, license-server, the
  KeyGuard federation sidecar egress, SMTP/SendGrid, etc.). Rather than keep two
  copies in sync by hand (they always drift), both api-egress and
  workflow-worker-egress `include` this template. Edit rules HERE, once.
*/}}
{{- define "mnemoshare.workloadEgressRules" -}}
# DNS resolution
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
# MongoDB (external or in-cluster)
{{- if .Values.networkPolicy.mongodb.enabled }}
- to:
    {{- if .Values.networkPolicy.mongodb.cidr }}
    - ipBlock:
        cidr: {{ .Values.networkPolicy.mongodb.cidr }}
    {{- else }}
    - namespaceSelector: {}
    {{- end }}
  ports:
    - protocol: TCP
      port: {{ .Values.networkPolicy.mongodb.port | default 27017 }}
{{- end }}
# S3/MinIO
{{- if .Values.minio.enabled }}
- to:
    - podSelector:
        matchLabels:
          app.kubernetes.io/name: minio
  ports:
    - protocol: TCP
      port: 9000
{{- else if .Values.networkPolicy.s3.enabled }}
- to:
    {{- if .Values.networkPolicy.s3.cidr }}
    - ipBlock:
        cidr: {{ .Values.networkPolicy.s3.cidr }}
    {{- else }}
    # Allow all egress to S3 (typically AWS/GCS public endpoints).
    # Excepts: RFC1918 (cluster pod/service CIDRs), 169.254.0.0/16
    # (cloud IMDS SSRF gate — AWS/GCP/Azure/DO metadata at port 80),
    # 100.64.0.0/10 (Tailscale CGNAT — must traverse the tailscale ns).
    - ipBlock:
        cidr: 0.0.0.0/0
        except:
          - 10.0.0.0/8       # RFC1918
          - 172.16.0.0/12    # RFC1918
          - 192.168.0.0/16   # RFC1918
          - 169.254.0.0/16   # Cloud IMDS SSRF gate
          - 100.64.0.0/10    # Tailscale CGNAT
    {{- end }}
  ports:
    - protocol: TCP
      port: 443
    - protocol: TCP
      port: 9000
{{- end }}
# ClamAV ICAP (embedded)
{{- if eq (include "mnemoshare.icapMode" .) "inCluster" }}
- to:
    - podSelector:
        matchLabels:
          app.kubernetes.io/name: clamav
  ports:
    - protocol: TCP
      port: 1344
{{- end }}
# ClamAV ICAP (external)
{{- if eq (include "mnemoshare.icapMode" .) "external" }}
- to:
    {{- if and .Values.networkPolicy.icap .Values.networkPolicy.icap.namespace }}
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: {{ .Values.networkPolicy.icap.namespace }}
    {{- else }}
    - namespaceSelector: {}
    {{- end }}
  ports:
    - protocol: TCP
      port: 1344
{{- end }}
# Redis (embedded)
{{- if eq (include "mnemoshare.redisMode" .) "inCluster" }}
- to:
    - podSelector:
        matchLabels:
          app.kubernetes.io/name: redis
  ports:
    - protocol: TCP
      port: 6379
{{- end }}
# Redis (external)
{{- if eq (include "mnemoshare.redisMode" .) "external" }}
- to:
    - namespaceSelector: {}
  ports:
    - protocol: TCP
      port: {{ .Values.redis.external.port | default 6379 }}
    {{- if .Values.redis.external.sentinelPort }}
    # Sentinel discovery port — required for redis-sentinel:// URLs. Without
    # this the client reaches the master on 6379 but cannot discover it via
    # Sentinel, so HA connections fail (e.g. shared Sentinel for Business+/
    # external workflow-worker tenants).
    - protocol: TCP
      port: {{ .Values.redis.external.sentinelPort }}
    {{- end }}
{{- end }}
{{- if .Values.richMedia.url }}
# Rich-media file-preview service (in-cluster, cross-namespace). The port is
# the service's targetPort: Cilium enforces egress against the targetPort,
# not the Service port, so the Service's :80 → targetPort :8080 lands on 8080.
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
# Apache Tika text/metadata extraction (in-cluster, cross-namespace).
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
# Presidio NER DLP scanning (in-cluster, cross-namespace).
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
# License server (external via public endpoint, or via ingress controller for in-cluster hairpin)
{{- if .Values.networkPolicy.licenseServer.enabled }}
- to:
    {{- if .Values.networkPolicy.licenseServer.cidr }}
    - ipBlock:
        cidr: {{ .Values.networkPolicy.licenseServer.cidr }}
    {{- else }}
    - ipBlock:
        cidr: 0.0.0.0/0
        except:
          - 10.0.0.0/8       # RFC1918
          - 172.16.0.0/12    # RFC1918
          - 192.168.0.0/16   # RFC1918
          - 169.254.0.0/16   # Cloud IMDS SSRF gate
          - 100.64.0.0/10    # Tailscale CGNAT
    {{- end }}
  ports:
    - protocol: TCP
      port: 443
# Allow traffic to ingress controller for license server hairpin NAT
- to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: {{ .Values.networkPolicy.ingressNamespace | default "ingress-nginx" }}
  ports:
    - protocol: TCP
      port: 443
{{- if .Values.networkPolicy.licenseServer.internalNamespace }}
# Internal license server (in-cluster service). Two ports, both to the
# license-server pods — either MUST be reachable or the instance latches into
# admin-only mode. Harmless on self-hosted clusters where this namespace does
# not exist (matches no pods).
#   - internalPort (8090): verified in-cluster mode validates against
#     http://license-server.<ns>:8090 directly.
#   - externalTargetPort (8443): when verified in-cluster mode is NOT active the
#     app falls back to the public URL (license.mnemoshare.com), which
#     split-horizon-resolves to the license-server ClusterIP. The Service maps
#     443 -> targetPort 8443 and Cilium enforces egress against the *targetPort*,
#     not the Service port — so the public-URL path is only reachable if 8443 is
#     allowed here.
- to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: {{ .Values.networkPolicy.licenseServer.internalNamespace }}
      podSelector:
        matchLabels:
          app.kubernetes.io/name: license-server
  ports:
    - protocol: TCP
      port: {{ .Values.networkPolicy.licenseServer.internalPort | default 8090 }}
    {{- if .Values.networkPolicy.licenseServer.externalTargetPort }}
    - protocol: TCP
      port: {{ .Values.networkPolicy.licenseServer.externalTargetPort }}
    {{- end }}
{{- end }}
{{- end }}
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
# SendGrid / AWS SES API (external, 443)
{{- if or .Values.sendgrid.apiKey (eq .Values.platformEmail.transport "ses") .Values.platformEmail.ses.region .Values.sesAdmin.region }}
- to:
    - ipBlock:
        cidr: 0.0.0.0/0
        except:
          - 10.0.0.0/8       # RFC1918
          - 172.16.0.0/12    # RFC1918
          - 192.168.0.0/16   # RFC1918
          - 169.254.0.0/16   # Cloud IMDS SSRF gate
          - 100.64.0.0/10    # Tailscale CGNAT
  ports:
    - protocol: TCP
      port: 443
{{- end }}
# OAuth/SSO providers (external)
{{- if .Values.networkPolicy.oauth.enabled }}
- to:
    - ipBlock:
        cidr: 0.0.0.0/0
        except:
          - 10.0.0.0/8       # RFC1918
          - 172.16.0.0/12    # RFC1918
          - 192.168.0.0/16   # RFC1918
          - 169.254.0.0/16   # Cloud IMDS SSRF gate
          - 100.64.0.0/10    # Tailscale CGNAT
  ports:
    - protocol: TCP
      port: 443
{{- end }}
# External SMTP (customer-configured outbound mail relays — Gmail, Office365, SES, etc.)
{{- if .Values.networkPolicy.smtp.enabled }}
- to:
    - ipBlock:
        cidr: 0.0.0.0/0
        except:
          - 10.0.0.0/8       # RFC1918
          - 172.16.0.0/12    # RFC1918
          - 192.168.0.0/16   # RFC1918
          - 169.254.0.0/16   # Cloud IMDS SSRF gate
          - 100.64.0.0/10    # Tailscale CGNAT
  ports:
    - protocol: TCP
      port: 25
    - protocol: TCP
      port: 465
    - protocol: TCP
      port: 587
    - protocol: TCP
      port: 2525
{{- end }}
# ICES standalone — Google Pub/Sub + Gmail API (external, 443). Without this
# the default-deny policy blackholes mail monitoring (the ICES pod's primary
# purpose) from first deploy on MinIO-only installs.
{{- if .Values.ices.enabled }}
- to:
    - ipBlock:
        cidr: 0.0.0.0/0
        except:
          - 10.0.0.0/8       # RFC1918
          - 172.16.0.0/12    # RFC1918
          - 192.168.0.0/16   # RFC1918
          - 169.254.0.0/16   # Cloud IMDS SSRF gate
          - 100.64.0.0/10    # Tailscale CGNAT
  ports:
    - protocol: TCP
      port: 443
{{- end }}
# Workflow engine — broad egress for customer-authored workflow steps
# (call_api, webhook, database_connect, sftp_*, ftps_*, as2_send, swift_*,
# ebics_*, oftp2, llm_prompt, etc.) which accept arbitrary host:port.
# An L4 port allowlist is theatrical for a workflows-enabled tenant, so
# the substantive boundary moves up the stack to DLP, audit chain, and
# anomaly detection. Private ranges are excluded for cluster + IMDS
# isolation; UDP is denied (TCP-only) to block DNS exfil and QUIC.
# Off by default for self-hosted; flip to true if the tenant has Workflows
# licensed and you want the iPaaS-style egress posture.
{{- if and .Values.networkPolicy.workflows .Values.networkPolicy.workflows.enabled }}
- to:
    - ipBlock:
        cidr: 0.0.0.0/0
        except:
          - 10.0.0.0/8       # RFC1918
          - 172.16.0.0/12    # RFC1918
          - 192.168.0.0/16   # RFC1918
          - 169.254.0.0/16   # Link-local (cloud IMDS SSRF gate)
          - 100.64.0.0/10    # Tailscale CGNAT
  ports:
    - protocol: TCP          # TCP only — block UDP egress
{{- end }}
{{- end -}}
