#!/usr/bin/env bash
set -euo pipefail

chart_dir=${1:-charts/mnemoshare}
fingerprint=201bde72fb66a4cb07af10d76f752619661590702e2441422ebb0a8bd2b7a8c7
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

for phase in plan down apply verify up; do
  render=$(helm template ci "$chart_dir" "${base[@]}" --set migrationOperation.phase="$phase")
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
