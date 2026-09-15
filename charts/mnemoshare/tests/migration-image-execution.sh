#!/usr/bin/env bash
set -Eeuo pipefail
# Command substitutions inherit errexit, and the ERR trap names the failing
# command, its line and its call stack: a provisioning or assertion failure
# fails here, at its own line, instead of being swallowed and surfacing later
# inside a container.
shopt -s inherit_errexit
on_error() {
  local rc=$? i stack=""
  for ((i = 1; i < ${#FUNCNAME[@]}; i++)); do
    stack+="${stack:+ < }${FUNCNAME[i]}:${BASH_LINENO[i - 1]}"
  done
  echo "${BASH_SOURCE[0]##*/}: line ${BASH_LINENO[0]}: $BASH_COMMAND failed (rc $rc; $stack)" >&2
}
trap on_error ERR

# This is deliberately an execution test, not a rendered-token test. The
# caller supplies an image built from the exact application checkout selected
# by CI; the rendered shell argv is then run by that image as uid 1000.
#
# The runner uid is not assumed to be 1000 or root (a CI runner is neither).
# It only renders, extracts, and starts containers; every read, write and
# removal inside a volume tree happens inside the image as uid 1000 or root,
# because after normalization the mount roots are root-owned setgid and their
# content is uid-1000 0700/0600, which no other uid can reach.
image=${MIGRATION_IMAGE:?MIGRATION_IMAGE must name the application image to execute}
chart_dir=${1:-charts/mnemoshare}
contract_dir="$chart_dir/tests/contracts/migration-operation/v1"
fingerprint=$(jq -er '.fingerprint | select(test("^[a-f0-9]{64}$"))' "$contract_dir/contract.json")
digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
tmp=$(mktemp -d)

cleanup() {
  local rc=$?
  trap - ERR
  set +e
  # The volume trees can only be removed by root; a leaked tree fails the gate.
  if compgen -G "$tmp/volume.*" >/dev/null; then
    docker run --rm --user 0:0 --read-only -v "$tmp:/cleanup" \
      --entrypoint /bin/sh "$image" -ec 'rm -rf /cleanup/volume.*' \
      || { echo "volume trees under $tmp were not removed" >&2; [ "$rc" -ne 0 ] || rc=1; }
  fi
  rm -rf "$tmp" || { echo "$tmp was not removed" >&2; [ "$rc" -ne 0 ] || rc=1; }
  exit "$rc"
}
trap cleanup EXIT

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
  local manifest=$1 container=$2 script_out=$3 args_out=$4 message_out=$5
  python3 - "$manifest" "$container" "$script_out" "$args_out" "$message_out" <<'PY'
import base64
import sys
import yaml

manifest, wanted, script_out, args_out, message_out = sys.argv[1:]
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
        message_path = container.get("terminationMessagePath", "")
        if not isinstance(message_path, str) or "\n" in message_path:
            raise SystemExit(f"{wanted}: terminationMessagePath is not a single-line string")
        with open(message_out, "w", encoding="utf-8") as out:
            out.write(message_path)
        raise SystemExit(0)
raise SystemExit(f"{wanted}: rendered container not found")
PY
}

# Runs a shell program inside the image as uid 1000 with a volume tree mounted
# at its rendered paths. Every assertion, read and stand-in write against a
# volume tree goes through here, as the Job's own principal would see it.
in_volume() {
  local root=$1 script=$2
  shift 2
  docker run --rm --read-only --user 1000:1000 \
    --cap-drop=ALL --security-opt=no-new-privileges \
    -v "$root/migration:/migration" -v "$root/status:/run/mnemoshare-migration" \
    --entrypoint /bin/sh "$image" -ec "$script" in_volume "$@"
}

volume_test() {
  local root=$1
  shift
  in_volume "$root" 'test "$@" || { echo "assertion failed as uid 1000: test $*" >&2; exit 1; }' "$@"
}

volume_stat() {
  local root=$1 path=$2 format=$3 expected=$4
  in_volume "$root" 'actual=$(stat -c "$2" "$1"); [ "$actual" = "$3" ] || { echo "$1: stat $2 is $actual, expected $3" >&2; exit 1; }' \
    "$path" "$format" "$expected"
}

volume_cat() {
  in_volume "$1" 'cat "$1"' "$2"
}

volume_write() {
  in_volume "$1" 'printf %s "$2" > "$1"' "$2" "$3"
}

docker_prepare_volumes() {
  local root=$1
  # Host-created bind mounts are deliberately normalized by a root helper so
  # the actual migration scripts exercise the same root-owned, setgid volume
  # boundary as kubelet-provisioned emptyDirs while still running as uid 1000.
  # The status emptyDir is exactly what kubelet provisions with fsGroup 1000:
  # root-owned, group 1000, setgid 2777.
  docker run --rm --user 0:0 --read-only \
    -v "$root:/volume" --entrypoint /bin/sh "$image" -ec \
    'chown 0:1000 /volume/migration /volume/status && chmod 2770 /volume/migration && chmod 2777 /volume/status
     mkdir /volume/kubelet && chmod 0755 /volume/kubelet'
  volume_stat "$root" /migration %u:%g:%a 0:1000:2770
  volume_stat "$root" /run/mnemoshare-migration %u:%g:%a 0:1000:2777
}

# Emulates kubelet's terminationMessagePath handling for one container: before
# the container starts, kubelet creates a root-owned 0666 regular file outside
# every volume and bind-mounts it at the declared path. The runtime creates
# whatever mount point (and missing parent directories) that bind needs, as
# root, inside the mounted volume. Prints the host file to hand to docker_run.
kubelet_termination_message() {
  local root=$1 name=$2
  docker run --rm --user 0:0 --read-only -v "$root/kubelet:/kubelet" \
    --entrypoint /bin/sh "$image" -ec ': > "/kubelet/$1" && chown 0:0 "/kubelet/$1" && chmod 0666 "/kubelet/$1"' \
    kubelet "$name"
  [ "$(stat -c %u:%g:%a:%F "$root/kubelet/$name")" = "0:0:666:regular empty file" ] \
    || { echo "kubelet termination message stand-in $root/kubelet/$name is not a root-owned 0666 regular file" >&2; return 1; }
  printf '%s\n' "$root/kubelet/$name"
}

# The rendered Job containers mount only /migration and the status directory
# on a read-only root filesystem; the gate grants nothing more (no /tmp). The
# SQLite target lives in the caller-owned 0700 artifact directory the rendered
# scripts create before exec, the directory the job contract already requires.
docker_run() {
  local volume_root=$1 status_root=$2 message_mount=$3 script=$4
  local timeout_seconds=${DOCKER_RUN_TIMEOUT:-}
  shift 4
  local -a mounts=(-v "$volume_root:/migration" -v "$status_root:/run/mnemoshare-migration")
  if [ -n "$message_mount" ]; then
    mounts+=(-v "$message_mount")
  fi
  local -a command=(docker run --rm --read-only --user 1000:1000 \
    --cap-drop=ALL --security-opt=no-new-privileges \
    --env ENVIRONMENT=production --env CUSTOMER_ID=ci-test \
    --env DB_DRIVER=sqlite --env SQLITE_PATH=/migration/artifacts/sqlite.db \
    "${mounts[@]}" \
    --entrypoint /bin/sh "$image" -ec "$script" "$@")
  if [ -n "$timeout_seconds" ]; then
    timeout "$timeout_seconds" "${command[@]}"
  else
    "${command[@]}"
  fi
}

# Executes one rendered container, keeps its whole output in $tmp, prints the
# last lines on success and everything on failure. A container that declares
# terminationMessagePath gets kubelet's bind-mounted message file.
execute_rendered() {
  local name=$1 tail_lines=$2 root=$3 message_path message_mount=""
  shift 3
  message_path=$(<"$tmp/$name.message-path")
  if [ -n "$message_path" ]; then
    message_mount="$(kubelet_termination_message "$root" "$name"):$message_path"
  fi
  if ! docker_run "$root/migration" "$root/status" "$message_mount" "$(<"$tmp/$name.script")" "$@" > "$tmp/$name.log" 2>&1; then
    cat "$tmp/$name.log" >&2
    echo "rendered $name container failed" >&2
    return 1
  fi
  tail -n "$tail_lines" "$tmp/$name.log"
}

new_volume_root() {
  local -n new_root=$1
  new_root=$(mktemp -d "$tmp/volume.XXXXXX")
  mkdir -p "$new_root/migration" "$new_root/status"
  chmod 2770 "$new_root/migration" "$new_root/status"
  docker_prepare_volumes "$new_root"
}

# The caller-owned status directory holds the durable 0600 records, and
# kubelet's own file (still the same root-owned 0666 inode) holds exactly the
# durable terminal bytes, written in place by the binary.
assert_completed_terminal() {
  local root=$1 name=$2 file message_path
  volume_stat "$root" /run/mnemoshare-migration/status %u:%a 1000:700
  for file in status.json termination.json; do
    volume_test "$root" -s "/run/mnemoshare-migration/status/$file"
    volume_stat "$root" "/run/mnemoshare-migration/status/$file" %u:%a:%h:%F 1000:600:1:regular\ file
    volume_cat "$root" "/run/mnemoshare-migration/status/$file" | jq -e '.state == "completed"' >/dev/null
  done
  message_path=$(<"$tmp/$name.message-path")
  [ -n "$message_path" ] || { echo "$name: rendered container declares no terminationMessagePath" >&2; return 1; }
  [ "$(stat -c %u:%g:%a:%F "$root/kubelet/$name")" = "0:0:666:regular file" ] \
    || { echo "$name: kubelet termination message file was replaced or re-permissioned: $(stat -c %u:%g:%a:%F "$root/kubelet/$name")" >&2; return 1; }
  if ! cmp <(volume_cat "$root" /run/mnemoshare-migration/status/termination.json) "$root/kubelet/$name"; then
    echo "$name: kubelet termination message ($message_path) does not hold the durable terminal bytes" >&2
    return 1
  fi
  jq -e '.state == "completed"' "$root/kubelet/$name" >/dev/null
  echo "$name: kubelet termination message $message_path holds the durable completed terminal in place"
}

# The chart's automatic mode deliberately admits MongoDB/PostgreSQL only. The
# rendered shell programs are nevertheless exercised against an isolated real
# SQLite target here, which gives the gate a deterministic apply/verify store.
helm template hook "$chart_dir" "${base_values[@]}" > "$tmp/hook.yaml"
new_volume_root hook_root
extract_container "$tmp/hook.yaml" plan-before-drain "$tmp/hook-plan.script" "$tmp/hook-plan.args" "$tmp/hook-plan.message-path"
extract_container "$tmp/hook.yaml" apply "$tmp/hook-apply.script" "$tmp/hook-apply.args" "$tmp/hook-apply.message-path"
extract_container "$tmp/hook.yaml" verify "$tmp/hook-verify.script" "$tmp/hook-verify.args" "$tmp/hook-verify.message-path"
mapfile -t hook_plan_args < "$tmp/hook-plan.args"
mapfile -t hook_apply_args < "$tmp/hook-apply.args"
mapfile -t hook_verify_args < "$tmp/hook-verify.args"
execute_rendered hook-plan 5 "$hook_root" "${hook_plan_args[@]}"
volume_test "$hook_root" -d /migration/artifacts
volume_stat "$hook_root" /migration/artifacts %a 700
volume_test "$hook_root" -s /migration/artifacts/plan.json
volume_test "$hook_root" -s /migration/artifacts/result.json
hook_decision=$(volume_cat "$hook_root" /migration/artifacts/result.json | jq -er '.decision | select(. == "ordinary" or . == "maintenance")')
hook_plan_digest=$(volume_cat "$hook_root" /migration/artifacts/result.json | jq -er '.planDigest | select(test("^[a-f0-9]{64}$"))')
# Stand-in for the drain-application-plane container, which records the plan
# decision and digest for apply as uid 1000 and needs kubectl otherwise.
volume_write "$hook_root" /migration/decision "$hook_decision"
volume_write "$hook_root" /migration/artifacts/plan-digest "$hook_plan_digest"
execute_rendered hook-apply 10 "$hook_root" "${hook_apply_args[@]}"
assert_completed_terminal "$hook_root" hook-apply
execute_rendered hook-verify 5 "$hook_root" "${hook_verify_args[@]}"

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
new_volume_root operation_root
extract_container "$tmp/operation-plan.yaml" migration-operation "$tmp/operation-plan.script" "$tmp/operation-plan.args" "$tmp/operation-plan.message-path"
mapfile -t operation_plan_args < "$tmp/operation-plan.args"
execute_rendered operation-plan 5 "$operation_root" "${operation_plan_args[@]}"
plan_digest=$(volume_cat "$operation_root" /migration/artifacts/primary-result.json | jq -er '.planDigest | select(test("^[a-f0-9]{64}$"))')
volume_test "$operation_root" -s /migration/artifacts/primary-plan.json
volume_test "$operation_root" -s /migration/artifacts/primary-result.json
volume_stat "$operation_root" /migration/artifacts %a 700

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
extract_container "$tmp/operation-apply.yaml" migration-operation "$tmp/operation-apply.script" "$tmp/operation-apply.args" "$tmp/operation-apply.message-path"
mapfile -t operation_apply_args < "$tmp/operation-apply.args"
execute_rendered operation-apply 10 "$operation_root" "${operation_apply_args[@]}"
assert_completed_terminal "$operation_root" operation-apply

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
extract_container "$tmp/operation-verify.yaml" migration-operation "$tmp/operation-verify.script" "$tmp/operation-verify.args" "$tmp/operation-verify.message-path"
mapfile -t operation_verify_args < "$tmp/operation-verify.args"
execute_rendered operation-verify 5 "$operation_root" "${operation_verify_args[@]}"

echo 'migration Jobs executed in-image as uid 1000: hook plan/apply/verify and operation plan/apply/verify'
