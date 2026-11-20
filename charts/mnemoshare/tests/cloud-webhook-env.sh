#!/usr/bin/env bash
# GOOGLE_WEBHOOK_URL / MICROSOFT_WEBHOOK_URL reach the pod that hosts the Google and Microsoft
# Drive engines (the worker, or the API when there is no worker) even when ices.enabled=true,
# while the mail-only env stays off that pod. No container may repeat an env name.
set -euo pipefail

chart=${1:-charts/mnemoshare}
base=(
  --set customerId=ci-test
  --set mongodb.external.uri=mongodb://t:t@l:27017/t
  --set s3.bucket=b --set s3.accessKey=k --set s3.secretKey=s
  --set-string jwt.ecPrivateKey=ec --set encryption.key=test-encryption-key-exactly-32by
  --set license.key=lk
  --set network.trustedProxyCIDRs=10.0.0.0/8
  --set redis.mode=inCluster --set redis.password=x
)
failed=0
fail() { echo "cloud-webhook-env: $*" >&2; failed=1; }

# check <label> <component> <expect-spec> <helm args...>
# expect-spec: space-separated NAME=VALUE (must be present with that value), +NAME (present),
# -NAME (absent), -WEBHOOKS (neither webhook URL present), -MAILONLY (no mail-only env),
# +MAILONLY (both mail intervals present).
check() {
  local label=$1 comp=$2 spec=$3; shift 3
  helm template t "$chart" "${base[@]}" "$@" | python3 -c '
import sys, yaml, json
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
label, comp, spec = sys.argv[1:4]
MAIL = ("GOOGLE_MAIL_ENROLLMENT_INTERVAL_SEC", "GOOGLE_INTERNAL_MAIL_WATCH_INTERVAL_SEC")
errs = []
hosts = [d for d in docs if d["kind"] in ("Deployment", "StatefulSet")
         and d["metadata"].get("labels", {}).get("app.kubernetes.io/component", "api") == comp]
if len(hosts) != 1:
    sys.exit(f"{label}: expected one {comp} workload, found {len(hosts)}")
for d in docs:
    if d["kind"] not in ("Deployment", "StatefulSet"):
        continue
    for c in d["spec"]["template"]["spec"].get("containers", []):
        names = [e["name"] for e in c.get("env", [])]
        dup = {n for n in names if names.count(n) > 1}
        if dup:
            errs.append("%s/%s: duplicate env %s" % (d["metadata"]["name"], c["name"], sorted(dup)))
env = {e["name"]: e.get("value") for e in hosts[0]["spec"]["template"]["spec"]["containers"][0].get("env", [])}
for tok in spec.split():
    if tok == "-WEBHOOKS":
        for n in ("GOOGLE_WEBHOOK_URL", "MICROSOFT_WEBHOOK_URL"):
            if n in env: errs.append(f"{comp} has {n}={env[n]}")
    elif tok == "-MAILONLY":
        for n in env:
            if n in MAIL or n.startswith("ARC_"): errs.append(f"{comp} has mail-only env {n}")
    elif tok == "+MAILONLY":
        for n in MAIL:
            if n not in env: errs.append(f"{comp} lacks {n}")
    elif tok.startswith("-"):
        if tok[1:] in env: errs.append(f"{comp} has {tok[1:]}")
    elif "=" in tok:
        n, v = tok.split("=", 1)
        if env.get(n) != v: errs.append(f"{comp} {n}={env.get(n)!r}, want {v!r}")
    elif tok not in env:
        errs.append(f"{comp} lacks {tok}")
if errs:
    sys.exit(f"{label}: " + "; ".join(errs))
' "$label" "$comp" "$spec" || fail "$label"
}

G=GOOGLE_WEBHOOK_URL M=MICROSOFT_WEBHOOK_URL
U=https://t.example.com/api/v1/integrations/cloud/webhook
urls="$G=$U/google $M=$U/microsoft"
app=(--set appUrl=https://t.example.com)
split=(--set workflowWorker.enabled=true --set ices.enabled=true --set mailMonitoring.enabled=true)

check "ices on, worker StatefulSet" workflow-worker "$urls ICES_STANDALONE=true -MAILONLY" "${app[@]}" "${split[@]}" --set workflowWorker.persistence.enabled=true
check "ices on, worker Deployment" workflow-worker "$urls ICES_STANDALONE=true -MAILONLY" "${app[@]}" "${split[@]}" --set workflowWorker.persistence.enabled=false
check "ices on, no worker: api hosts the engines" api "$urls ICES_STANDALONE=true -MAILONLY" "${app[@]}" --set ices.enabled=true --set mailMonitoring.enabled=true
check "ices on, appUrl empty, explicit Google URL (StatefulSet)" workflow-worker "$G=https://g.example.com/hook -$M -MAILONLY" "${split[@]}" --set workflowWorker.persistence.enabled=true --set mailMonitoring.googleWebhookUrl=https://g.example.com/hook
check "ices on, appUrl empty, explicit Google URL (Deployment)" workflow-worker "$G=https://g.example.com/hook -$M -MAILONLY" "${split[@]}" --set mailMonitoring.googleWebhookUrl=https://g.example.com/hook
check "cloudDlp.webhooks only, StatefulSet" workflow-worker "$urls -MAILONLY" "${app[@]}" --set workflowWorker.enabled=true --set workflowWorker.persistence.enabled=true --set cloudDlp.webhooks.enabled=true
check "cloudDlp.webhooks only, Deployment" workflow-worker "$urls -MAILONLY" "${app[@]}" --set workflowWorker.enabled=true --set cloudDlp.webhooks.enabled=true
check "cloudDlp.webhooks only, no worker" api "$urls -MAILONLY" "${app[@]}" --set cloudDlp.webhooks.enabled=true
check "cloudDlp.webhooks with ices: ices unchanged" ices "-WEBHOOKS -MAILONLY" "${app[@]}" --set workflowWorker.enabled=true --set ices.enabled=true --set cloudDlp.webhooks.enabled=true
check "cloudDlp.webhooks with ices: worker has URLs" workflow-worker "$urls ICES_STANDALONE=true -MAILONLY" "${app[@]}" --set workflowWorker.enabled=true --set ices.enabled=true --set cloudDlp.webhooks.enabled=true

# Guards that held before the change.
check "ices pod keeps both URLs and the mail env" ices "$urls +MAILONLY" "${app[@]}" "${split[@]}"
check "ices and worker on: api has no URLs and no mail env" api "-WEBHOOKS -MAILONLY" "${app[@]}" "${split[@]}"
check "ices off, worker StatefulSet keeps URLs and mail env" workflow-worker "$urls +MAILONLY -ICES_STANDALONE" "${app[@]}" --set workflowWorker.enabled=true --set workflowWorker.persistence.enabled=true --set mailMonitoring.enabled=true
check "ices off, worker Deployment keeps URLs and mail env" workflow-worker "$urls +MAILONLY -ICES_STANDALONE" "${app[@]}" --set workflowWorker.enabled=true --set mailMonitoring.enabled=true
check "ices off, no worker: api keeps URLs and mail env" api "$urls +MAILONLY" "${app[@]}" --set mailMonitoring.enabled=true
check "defaults: worker has no URLs" workflow-worker "-WEBHOOKS -MAILONLY" "${app[@]}" --set workflowWorker.enabled=true
check "defaults: api has no URLs" api "-WEBHOOKS -MAILONLY" "${app[@]}"
check "defaults: ices has no URLs" ices "-WEBHOOKS -MAILONLY" "${app[@]}" --set workflowWorker.enabled=true --set ices.enabled=true
check "worker on, ices off, cloudDlp.webhooks only: api hosts no engine, no URLs" api "-WEBHOOKS -MAILONLY" "${app[@]}" --set workflowWorker.enabled=true --set cloudDlp.webhooks.enabled=true
check "worker on, ices off, cloudDlp.webhooks only: worker has URLs" workflow-worker "$urls -MAILONLY" "${app[@]}" --set workflowWorker.enabled=true --set cloudDlp.webhooks.enabled=true
check "cloudDlp null renders as defaults" workflow-worker "-WEBHOOKS -MAILONLY" "${app[@]}" --set workflowWorker.enabled=true --set cloudDlp=null
check "cloudDlp.webhooks null renders as defaults" workflow-worker "-WEBHOOKS -MAILONLY" "${app[@]}" --set workflowWorker.enabled=true --set cloudDlp.webhooks=null
check "cloudDlp.webhooks, appUrl empty, explicit URLs" workflow-worker "$G=https://g.example.com/hook $M=https://m.example.com/hook" --set workflowWorker.enabled=true --set cloudDlp.webhooks.enabled=true --set mailMonitoring.googleWebhookUrl=https://g.example.com/hook --set mailMonitoring.microsoftWebhookUrl=https://m.example.com/hook

# cloudDlp.webhooks.enabled with nothing to render is refused; mailMonitoring alone stays silent.
if out=$(helm template t "$chart" "${base[@]}" --set workflowWorker.enabled=true --set cloudDlp.webhooks.enabled=true 2>&1); then
  fail "cloudDlp.webhooks with no appUrl and no explicit URL rendered"
elif ! grep -q "cloudDlp.webhooks.enabled=true renders no webhook URL: set appUrl, or mailMonitoring.googleWebhookUrl / mailMonitoring.microsoftWebhookUrl" <<<"$out"; then
  fail "cloudDlp.webhooks refusal message missing: $out"
fi
helm template t "$chart" "${base[@]}" --set workflowWorker.enabled=true --set mailMonitoring.enabled=true >/dev/null 2>&1 \
  || fail "mailMonitoring with no appUrl must keep rendering"

# A workaround in extraEnv now repeats the name: the chart entry comes first, the user's last.
dupcheck() { # <component> <helm args...>
  local comp=$1; shift
  helm template t "$chart" "${base[@]}" "${app[@]}" "$@" | python3 -c '
import sys, yaml
comp = sys.argv[1]
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
d = [d for d in docs if d["kind"] in ("Deployment", "StatefulSet")
     and d["metadata"].get("labels", {}).get("app.kubernetes.io/component", "api") == comp][0]
vals = [e["value"] for e in d["spec"]["template"]["spec"]["containers"][0]["env"] if e["name"] == "GOOGLE_WEBHOOK_URL"]
want = ["https://t.example.com/api/v1/integrations/cloud/webhook/google", "https://user.example.com/g"]
sys.exit(0 if vals == want else "GOOGLE_WEBHOOK_URL values %r, want %r" % (vals, want))
' "$comp"
}
dupcheck workflow-worker "${split[@]}" --set "workflowWorker.extraEnv[0].name=GOOGLE_WEBHOOK_URL" --set "workflowWorker.extraEnv[0].value=https://user.example.com/g" || fail "worker extraEnv duplicate"
dupcheck api --set ices.enabled=true --set mailMonitoring.enabled=true --set "extraEnv[0].name=GOOGLE_WEBHOOK_URL" --set "extraEnv[0].value=https://user.example.com/g" || fail "api extraEnv duplicate"

# Default render: no URLs, and the API's rendered mail-monitoring comment is unchanged.
out=$(helm template t "$chart" "${base[@]}" "${app[@]}")
grep -q "_WEBHOOK_URL" <<<"$out" && fail "default render contains a webhook URL"
grep -q "# needs the webhook/interval env when mailMonitoring.enabled." <<<"$out" || fail "API mail-monitoring comment changed"
[ "$failed" -eq 0 ] || exit 1
echo "cloud-webhook-env: ok"
