#!/usr/bin/env bash
set -euo pipefail

chart_dir=${1:-charts/mnemoshare}
contract_dir="$chart_dir/tests/contracts/migration-operation/v1"
contract_schema=$(jq -er '.provenance.schema | select(test("^mnemoshare\\.migration-operation\\.v[0-9]+$"))' "$contract_dir/contract.json")
contract_version=${contract_schema##*.}
test "$contract_version" = v1
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
jq -e '
  .commands.apply.args[-4:] == ["--status", "<status-file>", "--termination-log", "/dev/termination-log"] and
  .commands.status.args == ["status", "--file", "<status-file>", "--max-inactivity", "5m", "--absolute-deadline", "6h"]
' "$contract_dir/contract.json" >/dev/null
test "$(sed -n 's/^path=//p' "$contract_dir/UPSTREAM")" = contracts/migration-operation/v1
grep -Eq '^commit=[0-9a-f]{40}$' "$contract_dir/UPSTREAM"
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
      grep -Fq 'activeDeadlineSeconds: 1800' <<<"$render"
      grep -Fq 'name: ENVIRONMENT' <<<"$render"
      grep -Fq 'value: "production"' <<<"$render"
      grep -Fq "mnemoshare.io/migration-operation-contract-fingerprint: \"$fingerprint\"" <<<"$render"
      grep -Fq "args:" <<<"$render"
      grep -Fq -- '"--expect-contract-fingerprint"' <<<"$render"
      grep -Fq -- '"--output"' <<<"$render"
      grep -Fq -- '"--result"' <<<"$render"
      grep -Fq -- '- "plan"' <<<"$render"
      grep -Fq -- '- "--contract"' <<<"$render"
      grep -Fq -- '- "embedded"' <<<"$render"
	  grep -Fq 'phase="$0"' <<<"$render"
	  grep -Fq '/usr/local/bin/mnemoshare-migrate "$phase" "$@"' <<<"$render"
	  if grep -Eq '^[[:space:]]+shift([[:space:]]|$)' <<<"$render"; then
	    echo 'migration wrapper must not discard the first contract argument' >&2
	    exit 1
	  fi
	  ! grep -Fq '/var/run/mnemoshare-migration/status.json' <<<"$render"
      ;;
    down)
      deployment=$(awk '/# Source: mnemoshare\/templates\/deployment.yaml/{active=1} active{print} active&&/^---$/{exit}' <<<"$render")
      grep -Fq 'replicas: 0' <<<"$deployment"
      grep -Fq "mnemoshare.io/migration-operation-contract-fingerprint: \"$fingerprint\"" <<<"$deployment"
      selector=$(awk '/^  selector:/{active=1; next} active && /^  template:/{exit} active{print}' <<<"$deployment")
      ! grep -q 'mnemoshare.io/migration-operation-contract' <<<"$selector"
      ! grep -q 'kind: Job' <<<"$render"
      ! grep -Fq '/var/run/mnemoshare-migration/status.json' <<<"$render"
      ;;
    apply)
      ! grep -Fq 'activeDeadlineSeconds:' <<<"$render"
      grep -Fq 'name: ENVIRONMENT' <<<"$render"
      grep -Fq 'value: "production"' <<<"$render"
      grep -Fq "mnemoshare.io/migration-operation-contract-fingerprint: \"$fingerprint\"" <<<"$render"
      grep -Fq -- '- "apply"' <<<"$render"
      grep -Fq -- '"--expect-contract-fingerprint"' <<<"$render"
      grep -Fq -- '"--exclusive"' <<<"$render"
      grep -Fq -- '"--bootstrap-policy"' <<<"$render"
      grep -Fq -- '"provision-untracked"' <<<"$render"
      grep -Fq -- '- "--status"' <<<"$render"
      grep -Fq -- '- "/var/run/mnemoshare-migration/status.json"' <<<"$render"
      grep -Fq -- '- "--termination-log"' <<<"$render"
      grep -Fq -- '- "/dev/termination-log"' <<<"$render"
      grep -Fq 'name: migration-status' <<<"$render"
      grep -Fq 'mountPath: /var/run/mnemoshare-migration' <<<"$render"
      grep -Fq 'emptyDir: {}' <<<"$render"
      grep -Fq 'startupProbe:' <<<"$render"
      grep -Fq 'livenessProbe:' <<<"$render"
      test "$(grep -Fc 'command: ["/usr/local/bin/mnemoshare-migrate", "status", "--file", "/var/run/mnemoshare-migration/status.json", "--max-inactivity", "5m", "--absolute-deadline", "6h"]' <<<"$render")" -eq 2
      grep -Fq 'failureThreshold: 60' <<<"$render"
      grep -Fq 'periodSeconds: 30' <<<"$render"
      grep -Fq 'if [ "$phase" = "apply" ]; then' <<<"$render"
      ;;
    verify)
      grep -Fq 'activeDeadlineSeconds: 1800' <<<"$render"
      grep -Fq 'name: ENVIRONMENT' <<<"$render"
      grep -Fq 'value: "production"' <<<"$render"
      grep -Fq "mnemoshare.io/migration-operation-contract-fingerprint: \"$fingerprint\"" <<<"$render"
      grep -Fq -- '- "verify"' <<<"$render"
      grep -Fq -- '"--expect-contract-fingerprint"' <<<"$render"
      grep -Fq -- '"--expect-plan-digest"' <<<"$render"
      ! grep -Fq '/var/run/mnemoshare-migration/status.json' <<<"$render"
      ;;
    up)
      ! grep -q 'kind: Job' <<<"$render"
      grep -Fq "image: \"mnemoshare/mnemoshare@$target\"" <<<"$render"
      ! grep -Fq '/var/run/mnemoshare-migration/status.json' <<<"$render"
      ;;
  esac
done

# The full production values profile must preserve the same generated apply
# command and probe; profile defaults cannot weaken the operation contract.
full_render=$(helm template ci "$chart_dir" -f "$chart_dir/values-production.yaml" "${base[@]}" --set migrationOperation.phase=apply)
! grep -Fq 'activeDeadlineSeconds:' <<<"$full_render"
grep -Fq -- '- "--status"' <<<"$full_render"
grep -Fq -- '- "--termination-log"' <<<"$full_render"
test "$(grep -Fc 'command: ["/usr/local/bin/mnemoshare-migrate", "status", "--file", "/var/run/mnemoshare-migration/status.json", "--max-inactivity", "5m", "--absolute-deadline", "6h"]' <<<"$full_render")" -eq 2

echo 'migration-operation render contract passed'
