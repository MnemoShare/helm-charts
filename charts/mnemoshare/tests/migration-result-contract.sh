#!/usr/bin/env bash
set -euo pipefail

chart_dir=${1:-charts/mnemoshare}
test_dir=$(cd "$(dirname "$0")" && pwd)
contract_dir=${test_dir}/contracts/migration-result/v1
parser=${chart_dir}/files/migration-result-v1.jq
upstream_commit=e7537fb07d52491b70f9f4f2d2270d1bda29a763
jq_bin=${JQ:-jq}

(cd "$contract_dir" && sha256sum -c SHA256SUMS)
test "$(sed -n 's/^commit=//p' "${contract_dir}/UPSTREAM")" = "$upstream_commit"
test "$(sed -n 's/^path=//p' "${contract_dir}/UPSTREAM")" = contracts/migration-result/v1
test "$(sed -n 's/^sha256sums=//p' "${contract_dir}/UPSTREAM")" = "$(sha256sum "${contract_dir}/SHA256SUMS" | cut -d' ' -f1)"

render=$(helm template test "$chart_dir" \
  --set customerId=ci-test \
  --set image.digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --set mongodb.external.enabled=true \
  --set mongodb.external.uri=mongodb://test:test@localhost:27017/test \
  --set s3.bucket=test --set s3.accessKey=test --set s3.secretKey=test \
  --set-string jwt.ecPrivateKey=test \
  --set encryption.key=test-encryption-key-exactly-32by \
  --set license.key=test --set appUrl=https://test.example.com --set ingress.enabled=false)

extracted=$(mktemp)
trap 'rm -f "$extracted"' EXIT
awk '
  /cat > \/migration\/migration-result-v1.jq <<.MNEMOSHARE_MIGRATION_RESULT_V1./ { active=1; first=1; next }
  active && /^[[:space:]]*MNEMOSHARE_MIGRATION_RESULT_V1$/ { exit }
  active {
    sub(/^              /, "")
    if (first && $0 == "") { first=0; next }
    first=0
    print
  }
' <<<"$render" > "$extracted"
cmp "$parser" "$extracted"
grep -Fq 'jq --stream -c . /migration/result.json > /migration/result-events.jsonl' <<<"$render"
grep -Fq 'jq --slurp -e -f /migration/migration-result-v1.jq /migration/result-events.jsonl' <<<"$render"

run_vector() {
  local encoded=$1 expected=$2 name json
  name=$(printf %s "$encoded" | base64 -d | "$jq_bin" -r .name)
  events=$(mktemp)
  if printf %s "$encoded" | base64 -d | "$jq_bin" -j .json | "$jq_bin" --stream -c . >"$events" 2>/dev/null &&
     "$jq_bin" --slurp -e -f "$parser" "$events" >/dev/null 2>&1; then
    actual=valid
  else
    actual=invalid
  fi
  rm -f "$events"
  if [ "$actual" != "$expected" ]; then
    echo "migration-result/v1 ${name}: parser returned ${actual}, expected ${expected}" >&2
    exit 1
  fi
}

while IFS= read -r vector; do run_vector "$vector" valid; done < <("$jq_bin" -r '.valid[] | @base64' "${contract_dir}/conformance.json")
while IFS= read -r vector; do run_vector "$vector" invalid; done < <("$jq_bin" -r '.invalid[] | @base64' "${contract_dir}/conformance.json")
