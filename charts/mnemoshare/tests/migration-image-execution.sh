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

docker_prepare_volumes() {
  local volume_root=$1 status_root=$2
  # Host-created bind mounts are deliberately normalized by a root helper so
  # the actual migration scripts exercise the same root-owned, setgid volume
  # boundary as kubelet-provisioned emptyDirs while still running as uid 1000.
  docker run --rm --user 0:0 --read-only \
    --tmpfs /tmp:rw,nosuid,nodev,noexec,size=16m,mode=1777 \
    -v "$volume_root:/migration" -v "$status_root:/run/mnemoshare-migration" \
    --entrypoint /bin/sh "$image" -ec \
    'chown 0:0 /migration /run/mnemoshare-migration && chmod 2777 /migration /run/mnemoshare-migration'
  test "$(stat -c '%u:%g:%a' "$volume_root")" = 0:0:2777
  test "$(stat -c '%u:%g:%a' "$status_root")" = 0:0:2777
}

docker_run() {
  local volume_root=$1 status_root=$2 script=$3
  local timeout_seconds=${DOCKER_RUN_TIMEOUT:-}
  shift 3
  local -a command=(docker run --rm --read-only --user 1000:1000 \
    --cap-drop=ALL --security-opt=no-new-privileges \
    --env ENVIRONMENT=production --env CUSTOMER_ID=ci-test \
    --env DB_DRIVER=sqlite --env SQLITE_PATH=/migration/sqlite.db \
    --tmpfs /tmp:rw,nosuid,nodev,noexec,size=64m,mode=1777,uid=0,gid=0 \
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
  chmod 2777 "$root/migration" "$root/status"
  docker_prepare_volumes "$root/migration" "$root/status"
  printf '%s\n' "$root"
}

assert_completed_terminal() {
  local status_root=$1
  test -s "$status_root/status/status.json"
  test -s "$status_root/status/termination.json"
  test "$(stat -c '%a' "$status_root/status/status.json")" = 600
  test "$(stat -c '%a' "$status_root/status/termination.json")" = 600
  jq -e '.state == "completed"' "$status_root/status/status.json" >/dev/null
  jq -e '.state == "completed"' "$status_root/status/termination.json" >/dev/null
}

# The chart's automatic mode deliberately admits MongoDB/PostgreSQL only. The
# rendered shell programs are nevertheless exercised against an isolated real
# SQLite target here, which gives the gate a deterministic apply/verify store.
helm template hook "$chart_dir" "${base_values[@]}" > "$tmp/hook.yaml"
hook_root=$(new_volume_root)
extract_container "$tmp/hook.yaml" plan-before-drain "$tmp/hook-plan.script" "$tmp/hook-plan.args"
extract_container "$tmp/hook.yaml" apply "$tmp/hook-apply.script" "$tmp/hook-apply.args"
extract_container "$tmp/hook.yaml" verify "$tmp/hook-verify.script" "$tmp/hook-verify.args"
mapfile -t hook_plan_args < "$tmp/hook-plan.args"
mapfile -t hook_apply_args < "$tmp/hook-apply.args"
mapfile -t hook_verify_args < "$tmp/hook-verify.args"
hook_plan_output=$(docker_run "$hook_root/migration" "$hook_root/status" "$(<"$tmp/hook-plan.script")" "${hook_plan_args[@]}" 2>&1)
printf '%s\n' "$hook_plan_output" | tail -5
test -d "$hook_root/migration/artifacts"
test "$(stat -c '%a' "$hook_root/migration/artifacts")" = 700
test -s "$hook_root/migration/artifacts/plan.json"
test -s "$hook_root/migration/artifacts/result.json"
hook_decision=$(jq -er '.decision | select(. == "ordinary" or . == "maintenance")' "$hook_root/migration/artifacts/result.json")
hook_plan_digest=$(jq -er '.planDigest | select(test("^[a-f0-9]{64}$"))' "$hook_root/migration/artifacts/result.json")
printf '%s' "$hook_decision" > "$hook_root/migration/decision"
printf '%s' "$hook_plan_digest" > "$hook_root/migration/artifacts/plan-digest"
hook_apply_output=$(docker_run "$hook_root/migration" "$hook_root/status" "$(<"$tmp/hook-apply.script")" "${hook_apply_args[@]}" 2>&1)
printf '%s\n' "$hook_apply_output" | tail -10
assert_completed_terminal "$hook_root/status"
hook_verify_output=$(docker_run "$hook_root/migration" "$hook_root/status" "$(<"$tmp/hook-verify.script")" "${hook_verify_args[@]}" 2>&1)
printf '%s\n' "$hook_verify_output" | tail -5

# Operation plan/apply/verify uses the same real SQLite target and retains its
# caller-owned artifacts across three separately rendered Jobs.
plan_digest_placeholder=$(printf 'b%.0s' {1..64})
helm template operation "$chart_dir" "${base_values[@]}" \
  --set formatMigrations.mode=disabled \
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
plan_digest=$(jq -er '.planDigest | select(test("^[a-f0-9]{64}$"))' "$operation_root/migration/artifacts/primary-result.json")
test -s "$operation_root/migration/artifacts/primary-plan.json"
test -s "$operation_root/migration/artifacts/primary-result.json"
test "$(stat -c '%a' "$operation_root/migration/artifacts")" = 700

helm template operation "$chart_dir" "${base_values[@]}" \
  --set formatMigrations.mode=disabled \
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
operation_apply_output=$(docker_run "$operation_root/migration" "$operation_root/status" "$(<"$tmp/operation-apply.script")" "${operation_apply_args[@]}" 2>&1)
printf '%s\n' "$operation_apply_output" | tail -10
assert_completed_terminal "$operation_root/status"

helm template operation "$chart_dir" "${base_values[@]}" \
  --set formatMigrations.mode=disabled \
  --set migrationOperation.enabled=true \
  --set migrationOperation.phase=verify \
  --set migrationOperation.contractFingerprint="$fingerprint" \
  --set migrationOperation.operationId=ci-image-execution \
  --set migrationOperation.targetImage.repository=mnemoshare/mnemoshare \
  --set migrationOperation.targetImage.digest="$digest" \
  --set migrationOperation.transport.existingClaim=ci-migration \
  --set migrationOperation.planDigest="$plan_digest" \
  --set migrationOperation.verifiedPlanDigest="$plan_digest" > "$tmp/operation-verify.yaml"
extract_container "$tmp/operation-verify.yaml" migration-operation "$tmp/operation-verify.script" "$tmp/operation-verify.args"
mapfile -t operation_verify_args < "$tmp/operation-verify.args"
operation_verify_output=$(docker_run "$operation_root/migration" "$operation_root/status" "$(<"$tmp/operation-verify.script")" "${operation_verify_args[@]}" 2>&1)
printf '%s\n' "$operation_verify_output" | tail -5

echo 'migration Jobs executed in-image as uid 1000: hook plan/apply/verify and operation plan/apply/verify'
