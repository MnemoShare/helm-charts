#!/usr/bin/env bash
# Sandbox runner renders: off by default, confined RBAC, engine-host wiring,
# TLS/plaintext gate, and the strict-mode handling of the API-server fallback.
set -euo pipefail

chart=${1:-charts/mnemoshare}
base=(
  --set customerId=ci-test
  --set image.digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  --set cors.allowedOrigins=https://ci.example.com
  --set mongodb.external.enabled=true
  --set mongodb.external.uri=mongodb://test:test@localhost:27017/test
  --set s3.bucket=test-bucket --set s3.accessKey=test-key --set s3.secretKey=test-secret
  --set-string jwt.ecPrivateKey=test-ec-key
  --set encryption.key=test-encryption-key-exactly-32by
  --set license.key=test-license-key
  --set appUrl=https://test.example.com
  --set ingress.enabled=false
  --namespace tenant
)
on=(--set sandbox.enabled=true --set sandbox.runner.tls.issuerRef.name=issuer)
worker=(--set workflowWorker.enabled=true --set redis.mode=external --set redis.external.host=redis.example.com)
here=$(cd "$(dirname "$0")/../../.." && pwd)

fail() { echo "sandbox-runner: $*" >&2; exit 1; }
render() { helm template t "$chart" "${base[@]}" "$@"; }

out=$(render)
! grep -q "sandbox" <<<"$out" || fail "sandbox resources rendered with sandbox.enabled=false"
! grep -q "SANDBOX_RUNNER" <<<"$out" || fail "sandbox env rendered with sandbox.enabled=false"

# Business shape: the API hosts the engine.
out=$(render "${on[@]}" --set sandbox.runner.replicas=1)
python3 "$here/hack/check-render.py" <(echo "$out") >/dev/null || fail "api-host render fails the render guards"
for want in "namespace: tenant-sandbox" "kind: Certificate" "name: SANDBOX_RUNNER_URL" \
  "https://mnemoshare-sandbox-runner.tenant.svc:8083" "name: SANDBOX_NAMESPACE" "value: \"tenant-sandbox\""; do
  grep -qF -- "$want" <<<"$out" || fail "api-host render lacks: $want"
done
! grep -q "kind: PodDisruptionBudget" <<<"$out" || fail "single-replica runner renders a PDB"
! grep -q "kind: Namespace" <<<"$out" || fail "namespace rendered although createNamespace=false"
[[ $(grep -c "name: SANDBOX_RUNNER_URL" <<<"$out") == 1 ]] || fail "engine env must be on exactly one workload"
role=$(awk '/^kind: Role$/{a=1} a&&/^---$/{exit} a' <<<"$out")
! grep -Eq "secrets|exec|persistentvolumeclaims|\*" <<<"$role" || fail "runner Role is too broad"

# Quota backstop and runner caps render with the Business+ defaults.
for want in "kind: ResourceQuota" "kind: LimitRange" '"pods": "3"' "name: SANDBOX_MAX_CONCURRENT_JOBS" \
  "name: SANDBOX_MAX_INPUT_BYTES" "name: SANDBOX_MAX_OUTPUT_BYTES"; do
  grep -qF -- "$want" <<<"$out" || fail "quota render lacks: $want"
done
quota=$(render "${on[@]}" --set sandbox.quota.enabled=false)
! grep -q "kind: ResourceQuota" <<<"$quota" || fail "quota rendered with sandbox.quota.enabled=false"
small=$(render "${on[@]}" --set-string sandbox.policy.limits.maxConcurrentJobs=1 --set-string sandbox.quota.hard.pods=1)
grep -qF '"pods": "1"' <<<"$small" || fail "quota hard overrides not honoured"

# Business+ shape: workers host the engine.
out=$(render "${on[@]}" "${worker[@]}")
python3 "$here/hack/check-render.py" <(echo "$out") >/dev/null || fail "worker-host render fails the render guards"
grep -q "kind: PodDisruptionBudget" <<<"$out" || fail "two-replica runner lacks a PDB"
grep -Eq "app.kubernetes.io/component: workflow-worker" <<<"$(awk '/name: mnemoshare-sandbox-runner-ingress/{a=1} a&&/^---$/{exit} a' <<<"$out")" || fail "runner ingress is not limited to workers"

out=$(render "${on[@]}" --set sandbox.createNamespace=true)
grep -q "pod-security.kubernetes.io/enforce: restricted" <<<"$out" || fail "created namespace is not pod-security restricted"

# TLS/plaintext gate and issuer requirement.
if render --set sandbox.enabled=true >/dev/null 2>&1; then fail "TLS enabled with no issuer or secret rendered"; fi
if render --set sandbox.enabled=true --set sandbox.runner.tls.enabled=false >/dev/null 2>&1; then fail "plaintext rendered without allowPlaintext"; fi
render --set sandbox.enabled=true --set sandbox.runner.tls.enabled=false --set sandbox.runner.tls.allowPlaintext=true |
  grep -q 'name: SANDBOX_RUNNER_ALLOW_PLAINTEXT' || fail "plaintext opt-in not passed to the runner"

# The API-server fallback is listed in NOTES and fails under strict.
notes=$(mktemp -d); trap 'rm -rf "$notes"' EXIT
cp -R "$chart" "$notes/chart"
{ echo '{{- define "notes-probe" -}}'; cat "$notes/chart/templates/NOTES.txt"; echo '{{- end -}}'; } >"$notes/chart/templates/_notes-probe.tpl"
echo 'notes: {{ include "notes-probe" . | toJson }}' >"$notes/chart/templates/notes-probe.yaml"
out=$(helm template t "$notes/chart" "${base[@]}" "${on[@]}" --show-only templates/notes-probe.yaml)
grep -qF "sandbox runner Kubernetes API egress" <<<"$out" || fail "NOTES missing the sandbox API fallback"
api=(--set "sandbox.runner.egress.kubernetesApiTargets[0].cidr=10.96.0.1/32" --set "sandbox.runner.egress.kubernetesApiTargets[0].port=443")
out=$(helm template t "$notes/chart" "${base[@]}" "${on[@]}" "${api[@]}" --show-only templates/notes-probe.yaml)
! grep -qF "sandbox runner Kubernetes API egress" <<<"$out" || fail "NOTES list the fallback although targets are set"

# Other strict fallbacks are closed here so only the sandbox one is under test.
strict=(
  --set networkPolicy.strict=true
  --set "networkPolicy.database.cidrs={10.0.0.0/24}"
  --set "formatMigrations.networkPolicy.databaseCIDRs={10.0.0.0/24}"
  --set "formatMigrations.networkPolicy.kubernetesApiTargets[0].cidr=10.96.0.1/32"
  --set "formatMigrations.networkPolicy.kubernetesApiTargets[0].port=443"
)
err=$(render "${on[@]}" "${strict[@]}" 2>&1) && fail "strict render succeeded without sandbox.runner.egress.kubernetesApiTargets"
grep -qF "sandbox.runner.egress.kubernetesApiTargets is unset" <<<"$err" || fail "strict failure did not name the sandbox setting: $err"
render "${on[@]}" "${strict[@]}" "${api[@]}" >/dev/null || fail "strict render failed although targets are set"
echo "sandbox-runner: ok"
