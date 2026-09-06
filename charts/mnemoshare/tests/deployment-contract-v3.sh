#!/usr/bin/env bash
set -euo pipefail

contract_dir=$(cd "$(dirname "$0")" && pwd)/contracts/deployment/v3
expected_commit=0dd4f8eb13b9afb35a586f4ac7bc8618d25d7886
expected_fingerprint=23dc67fb882b463fbc1bd05d0732d2a5aadc86b3070b228dd5f62cb204319cc6

test "$(sed -n 's/^repository=//p' "${contract_dir}/UPSTREAM")" = https://github.com/MnemoShare/mnemoshare.git
test "$(sed -n 's/^commit=//p' "${contract_dir}/UPSTREAM")" = "$expected_commit"
test "$(sed -n 's/^path=//p' "${contract_dir}/UPSTREAM")" = contracts/deployment/v3
test "$(sed -n 's/^sha256sums=//p' "${contract_dir}/UPSTREAM")" = "$(sha256sum "${contract_dir}/SHA256SUMS" | cut -d' ' -f1)"
(cd "$contract_dir" && sha256sum -c SHA256SUMS)
jq -e --arg fingerprint "$expected_fingerprint" '
  .provenance.schema == "mnemoshare.deployment-contract.v3"
  and .fingerprint == $fingerprint
  and ([.executables[] | select(.id == "emailgateway" and .path == "/usr/local/bin/email-gateway") ] | length == 1)
' "${contract_dir}/contract.json" >/dev/null

python3 - "$contract_dir" <<'PY'
import hashlib
import json
import pathlib
import sys

from jsonschema import Draft202012Validator
from jsonschema.exceptions import ValidationError

root = pathlib.Path(sys.argv[1])
schema = json.loads((root / "schema.json").read_text())
vectors = json.loads((root / "conformance.json").read_text())
Draft202012Validator.check_schema(schema)
validator = Draft202012Validator(schema)

def semantic_errors(contract):
    errors = []
    executables = contract.get("executables", [])
    executable_ids = [item.get("id") for item in executables]
    if len(executable_ids) != len(set(executable_ids)):
        errors.append("duplicate executable id")
    for executable in executables:
        selector = executable.get("profile_selector", "")
        for profile in executable.get("profiles", []):
            selections = profile.get("selection", [])
            if bool(selector) != bool(selections):
                errors.append("profile selector and selection must coexist")
            for alternative in selections:
                for condition in alternative.get("all", []):
                    if condition.get("operator") in ("set", "unset") and "value" in condition:
                        errors.append("set and unset conditions cannot carry a value")
            for universe in profile.get("external_universes", []):
                if not universe.get("surfaces"):
                    errors.append("external universe requires surfaces")
    for adapter in contract.get("adapters", []):
        for process in adapter.get("processes", []):
            if process not in executable_ids:
                errors.append("adapter references unknown process")
    return errors

for vector in vectors["valid"]:
    validator.validate(vector["json"])
    assert not semantic_errors(vector["json"]), vector["name"]
for vector in vectors["invalid"]:
    try:
        validator.validate(vector["json"])
    except ValidationError:
        continue
    assert semantic_errors(vector["json"]), f'invalid vector passed: {vector["name"]}'

contract = json.loads((root / "contract.json").read_text())
validator.validate(contract)
assert not semantic_errors(contract)

restamp = vectors["restamp"]
canonical = json.dumps(
    restamp["input"], ensure_ascii=False, sort_keys=True, separators=(",", ":")
)
assert canonical == restamp["canonical_jcs"]
assert hashlib.sha256(canonical.encode()).hexdigest() == restamp["sha256"]
PY

chart_dir=${1:-$(cd "$(dirname "$0")/.." && pwd)}
digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
base=(
  --set customerId=test
  --set image.digest="$digest"
  --set deploymentContractV3.sourceCommit="$expected_commit"
  --set deploymentContractV3.contractFingerprint="$expected_fingerprint"
  --set deploymentContractV3.imageDigest="$digest"
  --set emailGateway.enabled=true
)

render_profile() {
  local expected=$1; shift
  local render deployment
  render=$(helm template contract-v3 "$chart_dir" "${base[@]}" "$@")
  deployment=$(awk '/# Source: mnemoshare\/templates\/email-gateway-deployment.yaml/{active=1;next} active&&/^---$/{exit} active{print}' <<<"$render")
  grep -Fq "mnemoshare.com/deployment-profile: \"${expected}\"" <<<"$deployment"
  grep -Fq "image: \"mnemoshare/mnemoshare@${digest}\"" <<<"$deployment"
  grep -Fq 'command: ["/usr/local/bin/email-gateway"]' <<<"$deployment"
  grep -Fq 'containerPort: 8080' <<<"$deployment"
  grep -Fq 'value: "8080"' <<<"$deployment"
  grep -Fq 'path: /readyz' <<<"$deployment"
  grep -Fq 'path: /healthz' <<<"$deployment"
  ! grep -Fq 'mnemoshare.io/database-writer' <<<"$deployment"
  printf '%s' "$render"
}

gateway=$(render_profile gateway --set emailGateway.mode=gateway)
! grep -Fq -- '--universe email-relay-mongo' <<<"$gateway"
grep -Fq 'type: RollingUpdate' <<<"$gateway"
inbound=$(render_profile inbound-relay --set emailGateway.mode=inbound-relay --set emailGateway.relay.spoolSharedKey=spool)
grep -Fq 'persistentVolumeClaim:' <<<"$inbound"
grep -Fq 'type: Recreate' <<<"$inbound"
no_store=$(render_profile relay-no-store --set emailGateway.mode=relay --set emailGateway.smtpAuthRequired=false --set emailGateway.relay.spoolSharedKey=spool)
grep -Fq 'name: RELAY_SMTP_AUTH_REQUIRED' <<<"$no_store"
! grep -Fq -- '--universe email-relay-mongo' <<<"$no_store"
dkim=$(render_profile relay-dkim --set emailGateway.mode=relay --set emailGateway.smtpAuthRequired=false --set emailGateway.relay.spoolSharedKey=spool --set emailGateway.relay.db.uri=mongodb://relay)
grep -Fq -- '--universe email-relay-mongo' <<<"$dkim"
tokens=$(render_profile relay-dkim-and-tokens --set emailGateway.mode=relay --set emailGateway.relay.spoolSharedKey=spool --set emailGateway.relay.db.uri=mongodb://relay)
grep -Fq -- '--universe email-relay-mongo' <<<"$tokens"
grep -Fq -- '--from-literal=external-plan-digest="${external_plan_digest}"' <<<"$tokens"
grep -Fq 'app.kubernetes.io/component in (email-gateway,sftp-gateway,mcp)' <<<"$tokens"
grep -Fq 'external-universe=email-relay-mongo' <<<"$tokens"
grep -Fq 'email-gateway) printf' <<<"$tokens"
grep -Fq '$external == "true" and .data.decision == "maintenance"' <<<"$tokens"
grep -Fq 'stored_external_digest="$(kubectl get "${state_resource}" -o jsonpath=' <<<"$tokens"
grep -Fq 'replanned email-relay-mongo digest drifted from durable target plan' <<<"$tokens"
grep -Fq 'fresh install with an empty writer census found existing application pods' <<<"$tokens"
grep -Fq 'app.kubernetes.io/component in (api,workflow-worker,ices,inbound-gateway,email-gateway,sftp-gateway,mcp)' <<<"$tokens"
primary_apply_line=$(grep -n -- '--expect-plan-digest "$(cat /migration/plan-digest)"' <<<"$tokens" | tail -1 | cut -d: -f1)
relay_apply_line=$(grep -n -- '--universe email-relay-mongo --expect-plan-digest "$(cat /migration/email-relay-plan-digest)"' <<<"$tokens" | tail -1 | cut -d: -f1)
test "$primary_apply_line" -lt "$relay_apply_line"

expect_failure() {
	local expected=$1 output
	shift
  if output=$(helm template bad-v3 "$chart_dir" "${base[@]}" "$@" 2>&1); then
    echo "invalid emailgateway configuration rendered: $*" >&2
    exit 1
  fi
  grep -Fq "$expected" <<<"$output"
}
expect_failure 'select exactly one' --set emailGateway.mode=inbound-relay
expect_failure 'select exactly one' --set emailGateway.mode=relay
expect_failure 'select exactly one' --set emailGateway.mode=relay --set emailGateway.relay.spoolSharedKey=spool
expect_failure 'durable spool' --set emailGateway.mode=inbound-relay --set emailGateway.relay.spoolSharedKey=spool --set emailGateway.relay.persistence.enabled=false
expect_failure 'durable path /var/spool/mnemo-relay' --set emailGateway.mode=inbound-relay --set emailGateway.relay.spoolSharedKey=spool --set emailGateway.relay.spoolDir=/tmp/spool
expect_failure 'replicas exactly 1' --set emailGateway.mode=inbound-relay --set emailGateway.relay.spoolSharedKey=spool --set emailGateway.replicas=2
expect_failure 'mutually exclusive' --set emailGateway.mode=inbound-relay --set emailGateway.relay.spoolSharedKey=spool --set emailGateway.relay.hosts=mx.example --set emailGateway.relayHosts[0]=legacy.example
expect_failure 'must include port 25' --set emailGateway.mode=gateway --set emailGateway.listenPorts=2525:plain
expect_failure 'duplicate port 25' --set emailGateway.mode=gateway --set-string 'emailGateway.listenPorts=25:plain\,25:starttls'
expect_failure 'not canonically spelled as 25' --set emailGateway.mode=gateway --set-string 'emailGateway.listenPorts=025:plain\,25:starttls'
expect_failure 'invalid listener' --set emailGateway.mode=gateway --set emailGateway.listenPorts=25:bogus
expect_failure 'collides with deployment-contract v3 probe port 8080' --set emailGateway.mode=gateway --set-string 'emailGateway.listenPorts=25:plain\,8080:plain'
expect_failure 'may not override' --set emailGateway.extraEnv[0].name=HEALTH_PORT --set emailGateway.extraEnv[0].value=9999
expect_failure 'sourceCommit must equal' --set deploymentContractV3.sourceCommit=deadbeef
expect_failure 'must equal the global image.digest' --set deploymentContractV3.imageDigest=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
expect_failure 'sourceCommit must equal' --set deploymentContractV3.sourceCommit=
expect_failure 'image.digest pinned as sha256' --set image.digest=

existing_claim=$(render_profile inbound-relay --set emailGateway.mode=inbound-relay --set emailGateway.relay.spoolSharedKey=spool --set emailGateway.relay.persistence.enabled=false --set emailGateway.relay.persistence.existingClaim=external-spool)
grep -Fq 'claimName: external-spool' <<<"$existing_claim"

existing_spool_key=$(render_profile inbound-relay --set emailGateway.mode=inbound-relay --set emailGateway.relay.existingSpoolKeySecret=relay-spool)
grep -Fq 'name: relay-spool' <<<"$existing_spool_key"
grep -Fq 'key: relay-spool-shared-key' <<<"$existing_spool_key"

relay_hosts=$(render_profile inbound-relay --set emailGateway.mode=inbound-relay --set emailGateway.relay.spoolSharedKey=spool --set emailGateway.relayHosts[0]=mx-a --set emailGateway.relayHosts[1]=mx-b)
test "$(grep -Fc 'name: RELAY_HOSTS' <<<"$relay_hosts")" -eq 1
grep -Fq 'value: "mx-a,mx-b"' <<<"$relay_hosts"

external_secret=$(render_profile relay-dkim --set emailGateway.mode=relay --set emailGateway.smtpAuthRequired=false --set emailGateway.relay.spoolSharedKey=spool --set emailGateway.relay.db.existingSecret=relay-db)
grep -Fq 'name: snapshot-email-relay-mongo-credentials' <<<"$external_secret"
grep -Fq 'source="relay-db"' <<<"$external_secret"
grep -Fq 'email-relay-mongo credential snapshot identity mismatch' <<<"$external_secret"

expect_failure 'networkPolicyCIDRs' --set emailGateway.mode=relay --set emailGateway.smtpAuthRequired=false --set emailGateway.relay.spoolSharedKey=spool --set emailGateway.relay.db.uri=mongodb://relay --set networkPolicy.enabled=true --set formatMigrations.networkPolicy.databaseCIDRs[0]=10.0.0.1/32 --set formatMigrations.networkPolicy.kubernetesApiTargets[0].cidr=10.0.0.2/32 --set formatMigrations.networkPolicy.kubernetesApiTargets[0].port=443
no_store_networked=$(render_profile relay-no-store --set emailGateway.mode=relay --set emailGateway.smtpAuthRequired=false --set emailGateway.relay.spoolSharedKey=spool --set networkPolicy.enabled=true --set formatMigrations.networkPolicy.databaseCIDRs[0]=10.0.0.1/32 --set formatMigrations.networkPolicy.kubernetesApiTargets[0].cidr=10.0.0.2/32 --set formatMigrations.networkPolicy.kubernetesApiTargets[0].port=443)
! grep -Fq 'email-relay-mongo automatic migration requires' <<<"$no_store_networked"
networked=$(render_profile relay-dkim --set emailGateway.mode=relay --set emailGateway.smtpAuthRequired=false --set emailGateway.relay.spoolSharedKey=spool --set emailGateway.relay.db.uri=mongodb://relay --set networkPolicy.enabled=true --set formatMigrations.networkPolicy.databaseCIDRs[0]=10.0.0.1/32 --set formatMigrations.networkPolicy.kubernetesApiTargets[0].cidr=10.0.0.2/32 --set formatMigrations.networkPolicy.kubernetesApiTargets[0].port=443 --set emailGateway.relay.db.networkPolicyCIDRs[0]=10.0.0.3/32 --set emailGateway.relay.db.networkPolicyPort=27019)
test "$(grep -Fc 'cidr: "10.0.0.3/32"' <<<"$networked")" -eq 2
test "$(grep -Fc 'port: 27019' <<<"$networked")" -eq 2
grep -Fq 'port: 8080' <<<"$networked"
! grep -Fq 'port: 8081' <<<"$networked"

coexist=$(helm template coexist "$chart_dir" "${base[@]}" \
  --set deploymentContractV2.sourceCommit=aba43f7911586189a6e056bb1c9dcab7258b21d4 \
  --set deploymentContractV2.contractFingerprint=e73dd2b91c7de17428fbfe1c4984758aa9a3894c6aadced0531f0ff591b67836 \
  --set deploymentContractV2.imageDigest="$digest" \
  --set mcp.enabled=true --set mcp.apiKey.key=test)
test "$(grep -Fc "image: \"mnemoshare/mnemoshare@${digest}\"" <<<"$coexist")" -ge 2

echo 'deployment contract v3 consumer tests passed'
