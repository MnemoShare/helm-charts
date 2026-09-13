#!/usr/bin/env bash
set -euo pipefail

# This is deliberately an execution test, not a rendered-token test. The
# caller supplies an image built from the exact application checkout selected
# by CI; the rendered shell argv is then run by that image as uid 1000.
image=${MIGRATION_IMAGE:?MIGRATION_IMAGE must name the application image to execute}
chart_dir=${1:-charts/mnemoshare}
contract_dir="$chart_dir/tests/contracts/migration-operation/v1"
fingerprint=$(jq -er '.fingerprint | select(test("^[a-f0-9]{64}$"))' "$contract_dir/contract.json")
digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

for tool in docker helm jq python3; do
  command -v "$tool" >/dev/null || { echo "required executable missing: $tool" >&2; exit 1; }
done
docker image inspect "$image" >/dev/null

base_values=(
  --set customerId=ci-test
  --set formatMigrations.mode=automatic
  --set image.digest="$digest"
  --set mongodb.external.enabled=true
  --set mongodb.external.uri=mongodb://127.0.0.1:27017/test
  --set s3.bucket=test
  --set s3.accessKey=test
  --set s3.secretKey=test
  --set-string jwt.ecPrivateKey=test
  --set encryption.key=test-encryption-key-exactly-32by
  --set license.key=test
  --set appUrl=https://test.example.com
  --set ingress.enabled=false
)

extract_container() {
  local manifest=$1 container=$2 script_out=$3 args_out=$4
  python3 - "$manifest" "$container" "$script_out" "$args_out" <<'PY'
import base64
import sys
import yaml

manifest, wanted, script_out, args_out = sys.argv[1:]
for document in yaml.safe_load_all(open(manifest, encoding="utf-8")):
    if not isinstance(document, dict) or document.get("kind") != "Job":
        continue
    pod = document.get("spec", {}).get("template", {}).get("spec", {})
    candidates = pod.get("initContainers", []) + pod.get("containers", [])
    for container in candidates:
        if container.get("name") != wanted:
            continue
        command = container.get("command")
        args = container.get("args")
        if command != ["/bin/sh", "-ec"] or not isinstance(args, list) or len(args) < 1:
            raise SystemExit(f"{wanted}: rendered command/args are not /bin/sh -ec")
        with open(script_out, "w", encoding="utf-8") as out:
            out.write(args[0])
        with open(args_out, "w", encoding="utf-8") as out:
            for arg in args[1:]:
                if not isinstance(arg, str) or "\n" in arg:
                    raise SystemExit(f"{wanted}: non-scalar or multiline argument")
                out.write(arg)
                out.write("\n")
        raise SystemExit(0)
raise SystemExit(f"{wanted}: rendered container not found")
PY
}

docker_run() {
  local volume_root=$1 status_root=$2 script=$3
  local timeout_seconds=${DOCKER_RUN_TIMEOUT:-}
  shift 3
  local -a command=(docker run --rm --user 1000:1000 \
    --cap-drop=ALL --security-opt=no-new-privileges \
    --tmpfs /tmp:rw,nosuid,nodev,size=64m \
    -v "$volume_root:/migration" -v "$status_root:/run/mnemoshare-migration" \
    --entrypoint /bin/sh "$image" -ec "$script" "$@")
  if [ -n "$timeout_seconds" ]; then
    timeout "$timeout_seconds" "${command[@]}"
  else
    "${command[@]}"
  fi
}

new_volume_root() {
  local root
  root=$(mktemp -d "$tmp/volume.XXXXXX")
  mkdir -p "$root/migration" "$root/status"
  chmod 0777 "$root/migration" "$root/status"
  printf '%s\n' "$root"
}

# Hook: execute the exact rendered plan-before-drain script. The result and
# plan parents are created by the rendered script itself.
helm template hook "$chart_dir" "${base_values[@]}" > "$tmp/hook.yaml"
hook_root=$(new_volume_root)
extract_container "$tmp/hook.yaml" plan-before-drain "$tmp/hook.script" "$tmp/hook.args"
mapfile -t hook_args < "$tmp/hook.args"
hook_output=$(docker_run "$hook_root/migration" "$hook_root/status" "$(<"$tmp/hook.script")" "${hook_args[@]}" 2>&1)
printf '%s\n' "$hook_output" | tail -5
test -d "$hook_root/migration/artifacts"
test "$(stat -c '%a' "$hook_root/migration/artifacts")" = 700
test -s "$hook_root/migration/artifacts/result.json"

# Operation plan: execute the exact rendered migration-operation wrapper and
# retain its caller-owned plan/result files for the following apply render.
plan_digest_placeholder=$(printf 'b%.0s' {1..64})
helm template operation "$chart_dir" "${base_values[@]}" \
  --set migrationOperation.enabled=true \
  --set migrationOperation.phase=plan \
  --set migrationOperation.contractFingerprint="$fingerprint" \
  --set migrationOperation.operationId=ci-image-execution \
  --set migrationOperation.targetImage.repository=mnemoshare/mnemoshare \
  --set migrationOperation.targetImage.digest="$digest" \
  --set migrationOperation.transport.existingClaim=ci-migration \
  --set migrationOperation.planDigest="$plan_digest_placeholder" \
  --set migrationOperation.verifiedPlanDigest="$plan_digest_placeholder" > "$tmp/operation-plan.yaml"
operation_root=$(new_volume_root)
extract_container "$tmp/operation-plan.yaml" migration-operation "$tmp/operation-plan.script" "$tmp/operation-plan.args"
mapfile -t operation_plan_args < "$tmp/operation-plan.args"
operation_plan_output=$(docker_run "$operation_root/migration" "$operation_root/status" "$(<"$tmp/operation-plan.script")" "${operation_plan_args[@]}" 2>&1)
printf '%s\n' "$operation_plan_output" | tail -5
plan_digest=$(printf '%s\n' "$operation_plan_output" | grep -Eo '[a-f0-9]{64}' | tail -1)
test "${#plan_digest}" = 64
test -s "$operation_root/migration/artifacts/primary-plan.json"
test -s "$operation_root/migration/artifacts/primary-result.json"
test "$(stat -c '%a' "$operation_root/migration/artifacts")" = 700

# Operation apply: use a render carrying the plan digest produced by the
# executed plan. The unavailable SQLite target may reject the migration, but
# a filesystem-contract failure is never acceptable.
helm template operation "$chart_dir" "${base_values[@]}" \
  --set migrationOperation.enabled=true \
  --set migrationOperation.phase=apply \
  --set migrationOperation.contractFingerprint="$fingerprint" \
  --set migrationOperation.operationId=ci-image-execution \
  --set migrationOperation.targetImage.repository=mnemoshare/mnemoshare \
  --set migrationOperation.targetImage.digest="$digest" \
  --set migrationOperation.transport.existingClaim=ci-migration \
  --set migrationOperation.planDigest="$plan_digest" \
  --set migrationOperation.verifiedPlanDigest="$plan_digest" > "$tmp/operation-apply.yaml"
extract_container "$tmp/operation-apply.yaml" migration-operation "$tmp/operation-apply.script" "$tmp/operation-apply.args"
mapfile -t operation_apply_args < "$tmp/operation-apply.args"
set +e
DOCKER_RUN_TIMEOUT=45 operation_apply_output=$(docker_run "$operation_root/migration" "$operation_root/status" "$(<"$tmp/operation-apply.script")" "${operation_apply_args[@]}" 2>&1)
operation_apply_rc=$?
set -e
printf '%s\n' "$operation_apply_output" | tail -10
case "$operation_apply_output" in
  *'result parent must be caller-owned'*|*'status parent must be caller-owned'*|*'trusted status path component'*|*'not a directory'*)
    echo 'migration operation failed its in-image filesystem contract' >&2
    exit 1
    ;;
esac
test "$operation_apply_rc" -ne 124
test -d "$operation_root/status/status"
test "$(stat -c '%a' "$operation_root/status/status")" = 700

echo 'migration Job scripts executed in-image as uid 1000'
