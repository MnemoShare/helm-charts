#!/usr/bin/env bash
# Chart-generated secrets (encryption key, JWT EC key) must be stable:
# explicit value wins, else the value already in the release Secret, else generated.
# Offline checks always run; the lookup checks need a disposable cluster and run
# only with STABLE_SECRETS_CLUSTER=1 (kubectl's current context is used).
set -euo pipefail

chart=${1:-charts/mnemoshare}
base=(
  --set customerId=ci-test
  --set image.digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  --set cors.allowedOrigins=https://ci.example.com
  --set mongodb.external.enabled=true
  --set mongodb.external.uri=mongodb://test:test@localhost:27017/test
  --set s3.bucket=test-bucket --set s3.accessKey=test-key --set s3.secretKey=test-secret
  --set license.key=test-license-key
  --set appUrl=https://test.example.com
  --set ingress.enabled=false
  --set sftpGateway.enabled=true --set sftpGateway.hostKey.existingSecret=hk
)
explicit=(--set-string jwt.ecPrivateKey=explicit-ec-key --set encryption.key=explicit-encryption-key-32bytes)

fail() { echo "stable-secrets: $*" >&2; exit 1; }
render() { helm template t "$chart" "${base[@]}" "$@"; }
# secret_value <rendered> <secret-name-suffix> <key>
secret_value() {
  awk -v sfx="$2" -v key="$3" '
    /^kind: Secret/ { insecret=1 }
    /^---/ { insecret=0; match_name=0 }
    insecret && $1=="name:" { match_name = ($2 ~ sfx"$") }
    match_name && $1==key":" { sub(/^[^:]*: */, ""); gsub(/"/, ""); print; exit }
  ' <<<"$1"
}

grep -q 'lookup "v1" "Secret"' "$chart/templates/_helpers.tpl" || fail "helper no longer looks up the release Secret"

out=$(render "${explicit[@]}")
[ "$(secret_value "$out" -secrets encryption-key)" = explicit-encryption-key-32bytes ] || fail "explicit encryption.key not used"
cmp -s <(echo "$out") <(render "${explicit[@]}") || fail "two renders with explicit keys differ"
want=$(printf 'mnemoshare-internal-api:%s' explicit-encryption-key-32bytes | shasum -a 256 | cut -d' ' -f1)
[ "$(secret_value "$out" -sftp-gateway internal-api-secret)" = "$want" ] || fail "sftp secret not derived from explicit key"

out=$(render)
enc=$(secret_value "$out" -secrets encryption-key)
[ "${#enc}" -eq 32 ] || fail "generated encryption key is not 32 bytes: '$enc'"
want=$(printf 'mnemoshare-internal-api:%s' "$enc" | shasum -a 256 | cut -d' ' -f1)
[ "$(secret_value "$out" -sftp-gateway internal-api-secret)" = "$want" ] || fail "sftp secret not derived from the rendered generated key"

if [ "${STABLE_SECRETS_CLUSTER:-}" = 1 ]; then
  ctx=$(kubectl config current-context)
  case "$ctx" in
    kind-*) ;;
    *) [ "${STABLE_SECRETS_CONTEXT:-}" = "$ctx" ] || fail "refusing to run against context '$ctx': use a kind cluster or set STABLE_SECRETS_CONTEXT=$ctx" ;;
  esac

  ns=stable-secrets-$$
  trap 'helm uninstall t -n "$ns" >/dev/null 2>&1 || true; kubectl delete namespace "$ns" --wait=false >/dev/null 2>&1 || true' EXIT
  kubectl create namespace "$ns" >/dev/null
  live=(--no-hooks --set formatMigrations.mode=disabled)
  field() { kubectl -n "$ns" get secret t-mnemoshare-secrets -o "jsonpath={.data.$1}"; }

  helm install t "$chart" -n "$ns" "${base[@]}" "${live[@]}" >/dev/null
  enc=$(field encryption-key); jwt=$(field 'jwt-ec-private-key')
  [ -n "$enc" ] && [ -n "$jwt" ] || fail "no keys generated on first install"

  helm upgrade t "$chart" -n "$ns" "${base[@]}" "${live[@]}" >/dev/null
  [ "$(field encryption-key)" = "$enc" ] || fail "encryption key changed on upgrade"
  [ "$(field 'jwt-ec-private-key')" = "$jwt" ] || fail "JWT key changed on upgrade"

  err=$(helm upgrade t "$chart" -n "$ns" "${base[@]}" "${live[@]}" --set nameOverride=other 2>&1) && fail "upgrade under a new Secret name must fail"
  grep -q "refusing to generate" <<<"$err" || fail "unexpected upgrade failure: $err"
  [ "$(field encryption-key)" = "$enc" ] || fail "encryption key lost after refused upgrade"

  helm upgrade t "$chart" -n "$ns" "${base[@]}" "${live[@]}" --set encryption.key=explicit-encryption-key-32bytes >/dev/null
  [ "$(field encryption-key)" = "$(printf explicit-encryption-key-32bytes | base64)" ] || fail "explicit value must win on upgrade"

  helm uninstall t -n "$ns" >/dev/null
  kubectl -n "$ns" get secret t-mnemoshare-secrets >/dev/null || fail "Secret not kept on uninstall"
fi
echo "stable-secrets: ok"
