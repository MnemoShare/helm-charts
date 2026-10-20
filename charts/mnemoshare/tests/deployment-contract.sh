#!/usr/bin/env bash
set -euo pipefail

chart_dir=${1:-$(cd "$(dirname "$0")/.." && pwd)}
contract_dir=$(cd "$(dirname "$0")" && pwd)/contracts/deployment/v1
upstream=$(sed -n 's/^commit=//p' "${contract_dir}/UPSTREAM")
fingerprint=$(jq -er .fingerprint "${contract_dir}/contract.json")
digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
identity=(--set "deploymentContract.sourceCommit=${upstream}" --set "deploymentContract.contractFingerprint=${fingerprint}" --set "deploymentContract.imageDigest=${digest}" --set "image.digest=${digest}")
(cd "$contract_dir" && sha256sum -c SHA256SUMS)
test "$(sed -n 's/^commit=//p' "${contract_dir}/UPSTREAM")" = "$upstream"
test "$(sed -n 's/^path=//p' "${contract_dir}/UPSTREAM")" = contracts/deployment/v1
test "$(sed -n 's/^sha256sums=//p' "${contract_dir}/UPSTREAM")" = "$(sha256sum "${contract_dir}/SHA256SUMS" | cut -d' ' -f1)"
jq -e '.provenance.schema == "mnemoshare.deployment-contract.v1" and (.executables | map(select(.id == "mcp-admin" and .path == "/usr/local/bin/mcp-admin" and .default_profile == "default" and (.profiles | any(.id == "default" and .persistence == "none" and .args == ["--transport=http","--http-addr=:9222","--log-level=info","--log-format=json"] and .probe.port == 9222)))) | length == 1) and (.executables | map(select(.id == "sftp-gateway" and .path == "/usr/local/bin/sftp-gateway" and .default_profile == "default" and (.profiles | any(.id == "default" and .persistence == "none" and .probe.path == "/readyz" and .probe.port == 8090 and .liveness_probe.path == "/healthz")))) | length == 1)' "${contract_dir}/contract.json" >/dev/null

render=$(helm template contract "$chart_dir" --set customerId=test "${identity[@]}" --set sftpGateway.enabled=true --set sftpGateway.hostKey.existingSecret=host-key --set encryption.key=test --set sftpGateway.licenseCapabilityEnabled=true --set mcp.enabled=true --set mcp.apiKey.key=mcp_test)
source_manifest() {
  awk -v source="# Source: mnemoshare/templates/$1" '$0 == source { active=1; next } active && /^---$/ { exit } active { print }' <<<"$render"
}
mcp_render=$(source_manifest mcp-deployment.yaml)
sftp_render=$(source_manifest sftp-gateway-deployment.yaml)
migration_render=$(source_manifest format-migration-job.yaml)
test -n "$mcp_render" && test -n "$sftp_render" && test -n "$migration_render"
for absent in 'mnemoshare.io/database-writer: "true"' 'SFTP_GATEWAY_HEALTH_PORT'; do
  if grep -Fq "$absent" <<<"${mcp_render}${sftp_render}"; then echo "none process retained $absent" >&2; exit 1; fi
done
grep -Fq 'command: ["/usr/local/bin/mcp-admin"]' <<<"$mcp_render"
grep -Fq -- '- --transport=http' <<<"$mcp_render"
grep -Fq -- '- --http-addr=:9222' <<<"$mcp_render"
grep -Fq -- '- --log-level=info' <<<"$mcp_render"
grep -Fq -- '- --log-format=json' <<<"$mcp_render"
grep -Fq 'containerPort: 9222' <<<"$mcp_render"
grep -Fq 'path: /health' <<<"$mcp_render"
grep -Fq 'command: ["/usr/local/bin/sftp-gateway"]' <<<"$sftp_render"
grep -Fq 'containerPort: 8090' <<<"$sftp_render"
grep -Fq 'path: /readyz' <<<"$sftp_render"
grep -Fq 'path: /healthz' <<<"$sftp_render"
grep -Fq 'sftp-gateway|mcp) continue' <<<"$migration_render"
grep -Fq "app.kubernetes.io/component in (api,workflow-worker,ices,inbound-gateway,email-gateway)'" <<<"$migration_render"
grep -Fq "app.kubernetes.io/component in (email-gateway,sftp-gateway,mcp)'" <<<"$migration_render"
grep -Fq 'for resource in ${peer_controllers}; do' <<<"$migration_render"
grep -Fq 'for component in api workflow-worker ices inbound-gateway email-gateway sftp-gateway mcp; do' <<<"$migration_render"
grep -Fq ': > /migration/writer-replicas' <<<"$migration_render"
grep -Fq "email-gateway) printf '%s=%s" <<<"$migration_render"
grep -Fq 'sftp-gateway|mcp) ;; # legacy v1.25.11 state' <<<"$migration_render"
grep -Fq 'mv /migration/writer-replicas /migration/desired-replicas' <<<"$migration_render"

port_render=$(helm template port "$chart_dir" --set customerId=test "${identity[@]}" --set mcp.enabled=true --set mcp.apiKey.key=x --set mcp.service.port=8443)
grep -Fq 'port: 8443' <<<"$port_render"
grep -Fq 'containerPort: 9222' <<<"$port_render"

operator_render=$(helm template immutable "$chart_dir" --set customerId=test "${identity[@]}" --set formatMigrations.mode=operator --set image.tag=old-tag --set mcp.enabled=true --set mcp.apiKey.key=x --set sftpGateway.enabled=true --set sftpGateway.hostKey.existingSecret=x --set encryption.key=x --set sftpGateway.licenseCapabilityEnabled=true)
test "$(grep -Fc "image: \"mnemoshare/mnemoshare@${digest}\"" <<<"$operator_render")" -eq 2

expect_failure() {
  local override=$1 expected=$2 output
  if output=$(helm template bad "$chart_dir" --set customerId=test "${identity[@]}" --set mcp.enabled=true --set mcp.apiKey.key=x --set sftpGateway.enabled=true --set sftpGateway.hostKey.existingSecret=x --set encryption.key=x --set sftpGateway.licenseCapabilityEnabled=true --set "$override" 2>&1); then
    echo "legacy override rendered: $override" >&2; exit 1
  fi
  grep -Fq "$expected" <<<"$output" || { echo "override $override lacked migration error: $expected" >&2; exit 1; }
}
expect_failure 'mcp.transport.type=stdio' 'mcp.transport.type is fixed to http'
expect_failure 'mcp.transport.http.containerPort=9999' 'mcp.transport.http.containerPort is fixed to 9222'
expect_failure 'mcp.logging.level=debug' 'mcp.logging.level is fixed to info'
expect_failure 'mcp.logging.format=console' 'mcp.logging.format is fixed to json'
expect_failure 'sftpGateway.image.repository=legacy/image' 'sftpGateway.image.repository is retired'
expect_failure 'sftpGateway.command[0]=legacy' 'sftpGateway.command is fixed'
expect_failure 'mcp.image.tag=legacy' 'mcp.image.tag is retired'
expect_failure 'mcp.image.digest=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' 'mcp.image.digest is retired'
expect_failure 'deploymentContract.sourceCommit=deadbeef' 'deploymentContract.sourceCommit must equal vendored application commit'
expect_failure 'deploymentContract.contractFingerprint=deadbeef' 'deploymentContract.contractFingerprint must equal vendored contract fingerprint'
expect_failure 'image.digest=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' 'deploymentContract.imageDigest must equal the application image digest selected for this operation'

# Contract identity is chart-wide, not conditional on an optional workload.
if output=$(helm template bad-default "$chart_dir" --set customerId=test --set deploymentContract.sourceCommit=deadbeef 2>&1); then
  echo 'default workload rendered with a foreign deployment contract identity' >&2; exit 1
fi
grep -Fq 'deploymentContract.sourceCommit must equal vendored application commit' <<<"$output"

# Worker process layout. The default keeps the image-default supervisor with
# no command override; api.embeddedWorkers=false runs the API executable alone
# and is refused unless every worker process keeps a resident host in the
# dedicated worker and/or the cloud-worker pool (ices).
jq -e '
  ([.adapters[] | select(.image_default)] | length == 1)
  and (([.adapters[] | select(.image_default)][0].processes - ["api"]) as $workers
    | [.adapters[] | select(.executable == "/usr/local/bin/run-workers") | ($workers - .processes)] == [[]])
  and ([.adapters[] | select(.executable == "/usr/local/bin/run-core-workers") | .processes] == [["background-worker", "workflow-worker"]])
  and ([.executables[] | select(.id == "api" and .path == "/usr/local/bin/mnemoshare-api")] | length == 1)
  and ([.executables[] | select(.id == "cloud-worker" and .path == "/usr/local/bin/cloud-worker")] | length == 1)
  and ([.executables[] | select(.id == "workflow-worker" and .path == "/usr/local/bin/workflow-worker")] | length == 1)
' "${contract_dir}/contract.json" >/dev/null
embedded_adapter=$(jq -er '.adapters[] | select(.image_default) | .executable' "${contract_dir}/contract.json")
# owns EXECUTABLE-ID NAME: the executable's profile requirements read NAME from env.
owns() {
  jq -e --arg id "$1" --arg name "$2" '[.executables[] | select(.id == $id) | .profiles[].requirements[]?.sources[]? | select(.identity == "env" and .address == $name)] | length > 0' "${contract_dir}/contract.json" >/dev/null
}
# hosts_cloud_worker PATH: the contract says PATH supervises or is cloud-worker.
hosts_cloud_worker() {
  jq -e --arg exe "$1" '(([.adapters[] | select(.executable == $exe) | .processes] + [.executables[] | select(.path == $exe) | [.id]]) | add // []) | index("cloud-worker") != null' "${contract_dir}/contract.json" >/dev/null
}
# Mail-monitoring settings are rendered on every cloud-worker host and nowhere
# else, so cloud-worker must own each name the chart renders; the two names the
# chart stopped rendering must stay unowned by every executable.
mail_names=(GOOGLE_WEBHOOK_URL MICROSOFT_WEBHOOK_URL GOOGLE_INTERNAL_MAIL_INTERVAL_SEC)
dead_mail_names=(GOOGLE_INTERNAL_MAIL_WATCH_INTERVAL_SEC GOOGLE_MAIL_ENROLLMENT_INTERVAL_SEC)
for name in "${mail_names[@]}"; do owns cloud-worker "$name"; done
for name in "${dead_mail_names[@]}"; do
  if jq -e --arg name "$name" '[.executables[].profiles[].requirements[]?.sources[]? | select(.identity == "env" and .address == $name)] | length > 0' "${contract_dir}/contract.json" >/dev/null; then
    echo "$name is owned again; render it from mailMonitoringEnv" >&2; exit 1
  fi
done
owns cloud-worker CLOUD_WORKER_METRICS_ADDR
owns workflow-worker WORKFLOW_WORKER_METRICS_ADDR
layout=(--set customerId=test "${identity[@]}" --set workflowWorker.enabled=true --set redis.mode=external --set redis.external.host=redis.example.com --set dlp.presidioUrl=http://presidio --set dlp.presidioApiKey=key --set dlp.tikaUrl=http://tika --set richMedia.url=http://media --set mailMonitoring.enabled=true --set appUrl=https://mnemoshare.example.com --set encryption.key=test-encryption-key-exactly-32by --set-string jwt.ecPrivateKey=test)
supervisor=(--set 'workflowWorker.command[0]=/usr/local/bin/run-workers')
core=(--set 'workflowWorker.command[0]=/usr/local/bin/run-core-workers')
pool=(--set ices.enabled=true)
container_env() {
  python3 -c '
import sys, yaml
want = sys.argv[1]
for document in yaml.safe_load_all(sys.stdin):
    if (document or {}).get("kind") not in ("Deployment", "StatefulSet"):
        continue
    if document["metadata"]["labels"].get("app.kubernetes.io/component") != want:
        continue
    container = document["spec"]["template"]["spec"]["containers"][0]
    print("executable=" + document["spec"]["template"]["metadata"].get("annotations", {}).get("mnemoshare.com/deployment-executable", ""))
    print("command=" + " ".join(container.get("command") or []))
    for item in container.get("env") or []:
        print("env=" + item["name"])
' "$1"
}
# assert_mail CONTAINER-ENV EXECUTABLE: the mail names are present exactly when
# the executable hosts cloud-worker; the dead names never are.
assert_mail() {
  local env=$1 executable=$2 name
  for name in "${mail_names[@]}"; do
    if hosts_cloud_worker "$executable"; then
      grep -Fxq "env=${name}" <<<"$env" || { echo "cloud-worker host $executable lacks $name" >&2; exit 1; }
    else
      ! grep -Fxq "env=${name}" <<<"$env" || { echo "non-host $executable carries $name" >&2; exit 1; }
    fi
  done
  for name in "${dead_mail_names[@]}"; do
    ! grep -Fxq "env=${name}" <<<"$env" || { echo "$executable carries dead $name" >&2; exit 1; }
  done
}
for worker_shape in workflowWorker.persistence.enabled=false workflowWorker.persistence.enabled=true; do
  for pool_shape in ices.enabled=false ices.enabled=true; do
    embedded=$(helm template layout "$chart_dir" "${layout[@]}" "${supervisor[@]}" --set "$worker_shape" --set "$pool_shape")
    embedded_api=$(container_env api <<<"$embedded")
    embedded_worker=$(container_env workflow-worker <<<"$embedded")
    grep -Fxq "executable=${embedded_adapter}" <<<"$embedded_api"
    grep -Fxq 'command=' <<<"$embedded_api"
    for name in PRESIDIO_ENABLED PRESIDIO_API_KEY DLP_AI_ENABLED PRESIDIO_URL TIKA_URL RICH_MEDIA_URL KMS_ENVELOPE_ENABLED; do
      grep -Fxq "env=${name}" <<<"$embedded_api"
      ! grep -Fxq "env=${name}" <<<"$embedded_worker"
    done
    assert_mail "$embedded_api" "$embedded_adapter"
    assert_mail "$embedded_worker" /usr/local/bin/run-workers
    if [ "$pool_shape" = ices.enabled=true ]; then
      embedded_pool=$(container_env ices <<<"$embedded")
      grep -Fxq 'command=/usr/local/bin/cloud-worker' <<<"$embedded_pool"
      assert_mail "$embedded_pool" /usr/local/bin/cloud-worker
    else
      test -z "$(container_env ices <<<"$embedded")"
    fi
    # Setting the new values to their defaults changes nothing.
    explicit=$(helm template layout "$chart_dir" "${layout[@]}" "${supervisor[@]}" --set "$worker_shape" --set "$pool_shape" --set api.embeddedWorkers=true --set ices.metrics.enabled=false --set workflowWorker.metrics.enabled=false --set ices.autoscaling.prometheus.serverAddress= --set workflowWorker.autoscaling.prometheus.serverAddress=)
    test "$explicit" = "$embedded"

    api_only=$(helm template layout "$chart_dir" "${layout[@]}" "${supervisor[@]}" --set "$worker_shape" --set "$pool_shape" --set api.embeddedWorkers=false)
    api_only_api=$(container_env api <<<"$api_only")
    api_only_worker=$(container_env workflow-worker <<<"$api_only")
    grep -Fxq 'executable=/usr/local/bin/mnemoshare-api' <<<"$api_only_api"
    grep -Fxq 'command=/usr/local/bin/mnemoshare-api' <<<"$api_only_api"
    grep -Fxq 'command=/usr/local/bin/run-workers' <<<"$api_only_worker"
    for name in PRESIDIO_ENABLED PRESIDIO_API_KEY DLP_AI_ENABLED; do
      ! grep -Fxq "env=${name}" <<<"$api_only_api"
      grep -Fxq "env=${name}" <<<"$api_only_worker"
    done
    for name in PRESIDIO_URL TIKA_URL RICH_MEDIA_URL KMS_ENVELOPE_ENABLED; do
      grep -Fxq "env=${name}" <<<"$api_only_api"
      grep -Fxq "env=${name}" <<<"$api_only_worker"
    done
    assert_mail "$api_only_api" /usr/local/bin/mnemoshare-api
    assert_mail "$api_only_worker" /usr/local/bin/run-workers
    [ "$pool_shape" = ices.enabled=false ] || assert_mail "$(container_env ices <<<"$api_only")" /usr/local/bin/cloud-worker
    # Only the worker-only integration names and the mail names leave the API pod.
    test "$(comm -23 <(grep '^env=' <<<"$embedded_api" | sort) <(grep '^env=' <<<"$api_only_api" | sort) | tr '\n' ' ')" = 'env=DLP_AI_ENABLED env=GOOGLE_INTERNAL_MAIL_INTERVAL_SEC env=GOOGLE_WEBHOOK_URL env=MICROSOFT_WEBHOOK_URL env=PRESIDIO_API_KEY env=PRESIDIO_ENABLED '
    test -z "$(comm -13 <(grep '^env=' <<<"$embedded_api" | sort) <(grep '^env=' <<<"$api_only_api" | sort))"
  done

  # Pool layout: cloud-worker only in the ices pool, background + workflow in
  # the dedicated worker, metrics and the backlog trigger on both.
  pooled=$(helm template layout "$chart_dir" "${layout[@]}" "${core[@]}" "${pool[@]}" --set "$worker_shape" --set api.embeddedWorkers=false --set ices.metrics.enabled=true --set ices.autoscaling.enabled=true --set ices.autoscaling.prometheus.serverAddress=http://prometheus:9090 --set workflowWorker.metrics.enabled=true --set workflowWorker.autoscaling.enabled=true --set workflowWorker.autoscaling.prometheus.serverAddress=http://prometheus:9090)
  pooled_api=$(container_env api <<<"$pooled")
  pooled_worker=$(container_env workflow-worker <<<"$pooled")
  pooled_pool=$(container_env ices <<<"$pooled")
  grep -Fxq 'command=/usr/local/bin/mnemoshare-api' <<<"$pooled_api"
  grep -Fxq 'command=/usr/local/bin/run-core-workers' <<<"$pooled_worker"
  grep -Fxq 'command=/usr/local/bin/cloud-worker' <<<"$pooled_pool"
  assert_mail "$pooled_api" /usr/local/bin/mnemoshare-api
  assert_mail "$pooled_worker" /usr/local/bin/run-core-workers
  assert_mail "$pooled_pool" /usr/local/bin/cloud-worker
  grep -Fxq 'env=CLOUD_WORKER_METRICS_ADDR' <<<"$pooled_pool"
  ! grep -Fxq 'env=CLOUD_WORKER_METRICS_ADDR' <<<"$pooled_worker"
  grep -Fxq 'env=WORKFLOW_WORKER_METRICS_ADDR' <<<"$pooled_worker"
  ! grep -Fxq 'env=WORKFLOW_WORKER_METRICS_ADDR' <<<"$pooled_pool"
  for name in PRESIDIO_ENABLED PRESIDIO_API_KEY DLP_AI_ENABLED; do grep -Fxq "env=${name}" <<<"$pooled_worker"; done
  pooled_scalers=$(python3 -c '
import sys, yaml
for document in yaml.safe_load_all(sys.stdin):
    if (document or {}).get("kind") != "ScaledObject":
        continue
    print(document["metadata"]["labels"]["app.kubernetes.io/component"] + "=" + ",".join(t["type"] for t in document["spec"]["triggers"]) + " min=" + str(document["spec"]["minReplicaCount"]))
    for trigger in document["spec"]["triggers"]:
        if trigger["type"] == "prometheus":
            print("query=" + trigger["metadata"]["query"])
' <<<"$pooled")
  grep -Fxq 'ices=prometheus min=2' <<<"$pooled_scalers"
  grep -Fxq 'workflow-worker=prometheus min=1' <<<"$pooled_scalers"
  grep -Fxq 'query=sum(mnemoshare_dispatch_backlog_rows{namespace="default",process="cloud-worker",engine=~"google|microsoft"})' <<<"$pooled_scalers"
  grep -Fxq 'query=sum(mnemoshare_dispatch_backlog_rows{namespace="default",process="workflow-worker"})' <<<"$pooled_scalers"
  ! grep -Fq 'kind: TriggerAuthentication' <<<"$pooled"
  grep -Fq 'prometheus.io/port: "9091"' <<<"$pooled"
  # Both pool triggers render when both are configured, prometheus first.
  both=$(helm template layout "$chart_dir" "${layout[@]}" "${core[@]}" "${pool[@]}" --set "$worker_shape" --set api.embeddedWorkers=false --set ices.metrics.enabled=true --set ices.autoscaling.enabled=true --set ices.autoscaling.prometheus.serverAddress=http://prometheus:9090 --set ices.autoscaling.subscriptionName=projects/p/subscriptions/s)
  grep -Fq 'type: prometheus' <<<"$both"
  grep -Fq 'type: gcp-pubsub' <<<"$both"
  # Without a Prometheus address the pool keeps the Pub/Sub trigger alone and the worker its Redis triggers.
  legacy=$(helm template layout "$chart_dir" "${layout[@]}" "${supervisor[@]}" "${pool[@]}" --set "$worker_shape" --set ices.autoscaling.enabled=true --set ices.autoscaling.subscriptionName=projects/p/subscriptions/s --set workflowWorker.autoscaling.enabled=true --set redis.external.password=x --set existingSecrets.redis=redis-secret)
  ! grep -Fq 'type: prometheus' <<<"$legacy"
  grep -Fq 'listName: "asynq:default:pending"' <<<"$legacy"
  grep -Fq 'kind: TriggerAuthentication' <<<"$legacy"
done

expect_layout_failure() {
  local expected=$1 output
  shift
  if output=$(helm template bad-layout "$chart_dir" --set customerId=test "${identity[@]}" --set api.embeddedWorkers=false "$@" 2>&1); then
    echo "API-only layout rendered without a complete worker host: $*" >&2; exit 1
  fi
  grep -Fq "$expected" <<<"$output" || { echo "API-only layout failure lacked: $expected" >&2; exit 1; }
}
worker=(--set workflowWorker.enabled=true --set redis.mode=external --set redis.external.host=redis.example.com)
expect_layout_failure 'leaves background-worker with no host'
expect_layout_failure 'leaves background-worker with no host' "${worker[@]}"
expect_layout_failure 'leaves background-worker with no host' "${worker[@]}" --set 'workflowWorker.command[0]=/usr/local/bin/workflow-worker'
expect_layout_failure 'leaves background-worker with no host' "${worker[@]}" "${supervisor[@]}" --set workflowWorker.replicas=0
expect_layout_failure 'leaves background-worker with no host' "${worker[@]}" "${supervisor[@]}" --set workflowWorker.autoscaling.enabled=true --set workflowWorker.autoscaling.minReplicas=0
expect_layout_failure 'embeddedWorkers' "${worker[@]}" "${supervisor[@]}" --set-string api.embeddedWorkers=false
expect_layout_failure 'leaves cloud-worker with no host' "${worker[@]}" "${core[@]}"
expect_layout_failure 'leaves cloud-worker with no host' "${worker[@]}" "${core[@]}" "${pool[@]}" --set ices.replicas=0
expect_layout_failure 'ices.autoscaling.minReplicas must be >= 1' "${worker[@]}" "${core[@]}" "${pool[@]}" --set ices.autoscaling.enabled=true --set ices.autoscaling.minReplicas=0 --set ices.autoscaling.subscriptionName=projects/p/subscriptions/s
expect_layout_failure 'needs a trigger' "${worker[@]}" "${core[@]}" "${pool[@]}" --set ices.autoscaling.enabled=true
expect_layout_failure 'requires ices.metrics.enabled=true' "${worker[@]}" "${core[@]}" "${pool[@]}" --set ices.autoscaling.enabled=true --set ices.autoscaling.prometheus.serverAddress=http://prometheus:9090
expect_layout_failure 'does not host cloud-worker' "${worker[@]}" "${supervisor[@]}" "${pool[@]}" --set 'ices.command[0]=/usr/local/bin/run-core-workers' --set ices.metrics.enabled=true
expect_layout_failure 'requires workflowWorker.metrics.enabled=true' "${worker[@]}" "${supervisor[@]}" --set workflowWorker.autoscaling.enabled=true --set workflowWorker.autoscaling.prometheus.serverAddress=http://prometheus:9090

if output=$(helm template missing "$chart_dir" --set customerId=test "${identity[@]}" --set mcp.enabled=true 2>&1); then echo 'MCP rendered without API key binding' >&2; exit 1; fi
grep -Fq 'mcp.enabled requires mcp.apiKey.existingSecret or mcp.apiKey.key' <<<"$output"
derived=$(helm template derived "$chart_dir" --set customerId=test --set mcp.enabled=true --set mcp.apiKey.key=x)
grep -Eq 'image: "mnemoshare/mnemoshare@sha256:[a-f0-9]{64}"' <<<"$derived"
