#!/usr/bin/env bash
# Chart-generated secrets (encryption key, JWT EC key) must be stable:
# explicit value wins, else the value already in the release Secret, else generated.
# Offline checks always run; the lookup checks need a disposable cluster and run
# only with STABLE_SECRETS_CLUSTER=1. They refuse any context not named kind-*
# unless STABLE_SECRETS_CONTEXT is set to that exact context name; every helm and
# kubectl call is pinned to that context.
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

err=$(render --is-upgrade 2>&1) && fail "offline upgrade render without keys must fail"
grep -q "without cluster access" <<<"$err" || fail "offline upgrade message missing: $err"
render --is-upgrade "${explicit[@]}" >/dev/null || fail "offline upgrade render with explicit keys must work"

# commonLabels: strings, booleans and --set integers only; values-file numbers are floats.
labels() { helm template t "$chart" "${base[@]}" "$@" 2>&1; }
lf=$(mktemp)
for bad in 0042 1.0 0755 1e3 1.5; do
  printf 'commonLabels:\n  z: %s\n' "$bad" >"$lf"
  out=$(labels -f "$lf") && fail "commonLabels value $bad from a values file was accepted"
  grep -q "commonLabels.z must be a string or boolean" <<<"$out" || fail "unexpected commonLabels failure for $bad: $out"
done
rm -f "$lf"
out=$(labels --set commonLabels.n=-5) && fail "negative commonLabels integer was accepted"
grep -q '^    "cc": "0042"$' <<<"$(labels --set commonLabels.cc=0042)" || fail "--set commonLabels.cc=0042 not kept as a string"
grep -q '^    "n": "5"$' <<<"$(labels --set commonLabels.n=5)" || fail "--set commonLabels.n=5 not rendered as \"5\""
grep -q '^    "b": "true"$' <<<"$(labels --set commonLabels.b=true)" || fail "boolean commonLabels not rendered as \"true\""
grep -q '^    "on": "a"$' <<<"$(labels --set-string commonLabels.on=a)" || fail "YAML 1.1 boolean-like commonLabels key not quoted"

if [ "${STABLE_SECRETS_CLUSTER:-}" = 1 ]; then
  ctx=$(kubectl config current-context)
  case "$ctx" in
    kind-*) ;;
    *) [ "${STABLE_SECRETS_CONTEXT:-}" = "$ctx" ] || fail "refusing to run against context '$ctx': use a kind cluster or set STABLE_SECRETS_CONTEXT=$ctx" ;;
  esac

  ns=stable-secrets-$$
  trap 'helm --kube-context "$ctx" uninstall t -n "$ns" >/dev/null 2>&1 || true; kubectl --context "$ctx" delete namespace "$ns" --wait=false >/dev/null 2>&1 || true' EXIT
  kubectl --context "$ctx" create namespace "$ns" >/dev/null
  live=(--no-hooks --set formatMigrations.mode=disabled)
  field() { kubectl --context "$ctx" -n "$ns" get secret t-mnemoshare-secrets -o "jsonpath={.data.$1}"; }

  helm --kube-context "$ctx" install t "$chart" -n "$ns" "${base[@]}" "${live[@]}" >/dev/null
  enc=$(field encryption-key); jwt=$(field 'jwt-ec-private-key')
  [ -n "$enc" ] && [ -n "$jwt" ] || fail "no keys generated on first install"

  helm --kube-context "$ctx" upgrade t "$chart" -n "$ns" "${base[@]}" "${live[@]}" >/dev/null
  [ "$(field encryption-key)" = "$enc" ] || fail "encryption key changed on upgrade"
  [ "$(field 'jwt-ec-private-key')" = "$jwt" ] || fail "JWT key changed on upgrade"

  err=$(helm --kube-context "$ctx" upgrade t "$chart" -n "$ns" "${base[@]}" "${live[@]}" --set nameOverride=other 2>&1) && fail "upgrade under a new Secret name must fail"
  grep -q "refusing to generate" <<<"$err" && grep -q "existing files would become unreadable" <<<"$err" || fail "unexpected upgrade failure: $err"
  [ "$(field encryption-key)" = "$enc" ] || fail "encryption key lost after refused upgrade"

  helm --kube-context "$ctx" upgrade t "$chart" -n "$ns" "${base[@]}" "${live[@]}" --set encryption.key=explicit-encryption-key-32bytes >/dev/null
  [ "$(field encryption-key)" = "$(printf explicit-encryption-key-32bytes | base64)" ] || fail "explicit value must win on upgrade"

  helm --kube-context "$ctx" uninstall t -n "$ns" >/dev/null
  kubectl --context "$ctx" -n "$ns" get secret t-mnemoshare-secrets >/dev/null || fail "Secret not kept on uninstall"
fi
echo "stable-secrets: ok"
