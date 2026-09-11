#!/usr/bin/env bash
set -euo pipefail

chart_dir=${1:-charts/mnemoshare}
contract_dir="$chart_dir/tests/contracts/migration-operation/v2"
contract_schema=$(jq -er '.provenance.schema | select(test("^mnemoshare\\.migration-operation\\.v[0-9]+$"))' "$contract_dir/contract.json")
contract_version=${contract_schema##*.}
test "$contract_version" = v2
fingerprint=$(jq -er '.fingerprint | select(test("^[a-f0-9]{64}$"))' "$contract_dir/contract.json")
source_fingerprint=$(jq -er '.provenance.sourceFingerprint | select(test("^[a-f0-9]{64}$"))' "$contract_dir/contract.json")
target=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
plan=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
base=(
  --set customerId=ci-test
  --set formatMigrations.mode=operator
  --set image.digest="$target"
  --set migrationOperation.enabled=true
  --set migrationOperation.contractFingerprint="$fingerprint"
  --set migrationOperation.operationId=ci-op
  --set migrationOperation.targetImage.repository=mnemoshare/mnemoshare
  --set migrationOperation.targetImage.digest="$target"
  --set migrationOperation.transport.existingClaim=ci-migration
  --set migrationOperation.planDigest="$plan"
  --set migrationOperation.verifiedPlanDigest="$plan"
)

(cd "$contract_dir" && sha256sum -c SHA256SUMS)
test "$(sed -n 's/^path=//p' "$contract_dir/UPSTREAM")" = contracts/migration-operation/v2
test "$(sed -n 's/^commit=//p' "$contract_dir/UPSTREAM")" = 7f163a8579fd412b4cae4eb4b9cd1d2932a42254
test "$(sed -n 's/^sha256sums=//p' "$contract_dir/UPSTREAM")" = "$(sha256sum "$contract_dir/SHA256SUMS" | cut -d' ' -f1)"
grep -Fq "\"fingerprint\":\"$fingerprint\"" "$contract_dir/contract.json"
grep -Fq "\"sourceFingerprint\":\"$source_fingerprint\"" "$contract_dir/contract.json"
grep -Fxq "contractFingerprint=$fingerprint" "$contract_dir/UPSTREAM"
grep -Fxq "sourceFingerprint=$source_fingerprint" "$contract_dir/UPSTREAM"

for phase in plan down apply verify up; do
  render=$(helm template ci "$chart_dir" "${base[@]}" --set migrationOperation.phase="$phase")
  grep -Fq "mnemoshare.io/migration-operation-contract: \"$contract_version\"" <<<"$render"
  grep -Fq "mnemoshare.io/migration-operation-contract-fingerprint: \"$fingerprint\"" <<<"$render"
  case "$phase" in
    plan)
      grep -Fq "mnemoshare.io/migration-operation-contract-fingerprint: \"$fingerprint\"" <<<"$render"
      grep -Fq "args:" <<<"$render"
      grep -Fq -- '"--expect-contract-fingerprint"' <<<"$render"
      grep -Fq -- '"--output"' <<<"$render"
      grep -Fq -- '"--result"' <<<"$render"
      grep -Fq -- '- "plan"' <<<"$render"
      grep -Fq -- '- "--contract"' <<<"$render"
      grep -Fq -- '- "embedded"' <<<"$render"
      ;;
    down)
      deployment=$(awk '/# Source: mnemoshare\/templates\/deployment.yaml/{active=1} active{print} active&&/^---$/{exit}' <<<"$render")
      grep -Fq 'replicas: 0' <<<"$deployment"
      grep -Fq "mnemoshare.io/migration-operation-contract-fingerprint: \"$fingerprint\"" <<<"$deployment"
      ! grep -q 'kind: Job' <<<"$render"
      ;;
    apply)
      grep -Fq "mnemoshare.io/migration-operation-contract-fingerprint: \"$fingerprint\"" <<<"$render"
      grep -Fq -- '- "apply"' <<<"$render"
      grep -Fq -- '"--expect-contract-fingerprint"' <<<"$render"
      grep -Fq -- '"--exclusive"' <<<"$render"
      grep -Fq -- '"--bootstrap-policy"' <<<"$render"
      grep -Fq -- '"provision-untracked"' <<<"$render"
      ;;
    verify)
      grep -Fq "mnemoshare.io/migration-operation-contract-fingerprint: \"$fingerprint\"" <<<"$render"
      grep -Fq -- '- "verify"' <<<"$render"
      grep -Fq -- '"--expect-contract-fingerprint"' <<<"$render"
      grep -Fq -- '"--expect-plan-digest"' <<<"$render"
      ;;
    up)
      ! grep -q 'kind: Job' <<<"$render"
      grep -Fq "image: \"mnemoshare/mnemoshare@$target\"" <<<"$render"
      ;;
  esac
done

echo 'migration-operation render contract passed'
