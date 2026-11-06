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
    for i in $(seq 1 {{ .Values.quickstart.s3.bucketInit.attempts }}); do
      aws --endpoint-url "$S3_URL" s3api head-bucket --bucket "$S3_BUCKET" 2>/dev/null && exit 0
      aws --endpoint-url "$S3_URL" s3api create-bucket --bucket "$S3_BUCKET" && exit 0
      sleep 2
    done
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
