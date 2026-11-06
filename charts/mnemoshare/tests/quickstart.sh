#!/usr/bin/env bash
# Quickstart profile (values-quickstart.yaml): offline render assertions always run.
# The install check needs a disposable cluster and runs only with QUICKSTART_CLUSTER=1;
# it refuses any context not named kind-* unless QUICKSTART_CONTEXT is that exact name,
# and every helm and kubectl call is pinned to that context. Set QUICKSTART_APP_IMAGE to
# repository:tag to override the app image (e.g. a locally built arm64 image loaded into
# kind) and QUICKSTART_NO_CLAMAV=1 where the ClamAV image cannot run (it is amd64 only).
set -euo pipefail

chart=${1:-charts/mnemoshare}
values="$chart/values-quickstart.yaml"

fail() { echo "quickstart: $*" >&2; exit 1; }
render() { helm template qs "$chart" -f "$values" "$@"; }
# env_value <rendered> <ENV_NAME>: value of an env entry of the api Deployment container
env_value() {
  awk -v want="$2" '
    /^kind: / { kind=$2; insec = 0 }
    kind=="Deployment" && /^  name: qs-mnemoshare$/ { api=1 }
    /^---/ { api=0 }
    api && $1=="-" && $2=="name:" && $3==want { getline; sub(/^ *value: */, ""); gsub(/"/, ""); print; exit }
  ' <<<"$1"
}
has() { grep -Eq "$2" <<<"$1" || fail "$3"; }
lacks() { ! grep -Eq "$2" <<<"$1" || fail "$3"; }

helm lint "$chart" -f "$values" >/dev/null || fail "helm lint failed"

out=$(render)
has "$out" '^kind: Deployment' "no Deployments rendered"
for c in s3 presidio tika clamav; do
  has "$out" "^  name: qs-mnemoshare-$c\$" "component $c not rendered"
done
has "$out" 'type: Recreate' "api strategy is not Recreate"
has "$out" 'claimName: qs-mnemoshare-sqlite' "api does not mount the SQLite PVC"
has "$out" 'name: create-bucket' "bucket init container missing"
has "$out" 'head-bucket' "bucket init is not idempotent"
lacks "$out" 'kind: Job' "unexpected Job (bucket creation must precede the api)"
lacks "$out" 'redis' "Redis must not be rendered"
has "$out" 'versity/versitygw:v1.10.0' "Versity image pin missing"
has "$out" 'presidio-analyzer:2.2.362' "Presidio image pin missing"
has "$out" 'apache/tika:4.2.0-full' "Tika image pin missing"
has "$out" 'c-icap-client' "ClamAV exec probe missing"
[ "$(env_value "$out" DB_DRIVER)" = sqlite ] || fail "DB_DRIVER is not sqlite"
[ "$(env_value "$out" DEFAULT_ICAP_URL)" = icap://qs-mnemoshare-clamav:1344 ] || fail "ICAP URL not wired to the in-namespace Service"
[ "$(env_value "$out" TIKA_URL)" = http://qs-mnemoshare-tika:9998 ] || fail "TIKA_URL not wired"
[ "$(env_value "$out" PRESIDIO_URL)" = http://qs-mnemoshare-presidio:3000 ] || fail "PRESIDIO_URL not wired"
[ "$(env_value "$out" S3_ENDPOINT)" = qs-mnemoshare-s3:7070 ] || fail "S3_ENDPOINT not wired"
[ "$(env_value "$out" ENVIRONMENT)" = production ] || fail "ENVIRONMENT is not production"
[ "$(env_value "$out" FILTERED_PROCESS)" = '*' ] || fail "FILTERED_PROCESS is not *"
[ "$(env_value "$out" CUSTOMER_ID)" = quickstart ] || fail "CUSTOMER_ID is not quickstart"

# Disabling a scanner blanks its URL and removes its workload.
out=$(render --set clamav.enabled=false)
[ -z "$(env_value "$out" DEFAULT_ICAP_URL)" ] || fail "ICAP URL set with ClamAV disabled"
lacks "$out" '^  name: qs-mnemoshare-clamav$' "ClamAV rendered while disabled"
out=$(render --set quickstart.tika.enabled=false)
[ -z "$(env_value "$out" TIKA_URL)" ] || fail "TIKA_URL set with Tika disabled"
lacks "$out" '^  name: qs-mnemoshare-tika$' "Tika rendered while disabled"
lacks "$out" 'port: 9998' "Tika network rule rendered while disabled"

# Generated keys: encryption key is 32 base64 characters (192 bits), differs per render.
a=$(render | awk '$1=="encryption-key:" {gsub(/"/,"",$2); print $2}')
b=$(render | awk '$1=="encryption-key:" {gsub(/"/,"",$2); print $2}')
[ "${#a}" -eq 32 ] && [[ "$a" =~ ^[A-Za-z0-9+/]{32}$ ]] || fail "encryption key is not 32 base64 characters: '$a'"
[ "$a" != "$b" ] || fail "encryption key not random"
[ "$(render --set-string encryption.key=explicit-encryption-key-32bytes | awk '$1=="encryption-key:" {gsub(/"/,"",$2); print $2}')" = explicit-encryption-key-32bytes ] || fail "explicit encryption.key ignored"
render | grep -q 'helm.sh/resource-policy: keep' || fail "generated Secret is not kept on uninstall"

# Offline upgrade renders must refuse to rotate any generated key.
err=$(render --is-upgrade 2>&1) && fail "offline upgrade render without keys must fail"
grep -q "without cluster access" <<<"$err" || fail "offline upgrade message missing: $err"

# Guards.
err=$(render --set database.driver=postgres 2>&1) && fail "quickstart must refuse a non-sqlite database"
grep -q "quickstart.enabled requires" <<<"$err" || fail "driver guard message: $err"
err=$(render --set replicaCount=2 2>&1) && fail "quickstart must refuse more than one replica"

# Default values render no quickstart workload.
out=$(helm template d "$chart" --set customerId=ci --set mongodb.external.uri=mongodb://t:t@l:27017/t \
  --set s3.bucket=b --set s3.accessKey=k --set s3.secretKey=s --set-string jwt.ecPrivateKey=ec \
  --set encryption.key=test-encryption-key-exactly-32by --set license.key=lk --set appUrl=https://t.example.com \
  --set network.trustedProxyCIDRs=10.0.0.0/8)
lacks "$out" 'versitygw|presidio|apache/tika|create-bucket|-sqlite' "default render contains quickstart resources"

if [ "${QUICKSTART_CLUSTER:-}" = 1 ]; then
  ctx=$(kubectl config current-context)
  case "$ctx" in
    kind-*) ;;
    *) [ "${QUICKSTART_CONTEXT:-}" = "$ctx" ] || fail "refusing to run against context '$ctx': use a kind cluster or set QUICKSTART_CONTEXT=$ctx" ;;
  esac
  ns=quickstart-$$
  rel=qs
  trap 'helm --kube-context "$ctx" uninstall "$rel" -n "$ns" >/dev/null 2>&1 || true; kubectl --context "$ctx" delete namespace "$ns" --wait=false >/dev/null 2>&1 || true' EXIT
  kubectl --context "$ctx" create namespace "$ns" >/dev/null
  extra=()
  if [ -n "${QUICKSTART_APP_IMAGE:-}" ]; then
    extra+=(--set "image.repository=${QUICKSTART_APP_IMAGE%:*}" --set "image.tag=${QUICKSTART_APP_IMAGE##*:}")
  fi
  [ "${QUICKSTART_NO_CLAMAV:-}" = 1 ] && extra+=(--set clamav.enabled=false)
  k() { kubectl --context "$ctx" -n "$ns" "$@"; }
  field() { k get secret "$rel-mnemoshare-secrets" -o "jsonpath={.data.$1}"; }
  secrets() { for f in encryption-key s3-access-key s3-secret-key jwt-ec-private-key; do field "$f"; echo; done; }

  helm --kube-context "$ctx" install "$rel" "$chart" -n "$ns" -f "$values" ${extra[@]+"${extra[@]}"} --wait --timeout 10m >/dev/null
  k get pods
  before=$(secrets)
  [ -n "$(field encryption-key)" ] || fail "no encryption key generated"
  pf_port=$((20000 + $$ % 10000))
  k port-forward "svc/$rel-mnemoshare" "$pf_port:80" >/dev/null 2>&1 &
  pf=$!
  trap 'kill $pf 2>/dev/null || true; helm --kube-context "$ctx" uninstall "$rel" -n "$ns" >/dev/null 2>&1 || true; kubectl --context "$ctx" delete namespace "$ns" --wait=false >/dev/null 2>&1 || true' EXIT
  code=000
  for _ in $(seq 1 30); do
    code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$pf_port/health" || true)
    [ "$code" = 200 ] && break
    sleep 2
  done
  [ "$code" = 200 ] || fail "/health returned $code"
  logs=$(k logs "deploy/$rel-mnemoshare" -c mnemoshare)
  grep -q one_time_password <<<"$logs" || fail "no one_time_password in the api log"

  helm --kube-context "$ctx" upgrade "$rel" "$chart" -n "$ns" -f "$values" ${extra[@]+"${extra[@]}"} --set resources.limits.memory=1280Mi --wait --timeout 10m >/dev/null
  [ "$(secrets)" = "$before" ] || fail "generated secrets changed on upgrade"
fi
echo "quickstart: ok"
