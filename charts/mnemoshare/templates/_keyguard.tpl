{{/*
KeyGuard helpers — wires the federation-sidecar (MSC-371) into the api
and workflow-worker pod specs when .Values.keyguard.enabled is true.

The sidecar mints a short-lived AWS-usable JWT (mTLS to idp-lite, validated
against a WorkloadIdentity allow-list) and writes it atomically to an
emptyDir tmpfs volume the app container reads via
AWS_WEB_IDENTITY_TOKEN_FILE. No AWS access keys live on the pod.

See cmd/federation-sidecar/README.md in the mnemoshare-idp-lite repo for
the trust chain end-to-end, and docs/private/KEYGUARD_KMS_INTEGRATION.md
for the architecture.

Pre-requisites (operator must set up before turning this on):
  - cert-manager installed in the cluster.
  - A ClusterIssuer / Issuer that can mint workload certs with a SPIFFE
    URI SAN (typically smallstep step-issuer fronting Step-CA).
  - The pod's SA registered as a WorkloadIdentity in the idp-lite realm.
  - An AWS IAM role with a trust policy pinning the pod's SPIFFE id.
  - The idp-lite server CA mounted into the cluster as a Secret (default
    name: `step-ca-root`, can be overridden via keyguard.cert.caSecretName).
*/}}

{{/*
Boolean — call from `{{ if include "mnemoshare.keyguard.enabled" . }}` so
the rest of the chart can gate cleanly without repeating the
nil-check / type-check dance.
*/}}
{{- define "mnemoshare.keyguard.enabled" -}}
{{- if and .Values.keyguard .Values.keyguard.enabled -}}true{{- end -}}
{{- end -}}

{{/*
SPIFFE id for this release. URI SAN on the workload cert; idp-lite uses
it as the JWT `sub` claim, AWS IAM trust policy conditions on it.
Form: spiffe://<trustDomain>/ns/<namespace>/sa/<serviceaccount>
*/}}
{{- define "mnemoshare.keyguard.spiffeID" -}}
spiffe://{{ .Values.keyguard.spiffeTrustDomain }}/ns/{{ .Release.Namespace }}/sa/{{ include "mnemoshare.serviceAccountName" . }}
{{- end -}}

{{/*
SA token audience. Defaults to the host portion of keyguard.idpEndpoint
when the user hasn't set saTokenAudience explicitly — idp-lite validates
that the projected SA token's `aud` matches its configured audience
(default `idp.mnemoshare.com`).
*/}}
{{- define "mnemoshare.keyguard.saTokenAudience" -}}
{{- if .Values.keyguard.saTokenAudience -}}
{{- .Values.keyguard.saTokenAudience -}}
{{- else -}}
{{- $url := .Values.keyguard.idpEndpoint -}}
{{- $afterScheme := regexReplaceAll "^https?://" $url "" -}}
{{- $hostPort := regexReplaceAll "/.*$" $afterScheme "" -}}
{{- regexReplaceAll ":.*$" $hostPort "" -}}
{{- end -}}
{{- end -}}

{{/*
Volumes the keyguard wiring adds to a pod. Always rendered as a list
fragment — caller splices it under the pod's `volumes:` key.
*/}}
{{- define "mnemoshare.keyguard.volumes" -}}
- name: keyguard-workload-tls
  secret:
    secretName: {{ printf "%s-keyguard-mtls" (include "mnemoshare.fullname" .) }}
- name: keyguard-idp-ca
  secret:
    secretName: {{ .Values.keyguard.cert.caSecretName | default "step-ca-root" }}
- name: keyguard-sa-token
  projected:
    sources:
      - serviceAccountToken:
          path: token
          audience: {{ include "mnemoshare.keyguard.saTokenAudience" . }}
          expirationSeconds: 3600
- name: keyguard-aws-federation
  emptyDir:
    medium: Memory
{{- end -}}

{{/*
Volume mounts for the MAIN app container (read-only token file).
*/}}
{{- define "mnemoshare.keyguard.volumeMountsMain" -}}
- name: keyguard-aws-federation
  mountPath: /var/run/secrets/aws-federation
  readOnly: true
{{- end -}}

{{/*
Volume mounts for the SIDECAR container (read certs + SA token, write token).
*/}}
{{- define "mnemoshare.keyguard.volumeMountsSidecar" -}}
- name: keyguard-workload-tls
  mountPath: /etc/keyguard/workload-tls
  readOnly: true
- name: keyguard-idp-ca
  mountPath: /etc/keyguard/idp-ca
  readOnly: true
- name: keyguard-sa-token
  mountPath: /var/run/secrets/k8s-sa
  readOnly: true
- name: keyguard-aws-federation
  mountPath: /var/run/secrets/aws-federation
{{- end -}}

{{/*
Env injected into the MAIN app container. AWS SDK reads these.
*/}}
{{- define "mnemoshare.keyguard.envMain" -}}
- name: AWS_WEB_IDENTITY_TOKEN_FILE
  value: /var/run/secrets/aws-federation/token
- name: AWS_ROLE_ARN
  value: {{ required "keyguard.roleArn is required when keyguard.enabled=true" .Values.keyguard.roleArn | quote }}
- name: AWS_REGION
  value: {{ .Values.keyguard.awsRegion | default "us-east-1" | quote }}
{{- end -}}

{{/*
The federation-sidecar container itself. Splice under `containers:` in
each consuming Deployment / StatefulSet.
*/}}
{{- define "mnemoshare.keyguard.sidecarContainer" -}}
- name: federation-sidecar
  image: "{{ .Values.keyguard.sidecar.image.repository }}:{{ required "keyguard.sidecar.image.tag is required — pin a specific sha or version, do not let it fall back to a rolling tag for a credential broker" .Values.keyguard.sidecar.image.tag }}"
  imagePullPolicy: {{ .Values.keyguard.sidecar.image.pullPolicy | default "IfNotPresent" }}
  env:
    - name: KG_IDP_ENDPOINT
      value: {{ required "keyguard.idpEndpoint is required when keyguard.enabled=true" .Values.keyguard.idpEndpoint | quote }}
    - name: KG_IDP_REALM
      value: {{ .Values.keyguard.idpRealm | default "master" | quote }}
    - name: KG_TLS_CA_PATH
      value: /etc/keyguard/idp-ca/{{ .Values.keyguard.cert.caSecretKey | default "ca.crt" }}
    - name: KG_TLS_CERT_PATH
      value: /etc/keyguard/workload-tls/tls.crt
    - name: KG_TLS_KEY_PATH
      value: /etc/keyguard/workload-tls/tls.key
    - name: KG_SA_TOKEN_PATH
      value: /var/run/secrets/k8s-sa/token
    - name: KG_OUTPUT_TOKEN_PATH
      value: /var/run/secrets/aws-federation/token
    - name: KG_ROLE_ARN
      value: {{ .Values.keyguard.roleArn | quote }}
    - name: KG_REFRESH_LEAD_SECS
      value: {{ .Values.keyguard.tokenRefreshLeadSecs | default 60 | quote }}
  ports:
    - name: keyguard
      containerPort: 8081
      protocol: TCP
  readinessProbe:
    httpGet:
      path: /readyz
      port: 8081
    initialDelaySeconds: 1
    periodSeconds: 5
  livenessProbe:
    httpGet:
      path: /healthz
      port: 8081
    initialDelaySeconds: 10
    periodSeconds: 30
  resources:
    {{- toYaml (.Values.keyguard.sidecar.resources | default (dict "requests" (dict "cpu" "5m" "memory" "16Mi") "limits" (dict "memory" "32Mi"))) | nindent 4 }}
  securityContext:
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    runAsNonRoot: true
    capabilities:
      drop: ["ALL"]
{{- end -}}
