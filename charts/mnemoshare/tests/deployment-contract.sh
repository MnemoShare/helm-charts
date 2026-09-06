#!/usr/bin/env bash
set -euo pipefail

chart_dir=${1:-$(cd "$(dirname "$0")/.." && pwd)}
contract_dir=$(cd "$(dirname "$0")" && pwd)/contracts/deployment/v2
upstream=aba43f7911586189a6e056bb1c9dcab7258b21d4
fingerprint=e73dd2b91c7de17428fbfe1c4984758aa9a3894c6aadced0531f0ff591b67836
digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
identity=(--set "deploymentContractV2.sourceCommit=${upstream}" --set "deploymentContractV2.contractFingerprint=${fingerprint}" --set "deploymentContractV2.imageDigest=${digest}" --set "image.digest=${digest}")
(cd "$contract_dir" && sha256sum -c SHA256SUMS)
test "$(sed -n 's/^commit=//p' "${contract_dir}/UPSTREAM")" = "$upstream"
test "$(sed -n 's/^path=//p' "${contract_dir}/UPSTREAM")" = contracts/deployment/v2
test "$(sed -n 's/^sha256sums=//p' "${contract_dir}/UPSTREAM")" = "$(sha256sum "${contract_dir}/SHA256SUMS" | cut -d' ' -f1)"
jq -e '.provenance.schema == "mnemoshare.deployment-contract.v2" and (.processes | map(select(.id == "mcp-admin" and .persistence == "none" and .executable == "/usr/local/bin/mcp-admin" and .args == ["--transport=http","--http-addr=:9222","--log-level=info","--log-format=json"] and .probe.port == 9222)) | length == 1) and (.processes | map(select(.id == "sftp-gateway" and .persistence == "none" and .executable == "/usr/local/bin/sftp-gateway" and .probe.path == "/readyz" and .probe.port == 8090 and .liveness_probe.path == "/healthz")) | length == 1)' "${contract_dir}/contract.json" >/dev/null

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
grep -Fq "app.kubernetes.io/component in (sftp-gateway,mcp)'" <<<"$migration_render"
grep -Fq 'for resource in ${peer_controllers}; do' <<<"$migration_render"
grep -Fq 'for component in api workflow-worker ices inbound-gateway email-gateway sftp-gateway mcp; do' <<<"$migration_render"
grep -Fq ': > /migration/writer-replicas' <<<"$migration_render"
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
expect_failure 'deploymentContractV2.sourceCommit=deadbeef' 'deploymentContractV2.sourceCommit must equal vendored application commit'
expect_failure 'deploymentContractV2.contractFingerprint=deadbeef' 'deploymentContractV2.contractFingerprint must equal vendored contract fingerprint'
expect_failure 'image.digest=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' 'deploymentContractV2.imageDigest must equal the global image.digest'

if output=$(helm template missing "$chart_dir" --set customerId=test "${identity[@]}" --set mcp.enabled=true 2>&1); then echo 'MCP rendered without API key binding' >&2; exit 1; fi
grep -Fq 'mcp.enabled requires mcp.apiKey.existingSecret or mcp.apiKey.key' <<<"$output"
if output=$(helm template unpinned "$chart_dir" --set customerId=test --set mcp.enabled=true --set mcp.apiKey.key=x 2>&1); then echo 'MCP rendered without immutable deployment identity' >&2; exit 1; fi
grep -Fq 'deploymentContractV2.sourceCommit must equal vendored application commit' <<<"$output"
if output=$(helm template missing-digest "$chart_dir" --set customerId=test --set "deploymentContractV2.sourceCommit=${upstream}" --set "deploymentContractV2.contractFingerprint=${fingerprint}" --set mcp.enabled=true --set mcp.apiKey.key=x 2>&1); then echo 'MCP rendered without immutable image digest binding' >&2; exit 1; fi
grep -Fq 'deploymentContractV2.imageDigest is required' <<<"$output"
