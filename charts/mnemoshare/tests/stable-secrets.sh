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
  ns=stable-secrets-$$
  trap 'kubectl delete namespace "$ns" --wait=false >/dev/null 2>&1 || true' EXIT
  kubectl create namespace "$ns" >/dev/null
  dry() { helm install t "$chart" -n "$ns" "${base[@]}" --dry-run=server "$@"; }

  out=$(dry)
  [ "$(secret_value "$out" -secrets encryption-key)" ] || fail "no key rendered on first install"
  kubectl -n "$ns" create secret generic t-mnemoshare-secrets \
    --from-literal=encryption-key=existing-encryption-key-32byte \
    --from-literal=jwt-ec-private-key=existing-ec-key >/dev/null
  kubectl -n "$ns" label secret t-mnemoshare-secrets app.kubernetes.io/managed-by=Helm >/dev/null
  kubectl -n "$ns" annotate secret t-mnemoshare-secrets meta.helm.sh/release-name=t "meta.helm.sh/release-namespace=$ns" >/dev/null

  out=$(dry)
  [ "$(secret_value "$out" -secrets encryption-key)" = existing-encryption-key-32byte ] || fail "existing encryption key not reused"
  [ "$(secret_value "$out" -secrets jwt-ec-private-key)" = existing-ec-key ] || fail "existing JWT key not reused"
  want=$(printf 'mnemoshare-internal-api:%s' existing-encryption-key-32byte | shasum -a 256 | cut -d' ' -f1)
  [ "$(secret_value "$out" -sftp-gateway internal-api-secret)" = "$want" ] || fail "sftp secret not derived from the existing key"

  out=$(dry "${explicit[@]}")
  [ "$(secret_value "$out" -secrets encryption-key)" = explicit-encryption-key-32bytes ] || fail "explicit value must win over the existing Secret"
fi
echo "stable-secrets: ok"
