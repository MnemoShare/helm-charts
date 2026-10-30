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
  --set network.trustedProxyCIDRs=none
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

assert_job_and_pod_annotation() {
  local render=$1 key=$2 value=$3 job job_labels job_annotations pod_labels pod_annotations
  job=$(awk '/^kind: Job$/{active=1} active{print}' <<<"$render")
  job_labels=$(awk '/^  labels:/{active=1; next} active && /^  annotations:/{exit} active{print}' <<<"$job")
  job_annotations=$(awk '/^  annotations:/{active=1; next} active && /^spec:/{exit} active{print}' <<<"$job")
  pod_labels=$(awk '/^      labels:/{active=1; next} active && /^      annotations:/{exit} active{print}' <<<"$job")
  pod_annotations=$(awk '/^      annotations:/{active=1; next} active && /^    spec:/{exit} active{print}' <<<"$job")
  if grep -Fq "$value" <<<"$job_labels" || grep -Fq "$value" <<<"$pod_labels"; then
    echo "$key full digest escaped into a Kubernetes label" >&2
    return 1
  fi
  grep -Fq "$key: \"$value\"" <<<"$job_annotations"
  grep -Fq "$key: \"$value\"" <<<"$pod_annotations"
}

assert_operation_routing_labels() {
  local render=$1 phase=$2 job pod_labels
  job=$(awk '/^kind: Job$/{active=1} active{print}' <<<"$render")
  pod_labels=$(awk '/^      labels:/{active=1; next} active && /^      annotations:/{exit} active{print}' <<<"$job")
  grep -Fq 'mnemoshare.io/migration-operation-id: "ci-op"' <<<"$pod_labels"
  grep -Fq "mnemoshare.io/migration-operation-phase: \"$phase\"" <<<"$pod_labels"
  grep -Fq 'mnemoshare.io/migration-operation-universe: "primary"' <<<"$pod_labels"
}

# The operation container runs mnemoshare-migrate in exec form; launch owns the
# private directories, phase-specific outcome line and exit-status propagation.
assert_operation_argv() {
  local render=$1 expected=$2 actual
  actual=$(python3 -c '
import sys, yaml
for document in yaml.safe_load_all(sys.stdin):
    if not document or document.get("kind") != "Job":
        continue
    for container in document["spec"]["template"]["spec"]["containers"]:
        if container["name"] == "migration-operation":
            print(" ".join((container.get("command") or []) + (container.get("args") or [])))
            sys.exit(0)
sys.exit("migration-operation container not rendered")
' <<<"$render")
  if [ "$actual" != "$expected" ]; then
    printf 'migration-operation argv mismatch\n  actual:   %s\n  expected: %s\n' "$actual" "$expected" >&2
    return 1
  fi
}
migrate=/usr/local/bin/mnemoshare-migrate
status_args="--status /run/mnemoshare-migration/status/status.json --termination-file /run/mnemoshare-migration/status/termination.json --termination-message-file /run/mnemoshare-migration/termination-message"
contract_args="--contract embedded --expect-contract-fingerprint $fingerprint"

(cd "$contract_dir" && sha256sum -c SHA256SUMS)
jq -e '
  .commands.apply.args[-6:] == ["--status", "<status-file>", "--termination-file", "<status-dir>/termination.json", "--termination-message-file", "<termination-message-file>"] and
  .commands.status.args == ["status", "--file", "<status-file>", "--termination-file", "<status-dir>/termination.json", "--termination-message-file", "<termination-message-file>", "--max-inactivity", "5m", "--absolute-deadline", "6h"] and
  .commands.reset.args[-10:] == ["--status", "<status-file>", "--termination-file", "<status-dir>/termination.json", "--termination-message-file", "<termination-message-file>", "--max-inactivity", "5m", "--absolute-deadline", "6h"] and
  .result.terminationMessageFlag == "--termination-message-file" and
  .result.terminationFile.target == "<status-dir>/termination.json" and
  .result.terminationFile.kubernetesTerminationMessage.argument == "<termination-message-file>" and
  .result.terminationFile.kubernetesTerminationMessage.location == "<status-dir>/../termination-message" and
  .result.terminationFile.kubernetesTerminationMessage.podSpecField == "container.terminationMessagePath" and
  .result.terminationFile.kubernetesTerminationMessage.pathBinding == "pod-spec-field-equal-to-termination-message-file-argument" and
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
  grep -Fq "mnemoshare.io/migration-operation-contract-id: \"${fingerprint:0:16}\"" <<<"$render"
  case "$phase" in
    reset)
      assert_operation_routing_labels "$render" "$phase"
      assert_job_and_pod_annotation "$render" mnemoshare.io/migration-operation-contract-fingerprint "$fingerprint"
      assert_job_and_pod_annotation "$render" mnemoshare.io/migration-operation-plan-digest "$plan"
      deployment=$(awk '/# Source: mnemoshare\/templates\/deployment.yaml/{active=1} active{print} active&&/^---$/{exit}' <<<"$render")
      grep -Fq 'replicas: 0' <<<"$deployment"
      inbound_render=$(helm template ci "$chart_dir" "${base[@]}" --set migrationOperation.phase=reset --set inboundGateway.enabled=true)
      inbound=$(awk '/# Source: mnemoshare\/templates\/inbound-gateway-deployment.yaml/{active=1} active{print} active&&/^---$/{exit}' <<<"$inbound_render")
      grep -Fq 'replicas: 0' <<<"$inbound"
      ! grep -Fq 'activeDeadlineSeconds:' <<<"$render"
      assert_operation_argv "$render" "$migrate launch --private-dir /migration/artifacts --private-dir /run/mnemoshare-migration/status -- pre-1-reset-format-ledger --exclusive --confirm-before-first-1.0 $status_args --max-inactivity 5m --absolute-deadline 6h"
      grep -Fq -- '- "--exclusive"' <<<"$render"
      grep -Fq -- '- "--confirm-before-first-1.0"' <<<"$render"
      grep -Fq -- '- "--status"' <<<"$render"
      grep -Fq -- '- "--termination-file"' <<<"$render"
      grep -Fq -- '- "/run/mnemoshare-migration/status/termination.json"' <<<"$render"
      grep -Fq -- '- "--termination-message-file"' <<<"$render"
      grep -Fq -- '- "/run/mnemoshare-migration/termination-message"' <<<"$render"
      grep -Fq 'terminationMessagePath: "/run/mnemoshare-migration/termination-message"' <<<"$render"
      grep -Fq 'name: migration-status' <<<"$render"
      grep -Fq 'name: migration-transport' <<<"$render"
      grep -Fq 'emptyDir: {}' <<<"$render"
      grep -Fq 'startupProbe:' <<<"$render"
      grep -Fq 'livenessProbe:' <<<"$render"
      test "$(grep -Fc 'command: ["/usr/local/bin/mnemoshare-migrate", "status", "--file", "/run/mnemoshare-migration/status/status.json", "--termination-file", "/run/mnemoshare-migration/status/termination.json", "--termination-message-file", "/run/mnemoshare-migration/termination-message", "--max-inactivity", "5m", "--absolute-deadline", "6h"]' <<<"$render")" -eq 2
      ! grep -Fq -- '- "--contract"' <<<"$render"
      ;;
    plan)
      assert_operation_routing_labels "$render" "$phase"
      grep -Fq 'activeDeadlineSeconds: 1800' <<<"$render"
      grep -Fq 'name: ENVIRONMENT' <<<"$render"
      grep -Fq 'value: "production"' <<<"$render"
      assert_job_and_pod_annotation "$render" mnemoshare.io/migration-operation-contract-fingerprint "$fingerprint"
      assert_job_and_pod_annotation "$render" mnemoshare.io/migration-operation-plan-digest "$plan"
      grep -Fq "args:" <<<"$render"
      grep -Fq -- '"--expect-contract-fingerprint"' <<<"$render"
      grep -Fq -- '"--output"' <<<"$render"
      grep -Fq -- '"--result"' <<<"$render"
      grep -Fq -- '- "/migration/artifacts/primary-plan.json"' <<<"$render"
      grep -Fq -- '- "/migration/artifacts/primary-result.json"' <<<"$render"
      grep -Fq -- '- "plan"' <<<"$render"
      grep -Fq -- '- "--contract"' <<<"$render"
      grep -Fq -- '- "embedded"' <<<"$render"
      assert_operation_argv "$render" "$migrate launch --private-dir /migration/artifacts -- plan $contract_args --output /migration/artifacts/primary-plan.json --result /migration/artifacts/primary-result.json"
      ! grep -Fq '/run/mnemoshare-migration/' <<<"$render"
      ;;
    down)
      deployment=$(awk '/# Source: mnemoshare\/templates\/deployment.yaml/{active=1} active{print} active&&/^---$/{exit}' <<<"$render")
      grep -Fq 'replicas: 0' <<<"$deployment"
      grep -Fq "mnemoshare.io/migration-operation-contract-id: \"${fingerprint:0:16}\"" <<<"$deployment"
      selector=$(awk '/^  selector:/{active=1; next} active && /^  template:/{exit} active{print}' <<<"$deployment")
      ! grep -q 'mnemoshare.io/migration-operation-contract' <<<"$selector"
      ! grep -q 'kind: Job' <<<"$render"
      ! grep -Fq '/run/mnemoshare-migration/' <<<"$render"
      ;;
    apply)
      assert_operation_routing_labels "$render" "$phase"
      ! grep -Fq 'activeDeadlineSeconds:' <<<"$render"
      grep -Fq 'name: ENVIRONMENT' <<<"$render"
      grep -Fq 'value: "production"' <<<"$render"
      assert_job_and_pod_annotation "$render" mnemoshare.io/migration-operation-contract-fingerprint "$fingerprint"
      assert_job_and_pod_annotation "$render" mnemoshare.io/migration-operation-plan-digest "$plan"
      grep -Fq -- '- "apply"' <<<"$render"
      grep -Fq -- '"--expect-contract-fingerprint"' <<<"$render"
      grep -Fq -- '"--exclusive"' <<<"$render"
      grep -Fq -- '"--bootstrap-policy"' <<<"$render"
      grep -Fq -- '"provision-untracked"' <<<"$render"
      grep -Fq -- '- "--status"' <<<"$render"
      grep -Fq -- '- "/run/mnemoshare-migration/status/status.json"' <<<"$render"
      grep -Fq -- '- "--termination-file"' <<<"$render"
      grep -Fq -- '- "/run/mnemoshare-migration/status/termination.json"' <<<"$render"
      grep -Fq -- '- "--termination-message-file"' <<<"$render"
      grep -Fq -- '- "/run/mnemoshare-migration/termination-message"' <<<"$render"
      grep -Fq 'terminationMessagePath: "/run/mnemoshare-migration/termination-message"' <<<"$render"
      ! grep -Fq 'terminationMessagePath: "/run/mnemoshare-migration/status/' <<<"$render"
      grep -Fq 'name: migration-status' <<<"$render"
      grep -Fq 'mountPath: /run/mnemoshare-migration' <<<"$render"
      grep -Fq 'emptyDir: {}' <<<"$render"
      grep -Fq 'fsGroup: 1000' <<<"$render"
      grep -Fq 'runAsNonRoot: true' <<<"$render"
      grep -Fq 'runAsUser: 1000' <<<"$render"
      assert_operation_argv "$render" "$migrate launch --private-dir /migration/artifacts --private-dir /run/mnemoshare-migration/status -- apply $contract_args --plan /migration/artifacts/primary-plan.json --expect-plan-digest $plan --exclusive --bootstrap-policy provision-untracked $status_args"
      grep -Fq 'startupProbe:' <<<"$render"
      grep -Fq 'livenessProbe:' <<<"$render"
      test "$(grep -Fc 'command: ["/usr/local/bin/mnemoshare-migrate", "status", "--file", "/run/mnemoshare-migration/status/status.json", "--termination-file", "/run/mnemoshare-migration/status/termination.json", "--termination-message-file", "/run/mnemoshare-migration/termination-message", "--max-inactivity", "5m", "--absolute-deadline", "6h"]' <<<"$render")" -eq 2
      grep -Fq 'failureThreshold: 60' <<<"$render"
      grep -Fq 'periodSeconds: 30' <<<"$render"
      ;;
    verify)
      assert_operation_routing_labels "$render" "$phase"
      grep -Fq 'activeDeadlineSeconds: 1800' <<<"$render"
      grep -Fq 'name: ENVIRONMENT' <<<"$render"
      grep -Fq 'value: "production"' <<<"$render"
      assert_job_and_pod_annotation "$render" mnemoshare.io/migration-operation-contract-fingerprint "$fingerprint"
      assert_job_and_pod_annotation "$render" mnemoshare.io/migration-operation-plan-digest "$plan"
      grep -Fq -- '- "verify"' <<<"$render"
      grep -Fq -- '"--expect-contract-fingerprint"' <<<"$render"
      grep -Fq -- '"--expect-plan-digest"' <<<"$render"
      assert_operation_argv "$render" "$migrate launch --private-dir /migration/artifacts --report-operation-id ci-op --report-phase verify --report-universe primary --report-plan-digest $plan -- verify $contract_args --plan /migration/artifacts/primary-plan.json --expect-plan-digest $plan"
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

# Reset is the destructive pre-1 escape hatch. It must structurally drain the
# governed application and needs no persistent plan transport.
reset_without_transport=$(helm template ci "$chart_dir" "${base[@]}" \
  --set migrationOperation.phase=reset \
  --set migrationOperation.suspend=true \
  --set-string migrationOperation.transport.existingClaim=)
grep -Fq 'replicas: 0' <<<"$reset_without_transport"
grep -Fq 'suspend: true' <<<"$reset_without_transport"
grep -Fq 'name: migration-transport' <<<"$reset_without_transport"
grep -Fq 'emptyDir: {}' <<<"$reset_without_transport"

# The full production values profile must preserve the same generated apply
# command and probe; profile defaults cannot weaken the operation contract.
full_render=$(helm template ci "$chart_dir" -f "$chart_dir/values-production.yaml" "${base[@]}" --set migrationOperation.phase=apply)
! grep -Fq 'activeDeadlineSeconds:' <<<"$full_render"
grep -Fq -- '- "--status"' <<<"$full_render"
grep -Fq -- '- "--termination-file"' <<<"$full_render"
test "$(grep -Fc 'command: ["/usr/local/bin/mnemoshare-migrate", "status", "--file", "/run/mnemoshare-migration/status/status.json", "--termination-file", "/run/mnemoshare-migration/status/termination.json", "--termination-message-file", "/run/mnemoshare-migration/termination-message", "--max-inactivity", "5m", "--absolute-deadline", "6h"]' <<<"$full_render")" -eq 2

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
  if [ "$phase" = verify ]; then
    assert_operation_argv "$relay_render" "$migrate launch --private-dir /migration/artifacts --report-operation-id ci-op --report-phase verify --report-universe email-relay-mongo --report-plan-digest $plan -- verify $contract_args --universe email-relay-mongo --plan /migration/artifacts/email-relay-plan.json --expect-plan-digest $plan"
  fi
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
