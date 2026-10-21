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
Identity mode: "shared" (default) — every federated pod runs as the release
ServiceAccount and mounts one cert Secret; "perComponent" — api, worker and
ices each get their own ServiceAccount, SPIFFE id, cert Secret and role ARN.
*/}}
{{- define "mnemoshare.keyguard.identityMode" -}}
{{- $m := "shared" -}}
{{- if .Values.keyguard -}}{{- $m = .Values.keyguard.identityMode | default "shared" -}}{{- end -}}
{{- if not (has $m (list "shared" "perComponent")) -}}
{{- fail (printf "keyguard.identityMode must be shared or perComponent, got %q" $m) -}}
{{- end -}}
{{- $m -}}
{{- end -}}

{{- define "mnemoshare.keyguard.perComponent" -}}
{{- if and (include "mnemoshare.keyguard.enabled" .) (eq (include "mnemoshare.keyguard.identityMode" .) "perComponent") -}}true{{- end -}}
{{- end -}}

{{/*
Per-component helpers take (dict "root" . "component" "api|worker|ices").
In shared mode they resolve to the release-wide values, so call sites are
identical in both modes.
*/}}
{{- define "mnemoshare.keyguard.componentSAName" -}}
{{- /* Truncate the fullname, not the suffix, so components never collapse to one name. */ -}}
{{- printf "%s-%s" (include "mnemoshare.fullname" .root | trunc (int (sub 62 (len .component))) | trimSuffix "-") .component -}}
{{- end -}}

{{- define "mnemoshare.keyguard.podServiceAccountName" -}}
{{- if include "mnemoshare.keyguard.perComponent" .root -}}
{{- include "mnemoshare.keyguard.componentSAName" . -}}
{{- else -}}
{{- include "mnemoshare.serviceAccountName" .root -}}
{{- end -}}
{{- end -}}

{{- define "mnemoshare.keyguard.certName" -}}
{{- if include "mnemoshare.keyguard.perComponent" .root -}}
{{- printf "%s-%s-keyguard-mtls" (include "mnemoshare.fullname" .root | trunc (int (sub 48 (len .component))) | trimSuffix "-") .component -}}
{{- else -}}
{{- printf "%s-keyguard-mtls" (include "mnemoshare.fullname" .root) -}}
{{- end -}}
{{- end -}}

{{- define "mnemoshare.keyguard.roleArn" -}}
{{- if include "mnemoshare.keyguard.perComponent" .root -}}
{{- $c := index (.root.Values.keyguard.components | default dict) .component | default dict -}}
{{- required (printf "keyguard.components.%s.roleArn is required when keyguard.identityMode=perComponent" .component) $c.roleArn -}}
{{- else -}}
{{- required "keyguard.roleArn is required when keyguard.enabled=true" .root.Values.keyguard.roleArn -}}
{{- end -}}
{{- end -}}

{{/*
SPIFFE id for this release. URI SAN on the workload cert; idp-lite uses
it as the JWT `sub` claim, AWS IAM trust policy conditions on it.
Form: spiffe://<trustDomain>/ns/<namespace>/sa/<serviceaccount>
Takes (dict "root" . "component" ...).
*/}}
{{- define "mnemoshare.keyguard.spiffeID" -}}
spiffe://{{ .root.Values.keyguard.spiffeTrustDomain }}/ns/{{ .root.Release.Namespace }}/sa/{{ include "mnemoshare.keyguard.podServiceAccountName" . }}
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
    secretName: {{ include "mnemoshare.keyguard.certName" . }}
- name: keyguard-idp-ca
  secret:
    secretName: {{ .root.Values.keyguard.cert.caSecretName | default "step-ca-root" }}
- name: keyguard-sa-token
  projected:
    sources:
      - serviceAccountToken:
          path: token
          audience: {{ include "mnemoshare.keyguard.saTokenAudience" .root }}
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
  value: {{ include "mnemoshare.keyguard.roleArn" . | quote }}
- name: AWS_REGION
  value: {{ .root.Values.keyguard.awsRegion | default "us-east-1" | quote }}
{{- end -}}

{{/*
The federation-sidecar container itself. Splice under `containers:` in
each consuming Deployment / StatefulSet.
*/}}
{{- define "mnemoshare.keyguard.sidecarContainer" -}}
{{- $root := .root -}}
- name: federation-sidecar
  image: "{{ $root.Values.keyguard.sidecar.image.repository }}:{{ required "keyguard.sidecar.image.tag is required — pin a specific sha or version, do not let it fall back to a rolling tag for a credential broker" $root.Values.keyguard.sidecar.image.tag }}"
  imagePullPolicy: {{ $root.Values.keyguard.sidecar.image.pullPolicy | default "IfNotPresent" }}
  env:
    - name: KG_IDP_ENDPOINT
      value: {{ required "keyguard.idpEndpoint is required when keyguard.enabled=true" $root.Values.keyguard.idpEndpoint | quote }}
    - name: KG_IDP_REALM
      value: {{ $root.Values.keyguard.idpRealm | default "master" | quote }}
    - name: KG_TLS_CA_PATH
      value: /etc/keyguard/idp-ca/{{ $root.Values.keyguard.cert.caSecretKey | default "ca.crt" }}
    - name: KG_TLS_CERT_PATH
      value: /etc/keyguard/workload-tls/tls.crt
    - name: KG_TLS_KEY_PATH
      value: /etc/keyguard/workload-tls/tls.key
    - name: KG_SA_TOKEN_PATH
      value: /var/run/secrets/k8s-sa/token
    - name: KG_OUTPUT_TOKEN_PATH
      value: /var/run/secrets/aws-federation/token
    - name: KG_ROLE_ARN
      value: {{ include "mnemoshare.keyguard.roleArn" . | quote }}
    - name: KG_REFRESH_LEAD_SECS
      value: {{ $root.Values.keyguard.tokenRefreshLeadSecs | default 60 | quote }}
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
    {{- toYaml ($root.Values.keyguard.sidecar.resources | default (dict "requests" (dict "cpu" "5m" "memory" "16Mi") "limits" (dict "memory" "32Mi"))) | nindent 4 }}
  volumeMounts:
    {{- include "mnemoshare.keyguard.volumeMountsSidecar" $root | nindent 4 }}
  securityContext:
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    runAsNonRoot: true
    # The federation-sidecar image (distroless:nonroot) declares a NON-numeric
    # USER (nonroot), so with only runAsNonRoot:true the kubelet cannot verify
    # the user is non-root and fails the container with CreateContainerConfigError.
    # Pin a numeric UID (matches the working demo sidecar) so the check passes.
    runAsUser: {{ $root.Values.keyguard.sidecar.runAsUser | default 1000 }}
    capabilities:
      drop: ["ALL"]
{{- end -}}
