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
relay_profile=(
  --set emailGateway.enabled=true
  --set emailGateway.mode=relay
  --set emailGateway.smtpAuthRequired=false
  --set emailGateway.relay.spoolSharedKey=spool
  --set emailGateway.relay.db.existingSecret=relay-db
)
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
  .commands.apply.args[-4:] == ["--status", "<status-file>", "--termination-file", "<status-dir>/termination.json"] and
  .commands.status.args == ["status", "--file", "<status-file>", "--termination-file", "<status-dir>/termination.json", "--max-inactivity", "5m", "--absolute-deadline", "6h"] and
  .commands.reset.args[-8:] == ["--status", "<status-file>", "--termination-file", "<status-dir>/termination.json", "--max-inactivity", "5m", "--absolute-deadline", "6h"] and
  .result.terminationFile.kubernetesTerminationMessagePath == "<status-dir>/termination.json" and
  .result.terminationFile.pathBinding == "equal-to-termination-file-argument" and
  .result.statusFile.parentTrust == "caller-owned-not-group-or-world-writable" and
  .result.planFile.target == "same-parent-atomic-create-or-replace" and
  .result.planFile.publication == "same-parent-temp-fsync-rename-fsync-parent" and
  .result.resultFile.parentTrust == "caller-owned-owner-writable-not-world-writable" and
  .result.resultFile.target == "same-parent-atomic-create-or-replace"
' "$contract_dir/contract.json" >/dev/null
test "$(sed -n 's/^path=//p' "$contract_dir/UPSTREAM")" = contracts/migration-operation/v1
grep -Eq '^commit=[0-9a-f]{40}$' "$contract_dir/UPSTREAM"
test "$(sed -n 's/^sha256sums=//p' "$contract_dir/UPSTREAM")" = "$(sha256sum "$contract_dir/SHA256SUMS" | cut -d' ' -f1)"
grep -Fq "\"fingerprint\":\"$fingerprint\"" "$contract_dir/contract.json"
grep -Fq "\"sourceFingerprint\":\"$source_fingerprint\"" "$contract_dir/contract.json"
grep -Fxq "contractFingerprint=$fingerprint" "$contract_dir/UPSTREAM"
grep -Fxq "sourceFingerprint=$source_fingerprint" "$contract_dir/UPSTREAM"

for phase in reset plan down apply verify up; do
  render=$(helm template ci "$chart_dir" "${base[@]}" --set migrationOperation.phase="$phase")
  grep -Fq "mnemoshare.io/migration-operation-contract: \"$contract_version\"" <<<"$render"
  grep -Fq "mnemoshare.io/migration-operation-contract-fingerprint: \"$fingerprint\"" <<<"$render"
  case "$phase" in
    reset)
      ! grep -Fq 'activeDeadlineSeconds:' <<<"$render"
      grep -Fq -- '- "reset"' <<<"$render"
      grep -Fq 'if [ "$phase" = "reset" ]; then command="pre-1-reset-format-ledger"; fi' <<<"$render"
      grep -Fq -- '- "--exclusive"' <<<"$render"
      grep -Fq -- '- "--confirm-before-first-1.0"' <<<"$render"
      grep -Fq -- '- "--status"' <<<"$render"
      grep -Fq -- '- "--termination-file"' <<<"$render"
      grep -Fq -- '- "/run/mnemoshare-migration/status/termination.json"' <<<"$render"
      grep -Fq 'terminationMessagePath: "/run/mnemoshare-migration/status/termination.json"' <<<"$render"
      grep -Fq 'name: migration-status' <<<"$render"
      grep -Fq 'startupProbe:' <<<"$render"
      grep -Fq 'livenessProbe:' <<<"$render"
      test "$(grep -Fc 'command: ["/usr/local/bin/mnemoshare-migrate", "status", "--file", "/run/mnemoshare-migration/status/status.json", "--termination-file", "/run/mnemoshare-migration/status/termination.json", "--max-inactivity", "5m", "--absolute-deadline", "6h"]' <<<"$render")" -eq 2
      ! grep -Fq -- '- "--contract"' <<<"$render"
      ;;
    plan)
      grep -Fq 'activeDeadlineSeconds: 1800' <<<"$render"
      grep -Fq 'name: ENVIRONMENT' <<<"$render"
      grep -Fq 'value: "production"' <<<"$render"
      grep -Fq "mnemoshare.io/migration-operation-contract-fingerprint: \"$fingerprint\"" <<<"$render"
      grep -Fq "args:" <<<"$render"
      grep -Fq -- '"--expect-contract-fingerprint"' <<<"$render"
      grep -Fq -- '"--output"' <<<"$render"
      grep -Fq -- '"--result"' <<<"$render"
      grep -Fq -- '- "/migration/artifacts/primary-plan.json"' <<<"$render"
      grep -Fq -- '- "/migration/artifacts/primary-result.json"' <<<"$render"
      grep -Fq 'mkdir -p "/migration/artifacts"' <<<"$render"
      grep -Fq 'chmod 0700 "/migration/artifacts"' <<<"$render"
      grep -Fq -- '- "plan"' <<<"$render"
      grep -Fq -- '- "--contract"' <<<"$render"
      grep -Fq -- '- "embedded"' <<<"$render"
	  grep -Fq 'phase="$0"' <<<"$render"
	  grep -Fq 'exec /usr/local/bin/mnemoshare-migrate "$command" "$@"' <<<"$render"
	  grep -Fq '/usr/local/bin/mnemoshare-migrate "$command" "$@"' <<<"$render"
	  if grep -Eq '^[[:space:]]+shift([[:space:]]|$)' <<<"$render"; then
	    echo 'migration wrapper must not discard the first contract argument' >&2
	    exit 1
	  fi
	  ! grep -Fq '/run/mnemoshare-migration/' <<<"$render"
      ;;
    down)
      deployment=$(awk '/# Source: mnemoshare\/templates\/deployment.yaml/{active=1} active{print} active&&/^---$/{exit}' <<<"$render")
      grep -Fq 'replicas: 0' <<<"$deployment"
      grep -Fq "mnemoshare.io/migration-operation-contract-fingerprint: \"$fingerprint\"" <<<"$deployment"
      selector=$(awk '/^  selector:/{active=1; next} active && /^  template:/{exit} active{print}' <<<"$deployment")
      ! grep -q 'mnemoshare.io/migration-operation-contract' <<<"$selector"
      ! grep -q 'kind: Job' <<<"$render"
      ! grep -Fq '/run/mnemoshare-migration/' <<<"$render"
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
      grep -Fq -- '- "/run/mnemoshare-migration/status/status.json"' <<<"$render"
      grep -Fq -- '- "--termination-file"' <<<"$render"
      grep -Fq -- '- "/run/mnemoshare-migration/status/termination.json"' <<<"$render"
      grep -Fq 'name: migration-status' <<<"$render"
      grep -Fq 'mountPath: /run/mnemoshare-migration' <<<"$render"
      grep -Fq 'emptyDir: {}' <<<"$render"
      grep -Fq 'fsGroup: 1000' <<<"$render"
      grep -Fq 'runAsNonRoot: true' <<<"$render"
      grep -Fq 'runAsUser: 1000' <<<"$render"
      grep -Fq 'umask 077' <<<"$render"
      grep -Fq 'mkdir -p "/run/mnemoshare-migration/status"' <<<"$render"
      grep -Fq 'chmod 0700 "/run/mnemoshare-migration/status"' <<<"$render"
      grep -Fq 'startupProbe:' <<<"$render"
      grep -Fq 'livenessProbe:' <<<"$render"
      test "$(grep -Fc 'command: ["/usr/local/bin/mnemoshare-migrate", "status", "--file", "/run/mnemoshare-migration/status/status.json", "--termination-file", "/run/mnemoshare-migration/status/termination.json", "--max-inactivity", "5m", "--absolute-deadline", "6h"]' <<<"$render")" -eq 2
      grep -Fq 'failureThreshold: 60' <<<"$render"
      grep -Fq 'periodSeconds: 30' <<<"$render"
      grep -Fq 'if [ "$phase" = "apply" ] || [ "$phase" = "reset" ]; then' <<<"$render"
      ;;
    verify)
      grep -Fq 'activeDeadlineSeconds: 1800' <<<"$render"
      grep -Fq 'name: ENVIRONMENT' <<<"$render"
      grep -Fq 'value: "production"' <<<"$render"
      grep -Fq "mnemoshare.io/migration-operation-contract-fingerprint: \"$fingerprint\"" <<<"$render"
      grep -Fq -- '- "verify"' <<<"$render"
      grep -Fq -- '"--expect-contract-fingerprint"' <<<"$render"
      grep -Fq -- '"--expect-plan-digest"' <<<"$render"
      ! grep -Fq '/run/mnemoshare-migration/' <<<"$render"
      ;;
    up)
      ! grep -q 'kind: Job' <<<"$render"
      grep -Fq "image: \"mnemoshare/mnemoshare@$target\"" <<<"$render"
      ! grep -Fq '/run/mnemoshare-migration/' <<<"$render"
      ;;
  esac
done

if helm template ci "$chart_dir" "${base[@]}" --set migrationOperation.phase=reset --set migrationOperation.universe=email-relay-mongo >/dev/null 2>&1; then
  echo 'primary format-ledger reset accepted an external universe' >&2
  exit 1
fi

# The full production values profile must preserve the same generated apply
# command and probe; profile defaults cannot weaken the operation contract.
full_render=$(helm template ci "$chart_dir" -f "$chart_dir/values-production.yaml" "${base[@]}" --set migrationOperation.phase=apply)
! grep -Fq 'activeDeadlineSeconds:' <<<"$full_render"
grep -Fq -- '- "--status"' <<<"$full_render"
grep -Fq -- '- "--termination-file"' <<<"$full_render"
test "$(grep -Fc 'command: ["/usr/local/bin/mnemoshare-migrate", "status", "--file", "/run/mnemoshare-migration/status/status.json", "--termination-file", "/run/mnemoshare-migration/status/termination.json", "--max-inactivity", "5m", "--absolute-deadline", "6h"]' <<<"$full_render")" -eq 2

# Every universe declared by the canonical contract has a concrete adapter.
# The relay universe uses its own durable files and credentials and passes the
# exact closed universe identity to every command.
for phase in plan apply verify; do
  relay_render=$(helm template ci "$chart_dir" "${base[@]}" "${relay_profile[@]}" \
    --set migrationOperation.universe=email-relay-mongo \
    --set migrationOperation.phase="$phase")
  grep -Fq -- '- "--universe"' <<<"$relay_render"
  grep -Fq -- '- "email-relay-mongo"' <<<"$relay_render"
  grep -Fq '/migration/artifacts/email-relay-plan.json' <<<"$relay_render"
  grep -Fq 'name: RELAY_DB_URI' <<<"$relay_render"
  grep -Fq 'name: relay-db' <<<"$relay_render"
  grep -Fq 'key: relay-db-uri' <<<"$relay_render"
  grep -Fq 'name: RELAY_DB_NAME' <<<"$relay_render"
  ! grep -Fq '/migration/artifacts/primary-plan.json' <<<"$relay_render"
done

# A configured external universe must be planned before down; failure occurs
# at render time, before the chart can emit a zero-replica workload.
if helm template ci "$chart_dir" "${base[@]}" --set migrationOperation.phase=down --set-string migrationOperation.planDigest= >/dev/null 2>&1; then
  echo 'down rendered without the primary plan proof' >&2
  exit 1
fi
if helm template ci "$chart_dir" "${base[@]}" "${relay_profile[@]}" --set migrationOperation.phase=down >/dev/null 2>&1; then
  echo 'down rendered without the email-relay-mongo plan proof' >&2
  exit 1
fi
helm template ci "$chart_dir" "${base[@]}" "${relay_profile[@]}" --set migrationOperation.phase=down --set migrationOperation.externalPlanDigest="$plan" >/dev/null
if helm template ci "$chart_dir" "${base[@]}" "${relay_profile[@]}" --set migrationOperation.phase=apply >/dev/null 2>&1; then
  echo 'primary apply rendered without the email-relay-mongo plan proof' >&2
  exit 1
fi
if helm template ci "$chart_dir" "${base[@]}" "${relay_profile[@]}" --set migrationOperation.phase=up >/dev/null 2>&1; then
  echo 'up rendered with absent email-relay-mongo plan and verification proofs' >&2
  exit 1
fi
if helm template ci "$chart_dir" "${base[@]}" "${relay_profile[@]}" --set migrationOperation.phase=up --set migrationOperation.externalPlanDigest="$plan" >/dev/null 2>&1; then
  echo 'up rendered without verified email-relay-mongo proof' >&2
  exit 1
fi
helm template ci "$chart_dir" "${base[@]}" "${relay_profile[@]}" --set migrationOperation.phase=up --set migrationOperation.externalPlanDigest="$plan" --set migrationOperation.verifiedExternalPlanDigest="$plan" >/dev/null

# Names retain a digest of the complete identity. Long IDs that differ only
# after the visible truncation therefore cannot select the same Job.
long_a=$(printf 'a%.0s' {1..62})
long_b="${long_a%?}b"
name_a=$(helm template this-is-a-deliberately-long-release-name "$chart_dir" "${base[@]}" --set migrationOperation.phase=plan --set migrationOperation.operationId="$long_a" | awk '/^kind: Job$/{job=1} job && /^  name:/{print $2; exit}')
name_b=$(helm template this-is-a-deliberately-long-release-name "$chart_dir" "${base[@]}" --set migrationOperation.phase=plan --set migrationOperation.operationId="$long_b" | awk '/^kind: Job$/{job=1} job && /^  name:/{print $2; exit}')
test "$name_a" != "$name_b"
test "${#name_a}" -le 63
test "${#name_b}" -le 63
if helm template ci "$chart_dir" "${base[@]}" --set migrationOperation.phase=plan --set migrationOperation.transport.existingClaim="$(printf 'p%.0s' {1..64})" >/dev/null 2>&1; then
  echo 'migration transport PVC name longer than 63 characters rendered' >&2
  exit 1
fi

echo 'migration-operation render contract passed'
