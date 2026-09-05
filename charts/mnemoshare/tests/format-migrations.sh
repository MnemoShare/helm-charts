#!/usr/bin/env bash
set -euo pipefail

chart_dir=${1:-charts/mnemoshare}
base=(
  --set customerId=ci-test
  --set mongodb.external.enabled=true
  --set mongodb.external.uri=mongodb://test:test@localhost:27017/test
  --set s3.bucket=test-bucket
  --set s3.accessKey=test-key
  --set s3.secretKey=test-secret
  --set-string jwt.ecPrivateKey=test-ec-key
  --set encryption.key=test-encryption-key-exactly-32by
  --set license.key=test-license-key
  --set appUrl=https://test.example.com
  --set ingress.enabled=false
  --set autoscaling.enabled=true
  --set image.digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
)

render=$(helm template test "$chart_dir" "${base[@]}" \
  --set workflowWorker.enabled=true \
  --set workflowWorker.autoscaling.enabled=true \
  --set redis.external.enabled=true \
  --set redis.external.host=redis.example.com \
  --set ices.enabled=true \
  --set ices.autoscaling.enabled=true \
  --set ices.autoscaling.subscriptionName=projects/test/subscriptions/test \
  --set inboundGateway.enabled=true \
  --set emailGateway.enabled=true \
  --set sftpGateway.enabled=true \
  --set sftpGateway.hostKey.existingSecret=test-host-key \
  --set sftpGateway.image.repository=mnemoshare/mnemoshare \
  --set mcp.enabled=true \
  --set mcp.apiKey.key=mcp_test)

assert_has() {
  if ! grep -Fq -- "$1" <<<"$render"; then
    echo "missing expected format-migration rendering: $1" >&2
    exit 1
  fi
}

assert_has 'name: test-mnemoshare-format-migration'
if grep -Fq 'name: test-mnemoshare-format-migration-mode-fence' <<<"$render"; then
  echo 'automatic mode rendered the non-automatic state fence' >&2
  exit 1
fi
assert_has 'image: "docker.io/alpine/k8s@sha256:66dd3f7db6c4cf152b688d83aad11ceed9eb2da0c4e7de1034c7d4ccea1b55ef"'
private_pull_render=$(helm template test "$chart_dir" "${base[@]}" \
  --set imagePullSecrets[0].name=private-registry)
cleanup_job=$(awk '
  /^# Source: mnemoshare\/templates\/format-migration-cleanup.yaml$/ { source=1; next }
  source && /^kind: Job$/ { block=""; job=1 }
  job { block=block $0 "\n" }
  job && /^  name: test-mnemoshare-format-migration-cleanup$/ { cleanup=1 }
  /^---$/ && cleanup { print block; exit }
' <<<"$private_pull_render")
for fragment in 'activeDeadlineSeconds: 1800' 'imagePullSecrets:' 'name: private-registry'; do
  if ! grep -Fq "$fragment" <<<"$cleanup_job"; then
    echo "cleanup Job missing bounded private-registry support: ${fragment}" >&2
    exit 1
  fi
done
application_ref='mnemoshare/mnemoshare@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
if [ "$(grep -Fc "image: \"${application_ref}\"" <<<"$render")" -lt 10 ]; then
  echo 'not every enabled writer plus plan/apply/verify uses the exact application digest' >&2
  exit 1
fi
assert_image_in_source() {
  local manifest=$1 source=$2
  if ! awk -v source="$source" -v image="$application_ref" '
    /^# Source: / { active = ($0 ~ source "$"); next }
    active && index($0, "image: \"" image "\"") { found=1; exit }
    END { exit found ? 0 : 1 }
  ' <<<"$manifest"; then
    echo "exact automatic application digest missing from ${source}" >&2
    exit 1
  fi
}
for writer_source in \
  templates/deployment.yaml \
  templates/workflow-worker-deployment.yaml \
  templates/ices-deployment.yaml \
  templates/email-gateway-deployment.yaml \
  templates/inbound-gateway-deployment.yaml \
  templates/sftp-gateway-deployment.yaml \
  templates/mcp-deployment.yaml \
  templates/format-migration-job.yaml; do
  assert_image_in_source "$render" "$writer_source"
done
stateful_render=$(helm template test "$chart_dir" "${base[@]}" \
  --set workflowWorker.enabled=true \
  --set workflowWorker.persistence.enabled=true \
  --set redis.external.enabled=true \
  --set redis.external.host=redis.example.com)
assert_image_in_source "$stateful_render" 'templates/workflow-worker-statefulset.yaml'
assert_has 'command: ["/usr/local/bin/mnemoshare-migrate"]'
assert_has 'args: ["plan", "--contract", "embedded", "--result", "/migration/result.json", "--output", "/migration/plan.json"]'
assert_has 'verify --contract embedded --expect-plan-digest "$(cat /migration/plan-digest)"'
assert_has 'case "${decision}" in'
assert_has 'selected_pods="$(kubectl get pods -l "${selector}" -o name)"'
assert_has 'if [ -n "${selected_pods}" ]; then'
assert_has 'resource_name="$(kubectl get "$1" --ignore-not-found -o name)"'
assert_has 'keda_resources="$(kubectl api-resources --api-group=keda.sh -o name)"'
assert_has 'owner_patch='
for owned_support in \
  serviceaccount/test-mnemoshare-format-migration \
  role.rbac.authorization.k8s.io/test-mnemoshare-format-migration \
  rolebinding.rbac.authorization.k8s.io/test-mnemoshare-format-migration \
  networkpolicy.networking.k8s.io/test-mnemoshare-format-migration; do
  assert_has "attach_owner_if_present ${owned_support}"
done
if grep -Fq 'attach_owner_if_present secret/' <<<"$render"; then
  echo 'credential snapshot must not be owned by the asynchronously deleted migration Job' >&2
  exit 1
fi
assert_has 'kubectl delete secrets,configmaps,jobs,serviceaccounts,roles.rbac.authorization.k8s.io,rolebindings.rbac.authorization.k8s.io,networkpolicies.networking.k8s.io \'

for image_override in \
  workflowWorker.image.tag=old \
  ices.image.digest=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  sftpGateway.image.digest=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  mcp.image.tag=old \
  mcp.image.digest=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb; do
  if helm template test "$chart_dir" "${base[@]}" \
      --set workflowWorker.enabled=true --set redis.external.enabled=true --set redis.external.host=redis.example.com \
      --set ices.enabled=true \
      --set sftpGateway.enabled=true --set sftpGateway.hostKey.existingSecret=test-host-key \
      --set sftpGateway.image.repository=mnemoshare/mnemoshare \
      --set mcp.enabled=true --set mcp.apiKey.key=mcp_test \
      --set "$image_override" >/dev/null 2>&1; then
    echo "automatic migration accepted a divergent writer tag/digest: ${image_override}" >&2
    exit 1
  fi
done

tag_render=$(helm template test "$chart_dir" "${base[@]}" \
  --set formatMigrations.mode=operator \
  --set image.tag=compat-tag \
  --set image.digest=)
if ! grep -Fq 'image: "mnemoshare/mnemoshare:compat-tag"' <<<"$tag_render"; then
  echo 'operator mode did not preserve historical tag image rendering' >&2
  exit 1
fi

if helm template test "$chart_dir" "${base[@]}" --set image.digest= >/dev/null 2>&1; then
  echo 'automatic migration accepted a missing global application digest' >&2
  exit 1
fi
if helm template test "$chart_dir" "${base[@]}" --set image.digest=sha256:ABC >/dev/null 2>&1; then
  echo 'automatic migration accepted an invalid global application digest' >&2
  exit 1
fi

for image_override in \
  workflowWorker.image.repository=example/old-writer \
  ices.image.repository=example/old-writer \
  sftpGateway.image.repository=example/old-writer \
  mcp.image.repository=example/old-writer; do
  if helm template test "$chart_dir" "${base[@]}" \
      --set workflowWorker.enabled=true --set redis.external.enabled=true --set redis.external.host=redis.example.com \
      --set ices.enabled=true \
      --set sftpGateway.enabled=true --set sftpGateway.hostKey.existingSecret=test-host-key \
      --set sftpGateway.image.repository=mnemoshare/mnemoshare \
      --set mcp.enabled=true --set mcp.apiKey.key=mcp_test \
      --set "$image_override" >/dev/null 2>&1; then
    echo "automatic migration accepted a distinct writer image: ${image_override}" >&2
    exit 1
  fi
done

if helm template test "$chart_dir" "${base[@]}" --set networkPolicy.enabled=true >/dev/null 2>&1; then
  echo 'network policy accepted missing restricted DB/API destinations' >&2
  exit 1
fi
np_render=$(helm template test "$chart_dir" "${base[@]}" \
  --set networkPolicy.enabled=true \
  --set formatMigrations.networkPolicy.databaseCIDRs[0]=10.20.30.40/32 \
  --set formatMigrations.networkPolicy.kubernetesApiTargets[0].cidr=10.96.0.1/32 \
  --set formatMigrations.networkPolicy.kubernetesApiTargets[0].port=443)
for fragment in \
  'name: test-mnemoshare-format-migration' \
  'name: test-mnemoshare-format-migration-cleanup' \
  'cidr: "10.20.30.40/32"' \
  'cidr: "10.96.0.1/32"' \
  'port: 27017' \
  'k8s-app: kube-dns' \
  'app.kubernetes.io/name: mnemoshare'; do
  if ! grep -Fq "$fragment" <<<"$np_render"; then
    echo "migration NetworkPolicy missing: ${fragment}" >&2
    exit 1
  fi
done
cleanup_policy=$(awk '
  /^kind: NetworkPolicy$/ { block=""; active=1; cleanup=0 }
  active { block=block $0 "\n" }
  active && /^  name: test-mnemoshare-format-migration-cleanup$/ { cleanup=1 }
  /^---$/ && cleanup { print block; exit }
' <<<"$np_render")
if grep -Fq '10.20.30.40/32' <<<"$cleanup_policy"; then
  echo 'cleanup NetworkPolicy unexpectedly permits database egress' >&2
  exit 1
fi
postgres_np=$(helm template test "$chart_dir" "${base[@]}" \
  --set database.driver=postgres --set postgres.dsn=postgres://test \
  --set networkPolicy.enabled=true \
  --set formatMigrations.networkPolicy.databaseCIDRs[0]=10.20.30.40/32 \
  --set formatMigrations.networkPolicy.kubernetesApiTargets[0].cidr=10.96.0.1/32 \
  --set formatMigrations.networkPolicy.kubernetesApiTargets[0].port=443)
if ! grep -Fq 'port: 5432' <<<"$postgres_np"; then
  echo 'PostgreSQL migration NetworkPolicy did not default to port 5432' >&2
  exit 1
fi
custom_port_np=$(helm template test "$chart_dir" "${base[@]}" \
  --set networkPolicy.enabled=true \
  --set formatMigrations.networkPolicy.databaseCIDRs[0]=10.20.30.40/32 \
  --set formatMigrations.networkPolicy.databasePort=27018 \
  --set formatMigrations.networkPolicy.kubernetesApiTargets[0].cidr=10.96.0.1/32 \
  --set formatMigrations.networkPolicy.kubernetesApiTargets[0].port=6443)
for custom_fragment in 'port: 27018' 'port: 6443'; do
  if ! grep -Fq "$custom_fragment" <<<"$custom_port_np"; then
    echo "custom migration NetworkPolicy target missing: ${custom_fragment}" >&2
    exit 1
  fi
done
assert_has '(.planDigest | test("^[a-f0-9]{64}$"))'

decision_is_valid_value() {
  local candidate=$1
  printf %s ordinary | cmp -s - <(printf %s "$candidate") ||
    printf 'ordinary\n' | cmp -s - <(printf %s "$candidate") ||
    printf %s maintenance | cmp -s - <(printf %s "$candidate") ||
    printf 'maintenance\n' | cmp -s - <(printf %s "$candidate")
}
for valid in ordinary maintenance; do
  decision_is_valid_value "$valid"
  decision_is_valid_value "${valid}"$'\n'
done
if decision_is_valid_value $'ordinary\nunterminated'; then
  echo 'decision parser accepted a second unterminated line' >&2
  exit 1
fi
assert_has 'exec /usr/local/bin/mnemoshare-migrate apply \'
assert_has '--contract embedded --expect-plan-digest "$(cat /migration/plan-digest)" --exclusive'
assert_has '"helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded'
if [ "$(grep -Ec '^[[:space:]]+"helm.sh/hook-delete-policy": before-hook-creation$' <<<"$render")" -lt 7 ]; then
  echo 'support hooks do not all use deterministic next-attempt cleanup' >&2
  exit 1
fi
if [ "$(grep -Fc '"helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded' <<<"$render")" -ne 2 ]; then
  echo 'migration and stale-resource cleanup Jobs must delete after success' >&2
  exit 1
fi
assert_has '"helm.sh/hook": post-install,post-upgrade,pre-delete'
assert_has 'kubectl delete secrets,configmaps,jobs,serviceaccounts,roles.rbac.authorization.k8s.io,rolebindings.rbac.authorization.k8s.io,networkpolicies.networking.k8s.io \'
assert_has "jsonpath='{.spec.scaleTargetRef.name}'"
if grep -Fq "kubectl delete hpa -l 'app.kubernetes.io/instance=" <<<"$render"; then
  echo 'migration drain must not delete non-API HPAs by the release-wide label' >&2
  exit 1
fi
assert_has 'mnemoshare.io/database-writer=true'
assert_has 'kubectl create configmap "${state_name}" \'
assert_has 'kubectl scale "${resource}" --replicas=0'
if grep -Fq 'kubectl scale "${resource}" --replicas="${replicas}"' <<<"$render"; then
  echo 'governed migration must never restore the old replica fence' >&2
  exit 1
fi
assert_has 'if [ "${stored_decision}" = maintenance ]; then'
assert_has '.immutable == true and'
assert_has '(.data | keys | sort) == ["decision","desired-replicas","operation","plan-digest","snapshot-sha256"]'
assert_has 'maintenance requires a nonempty exact prior writer census'
assert_has '.data.operation == $operation or'
assert_has '.data.operation == "install" and $operation == "upgrade" and'
assert_has '.data.decision == "ordinary" and $decision == "ordinary"'
assert_has 'writer snapshot content mismatch'
assert_has 'operation=install'
assert_has 'name: fence-active-migration-state'
assert_has 'retained migration state ${state} fences target ${expected}'
assert_has 'app.kubernetes.io/component=format-migration-state'
upgrade_render=$(helm template test "$chart_dir" "${base[@]}" --is-upgrade)
if ! grep -Fq 'operation=upgrade' <<<"$upgrade_render"; then
  echo 'upgrade retry state is not distinguished from pre-install state' >&2
  exit 1
fi
assert_has 'app.kubernetes.io/component=format-migration-state'

override_render=$(helm template test "$chart_dir" "${base[@]}" \
  --set fullnameOverride=renamed-mnemoshare)
if ! grep -Fq 'mnemoshare.io/database-writer=true' <<<"$override_render"; then
  echo 'fullname transition lost label-based old-controller discovery' >&2
  exit 1
fi
if grep -Fq 'kubectl scale deployment/renamed-mnemoshare' <<<"$override_render"; then
  echo 'fullname transition drain still relies on a constructed controller name' >&2
  exit 1
fi
assert_has 'mnemoshare.io/format-migration-target:'
assert_has '"helm.sh/hook-weight": "-45"'
assert_has 'mongodb-uri: "mongodb://test:test@localhost:27017/test"'

external_render=$(helm template test "$chart_dir" "${base[@]}" \
  --set existingSecrets.mongodb=target-db-secret)
if grep -Fq 'kind: Secret' <<<"$(awk '
  /# Source: mnemoshare\/templates\/format-migration-target-config.yaml/ { active=1; next }
  /^---$/ && active { exit }
  active { print }
' <<<"$external_render")"; then
  echo 'target DB snapshot rendered despite an external Secret reference' >&2
  exit 1
fi
if ! grep -Fq 'name: snapshot-target-credentials' <<<"$external_render" || ! grep -Fq 'source="target-db-secret"' <<<"$external_render"; then
  echo 'migration hook did not snapshot the target external Secret' >&2
  exit 1
fi
for snapshot_guard in \
  'credential snapshot identity mismatch' \
  '.metadata.annotations["mnemoshare.io/format-migration-credential-source"] == $source' \
  '(.data | keys) == [$key]'; do
  if ! grep -Fq "$snapshot_guard" <<<"$external_render"; then
    echo "external credential snapshot lacks tamper guard: ${snapshot_guard}" >&2
    exit 1
  fi
done

# A stale existingSecret for the inactive driver must never trigger snapshot
# creation or substitute an empty source. Driver selection is symmetric.
mongo_stale_postgres=$(helm template test "$chart_dir" "${base[@]}" \
  --set existingSecrets.postgres=stale-postgres)
if grep -Fq 'name: snapshot-target-credentials' <<<"$mongo_stale_postgres"; then
  echo 'MongoDB mode incorrectly activated the PostgreSQL credential snapshot' >&2
  exit 1
fi
postgres_stale_mongo=$(helm template test "$chart_dir" "${base[@]}" \
  --set database.driver=postgres \
  --set postgres.dsn=postgres://target:test@postgres.example.com/mnemoshare \
  --set existingSecrets.mongodb=stale-mongo)
if grep -Fq 'name: snapshot-target-credentials' <<<"$postgres_stale_mongo"; then
  echo 'PostgreSQL mode incorrectly activated the MongoDB credential snapshot' >&2
  exit 1
fi
postgres_external=$(helm template test "$chart_dir" "${base[@]}" \
  --set database.driver=postgres \
  --set postgres.dsn=postgres://target:test@postgres.example.com/mnemoshare \
  --set existingSecrets.postgres=target-postgres)
if ! grep -Fq 'source="target-postgres"' <<<"$postgres_external"; then
  echo 'PostgreSQL active external credential was not snapshotted' >&2
  exit 1
fi

postgres_render=$(helm template test "$chart_dir" "${base[@]}" \
  --set database.driver=postgres \
  --set postgres.dsn=postgres://target:test@postgres.example.com/mnemoshare)
if ! grep -Fq 'postgres-dsn: "postgres://target:test@postgres.example.com/mnemoshare"' <<<"$postgres_render"; then
  echo 'PostgreSQL target DB snapshot did not use target values' >&2
  exit 1
fi

if grep -Eq '(kubectl scale|scale_if_present) .*-(redis|clamav|step-ca|minio)' <<<"$render"; then
  echo 'infrastructure workload unexpectedly included in drain' >&2
  exit 1
fi

for mode in operator disabled; do
  without_hook=$(helm template test "$chart_dir" "${base[@]}" --set formatMigrations.mode="$mode")
  if grep -Eq '^  name: test-mnemoshare-format-migration$' <<<"$without_hook"; then
    echo "main format migration hook rendered in ${mode} mode" >&2
    exit 1
  fi
  if ! grep -Fq '"helm.sh/hook": pre-delete' <<<"$without_hook"; then
    echo "retained-hook cleanup path missing in ${mode} mode" >&2
    exit 1
  fi
  for fence_fragment in \
    'name: test-mnemoshare-format-migration-mode-fence' \
    '"helm.sh/hook": pre-upgrade' \
    'app.kubernetes.io/component=format-migration-state' \
    "unresolved automatic migration state fences formatMigrations.mode=${mode}" \
    'explicit operator-owned state handoff'; do
    if ! grep -Fq "$fence_fragment" <<<"$without_hook"; then
      echo "retained-state mode fence missing in ${mode}: ${fence_fragment}" >&2
      exit 1
    fi
  done
done

for safety_doc in charts/mnemoshare/README.md charts/mnemoshare/templates/NOTES.txt; do
  if ! grep -Fq 'helm upgrade --atomic' "$safety_doc"; then
    echo "automatic rollback prohibition missing from ${safety_doc}" >&2
    exit 1
  fi
done

if helm template test "$chart_dir" "${base[@]}" --set formatMigrations.mode=invalid >/dev/null 2>&1; then
  echo 'schema accepted an invalid formatMigrations.mode' >&2
  exit 1
fi

if helm template test "$chart_dir" "${base[@]}" --set database.driver=sqlite >/dev/null 2>&1; then
  echo 'automatic format migration unexpectedly accepted isolated SQLite' >&2
  exit 1
fi
helm template test "$chart_dir" "${base[@]}" \
  --set database.driver=sqlite \
  --set formatMigrations.mode=operator >/dev/null

for unsupported_driver in db2 unknown; do
  if helm template test "$chart_dir" "${base[@]}" \
      --set database.driver="$unsupported_driver" >/dev/null 2>&1; then
    echo "automatic format migration accepted unsupported driver: ${unsupported_driver}" >&2
    exit 1
  fi
done

# Default and partial topologies render the same guarded wait loop: absent
# component pods must skip kubectl wait instead of turning no matches into a
# failed upgrade.
for topology_args in '' '--set mcp.enabled=true --set mcp.apiKey.key=mcp_test'; do
  # shellcheck disable=SC2206
  topology_extra=($topology_args)
  topology_render=$(helm template test "$chart_dir" "${base[@]}" "${topology_extra[@]}")
  if ! grep -Fq 'if [ -n "${selected_pods}" ]; then' <<<"$topology_render"; then
    echo 'default/partial topology rendered an unguarded pod wait' >&2
    exit 1
  fi
done

scheduling_render=$(helm template test "$chart_dir" "${base[@]}" \
  --set dnsConfig.searches[0]=corp.example \
  --set nodeSelector.migrations=allowed \
  --set tolerations[0].key=dedicated \
  --set tolerations[0].operator=Exists \
  --set affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].key=migrations \
  --set affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].operator=Exists)
for scheduling_fragment in 'corp.example' 'migrations: allowed' 'key: dedicated' 'nodeAffinity:'; do
  if ! grep -Fq "$scheduling_fragment" <<<"$scheduling_render"; then
    echo "migration Job did not inherit scheduling fragment: ${scheduling_fragment}" >&2
    exit 1
  fi
done

echo 'format migration render tests passed'
