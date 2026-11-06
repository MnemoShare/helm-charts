{{/*
Creates the bucket on the bundled Versity S3 before the api starts: the api
refuses to boot without its bucket and a post-install hook would only run after
`helm install --wait` had already given up on the api. Idempotent (head, then create).
*/}}
{{- define "mnemoshare.quickstart.bucketInitContainer" -}}
- name: create-bucket
  image: "{{ .Values.quickstart.s3.bucketInit.image.repository }}:{{ .Values.quickstart.s3.bucketInit.image.tag }}"
  imagePullPolicy: {{ .Values.quickstart.s3.bucketInit.image.pullPolicy }}
  securityContext:
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    runAsNonRoot: true
    runAsUser: 1000
    capabilities:
      drop:
        - ALL
    seccompProfile:
      type: RuntimeDefault
  command: ["/bin/sh", "-c"]
  args:
  - |
    n={{ .Values.quickstart.s3.bucketInit.attempts }}
    i=0
    while [ "$i" -lt "$n" ]; do
      i=$((i+1))
      aws --cli-connect-timeout 5 --cli-read-timeout 10 --endpoint-url "$S3_URL" s3api head-bucket --bucket "$S3_BUCKET" && exit 0
      aws --cli-connect-timeout 5 --cli-read-timeout 10 --endpoint-url "$S3_URL" s3api create-bucket --bucket "$S3_BUCKET" && exit 0
      sleep 2
    done
    echo "bucket $S3_BUCKET could not be created at $S3_URL after $n attempts" >&2
    exit 1
  env:
  - name: S3_URL
    value: "http://{{ include "mnemoshare.fullname" . }}-s3:7070"
  - name: S3_BUCKET
    value: {{ .Values.s3.bucket | default "mnemoshare" | quote }}
  - name: AWS_DEFAULT_REGION
    value: {{ .Values.s3.region | quote }}
  - name: HOME
    value: /tmp
  - name: AWS_MAX_ATTEMPTS
    value: "1"
  - name: AWS_ACCESS_KEY_ID
    valueFrom:
      secretKeyRef:
        name: {{ include "mnemoshare.s3SecretName" . }}
        key: s3-access-key
  - name: AWS_SECRET_ACCESS_KEY
    valueFrom:
      secretKeyRef:
        name: {{ include "mnemoshare.s3SecretName" . }}
        key: s3-secret-key
  resources:
    requests:
      cpu: 10m
      memory: 64Mi
    limits:
      memory: 256Mi
  volumeMounts:
  - name: tmp
    mountPath: /tmp
{{- end }}

{{/*
Render-time guards. Included from sqlite-pvc.yaml (SQLite single writer) and
quickstart-s3.yaml (Quickstart profile).
*/}}
{{- define "mnemoshare.sqlite.validate" -}}
{{- if include "mnemoshare.sqlitePersistent" . -}}
{{- if or (gt (int .Values.replicaCount) 1) .Values.autoscaling.enabled -}}
{{- fail "database.driver=sqlite with persistence is a single-writer install: replicaCount must be 1 and autoscaling.enabled must be false." -}}
{{- end -}}
{{- if or .Values.workflowWorker.enabled .Values.ices.enabled -}}
{{- fail "database.driver=sqlite with persistence is a single-writer install: workflowWorker and ices run as separate pods and would open the database concurrently; leave them disabled (the api hosts the engines)." -}}
{{- end -}}
{{- $dir := dir (.Values.database.sqlite.path | default "/var/lib/mnemoshare/mnemoshare.db") -}}
{{- if has $dir (list "/" "/tmp" "/mnt/disk-buffer" "/etc/mtls-tls" "/etc/mtls-ca") -}}
{{- fail (printf "database.sqlite.path directory %q collides with another pod mount; use a dedicated directory such as /var/lib/mnemoshare." $dir) -}}
{{- end -}}
{{- end -}}
{{- end }}

{{- define "mnemoshare.quickstart.validate" -}}
{{- if or (ne (.Values.database.driver | default "mongodb") "sqlite") (not .Values.database.sqlite.persistence.enabled) -}}
{{- fail "quickstart.enabled requires database.driver=sqlite and database.sqlite.persistence.enabled=true (use -f values-quickstart.yaml)." -}}
{{- end -}}
{{- if .Values.minio.enabled -}}
{{- fail "quickstart.enabled bundles its own Versity S3 gateway; set minio.enabled=false." -}}
{{- end -}}
{{- if not (has (.Values.s3.endpoint | default "") (list "" "https://s3.amazonaws.com")) -}}
{{- fail (printf "s3.endpoint=%q is ignored under quickstart.enabled (the api is pointed at the bundled gateway); remove it, or disable the Quickstart profile to use an external store." .Values.s3.endpoint) -}}
{{- end -}}
{{- $tag := toString (.Values.image.tag | default .Chart.AppVersion) -}}
{{- $semver := regexMatch "^v?[0-9]+\\.[0-9]+\\.[0-9]+$" $tag -}}
{{- if not .Values.quickstart.allowUnreleasedImage -}}
{{- if not $semver -}}
{{- fail (printf "quickstart.enabled needs a released app image, but image tag %q is not a release version. Pin image.tag to a release >= %s, or set quickstart.allowUnreleasedImage=true for a local or development build." $tag .Values.quickstart.minAppVersion) -}}
{{- end -}}
{{- if not (semverCompare (printf ">=%s" .Values.quickstart.minAppVersion) $tag) -}}
{{- fail (printf "quickstart.enabled needs app >= %s (earlier releases lack the Quickstart licensing and SQLite fixes), but the effective image tag is %q. Set image.tag to a release >= %s, or quickstart.allowUnreleasedImage=true for a local or development build." .Values.quickstart.minAppVersion $tag .Values.quickstart.minAppVersion) -}}
{{- end -}}
{{- end -}}
{{- end }}
