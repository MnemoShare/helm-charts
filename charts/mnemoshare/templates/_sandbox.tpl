{{/*
Sandbox runner helpers. The runner is the only workload that holds Kubernetes
API access; everything it creates lives in a SEPARATE namespace
(<release namespace><sandbox.namespaceSuffix>) that this chart renders
resources into. The namespace must exist with pod security "restricted":
pre-create it (recommended; it then survives uninstall) or set
sandbox.createNamespace=true to have the release own it.
*/}}
{{- define "mnemoshare.sandbox.namespace" -}}
{{- $suffix := required "sandbox.namespaceSuffix must not be empty" .Values.sandbox.namespaceSuffix -}}
{{- printf "%s%s" .Release.Namespace $suffix -}}
{{- end }}

{{- define "mnemoshare.sandbox.runnerName" -}}
mnemoshare-sandbox-runner
{{- end }}

{{- define "mnemoshare.sandbox.secretName" -}}
{{- .Values.sandbox.runner.secretName | default (printf "%s-sandbox-runner" (include "mnemoshare.fullname" .)) -}}
{{- end }}

{{- define "mnemoshare.sandbox.tlsSecretName" -}}
{{- .Values.sandbox.runner.tls.secretName | default (printf "%s-sandbox-runner-tls" (include "mnemoshare.fullname" .)) -}}
{{- end }}

{{/* Pods that host the workflows engine: workers when external, else the api. */}}
{{- define "mnemoshare.sandbox.engineComponent" -}}
{{- if and .Values.workflowWorker .Values.workflowWorker.enabled -}}workflow-worker{{- else -}}api{{- end -}}
{{- end }}

{{- define "mnemoshare.sandbox.scheme" -}}
{{- if .Values.sandbox.runner.tls.enabled -}}https{{- else -}}http{{- end -}}
{{- end }}

{{- define "mnemoshare.sandbox.url" -}}
{{- printf "%s://%s.%s.svc:%v" (include "mnemoshare.sandbox.scheme" .) (include "mnemoshare.sandbox.runnerName" .) .Release.Namespace .Values.sandbox.runner.port -}}
{{- end }}

{{- define "mnemoshare.sandbox.image" -}}
{{- include "mnemoshare.applicationImage" (dict "root" . "component" .Values.sandbox.runner.image "name" "sandbox-runner") -}}
{{- end }}

{{/* Env for the pods that host the engine; the runner URL and shared secret. */}}
{{- define "mnemoshare.sandbox.engineEnv" -}}
{{- if .Values.sandbox.enabled }}
- name: SANDBOX_RUNNER_URL
  value: {{ include "mnemoshare.sandbox.url" . | quote }}
- name: SANDBOX_RUNNER_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ include "mnemoshare.sandbox.secretName" . }}
      key: secret
{{- end }}
{{- end }}

{{- define "mnemoshare.sandbox.validate" -}}
{{- if .Values.sandbox.enabled -}}
{{- if not (include "mnemoshare.sandbox.namespace" .) -}}{{- fail "sandbox namespace is empty" -}}{{- end -}}
{{- if and (not .Values.sandbox.runner.tls.enabled) (not .Values.sandbox.runner.tls.allowPlaintext) -}}
{{- fail "sandbox.runner.tls.enabled=false requires sandbox.runner.tls.allowPlaintext=true (plaintext runner traffic carries the shared secret)" -}}
{{- end -}}
{{- if and .Values.sandbox.runner.tls.enabled (not .Values.sandbox.runner.tls.secretName) (not .Values.sandbox.runner.tls.issuerRef.name) (not (and .Values.keyguard .Values.keyguard.cert .Values.keyguard.cert.issuerName)) -}}
{{- fail "sandbox.runner.tls needs sandbox.runner.tls.secretName, sandbox.runner.tls.issuerRef.name or keyguard.cert.issuerName (or set tls.enabled=false with tls.allowPlaintext=true for development)" -}}
{{- end -}}
{{- end -}}
{{- end }}
