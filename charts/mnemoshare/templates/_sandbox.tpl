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
{{- if and .Values.sandbox.runner.staging.enabled (or (eq (int .Values.sandbox.runner.staging.port) (int .Values.sandbox.runner.port)) (eq (int .Values.sandbox.runner.staging.port) (int .Values.sandbox.runner.healthPort))) -}}
{{- fail "sandbox.runner.staging.port must differ from sandbox.runner.port and sandbox.runner.healthPort" -}}
{{- end -}}
{{- if and (not .Values.sandbox.runner.tls.enabled) (not .Values.sandbox.runner.tls.allowPlaintext) -}}
{{- fail "sandbox.runner.tls.enabled=false requires sandbox.runner.tls.allowPlaintext=true (plaintext runner traffic carries the shared secret)" -}}
{{- end -}}
{{- if and .Values.sandbox.runner.tls.enabled (not .Values.sandbox.runner.tls.secretName) (not .Values.sandbox.runner.tls.issuerRef.name) (not (and .Values.keyguard .Values.keyguard.cert .Values.keyguard.cert.issuerName)) -}}
{{- fail "sandbox.runner.tls needs sandbox.runner.tls.secretName, sandbox.runner.tls.issuerRef.name or keyguard.cert.issuerName (or set tls.enabled=false with tls.allowPlaintext=true for development)" -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Runner storage sizing, derived from the tier envelope so the staging and output
volumes always fit the byte caps the runner enforces. The per-run ceiling is
the tier cap bounded by the runner's 512Mi default, and the store totals equal
concurrency times that ceiling. Volumes add 12.5% plus 64Mi for
sealing overhead, logs and results; the container's ephemeral-storage covers
both volumes, /tmp and 64Mi of log and layer headroom.
*/}}
{{- define "mnemoshare.sandbox.sizing" -}}
{{- $l := .Values.sandbox.policy.limits | default dict -}}
{{- $jobs := int64 ($l.maxConcurrentJobs | default 1) -}}
{{- $runCap := int64 536870912 -}}
{{- $inRun := min (int64 ($l.maxInputBytes | default $runCap)) $runCap -}}
{{- $outRun := min (int64 ($l.maxOutputBytes | default $runCap)) $runCap -}}
{{- $inTotal := mul $jobs $inRun -}}
{{- $outTotal := mul $jobs $outRun -}}
{{- $mi := int64 1048576 -}}
{{- $inMi := div (add (add $inTotal (div $inTotal 8)) (add (mul 64 $mi) (sub $mi 1))) $mi -}}
{{- $outMi := div (add (add $outTotal (div $outTotal 8)) (add (mul 64 $mi) (sub $mi 1))) $mi -}}
{{- dict "stagingTotalBytes" (toString $inTotal) "outputTotalBytes" (toString $outTotal) "stagingVolume" (printf "%dMi" $inMi) "outputVolume" (printf "%dMi" $outMi) "containerEphemeral" (printf "%dMi" (add (add $inMi $outMi) 128)) | toJson -}}
{{- end }}

{{/*
Staging runs only on a digest-pinned runner image: the runner refuses to start
with SANDBOX_INIT_IMAGE unpinned while policy.requireImageDigest is on, which
would take the whole runner down rather than just staging.
*/}}
{{- define "mnemoshare.sandbox.stagingOn" -}}
{{- if and .Values.sandbox.runner.staging.enabled (or (contains "@sha256:" (include "mnemoshare.sandbox.image" .)) (not .Values.sandbox.policy.requireImageDigest)) -}}true{{- else -}}false{{- end -}}
{{- end }}
