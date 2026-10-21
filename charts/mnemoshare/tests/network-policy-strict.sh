#!/usr/bin/env bash
# networkPolicy fallbacks are listed in NOTES and networkPolicy.strict turns each into a render failure.
set -euo pipefail

chart_dir=${1:-charts/mnemoshare}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp -R "$chart_dir" "$work/chart"
# helm template does not print NOTES.txt; render it as an ordinary template instead.
{
  echo '{{- define "notes-probe" -}}'
  cat "$work/chart/templates/NOTES.txt"
  echo '{{- end -}}'
} >"$work/chart/templates/_notes-probe.tpl"
echo 'notes: {{ include "notes-probe" . | toJson }}' >"$work/chart/templates/notes-probe.yaml"
chart=$work/chart

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
)
wide=(
  --set emailGateway.enabled=true
  --set redis.mode=external --set redis.external.host=redis.example.com
)
# setting|--set value; one entry per setting that closes a fallback
narrow=(
  "networkPolicy.database.cidrs|networkPolicy.database.cidrs={10.0.0.0/24}"
  "networkPolicy.redis.cidrs|networkPolicy.redis.cidrs={10.0.1.0/24}"
  "emailGateway.relay.db.networkPolicyCIDRs|emailGateway.relay.db.networkPolicyCIDRs={10.0.2.0/24}"
  "formatMigrations.networkPolicy.databaseCIDRs|formatMigrations.networkPolicy.databaseCIDRs={10.0.0.0/24}"
  "formatMigrations.networkPolicy.kubernetesApiTargets|formatMigrations.networkPolicy.kubernetesApiTargets[0].cidr=10.96.0.1/32"
  "formatMigrations.networkPolicy.kubernetesApiTargets|formatMigrations.networkPolicy.kubernetesApiTargets[0].port=443"
)
# narrow_args [skip-setting]: --set args for every entry except the skipped setting
narrow_args() {
  local entry
  for entry in "${narrow[@]}"; do
    [[ ${entry%%|*} == "${1:-}" ]] || printf '%s\n' --set "${entry#*|}"
  done
}

fail() { echo "network-policy-strict: $*" >&2; exit 1; }

notes() { helm template t "$chart" "${base[@]}" "$@" --show-only templates/notes-probe.yaml; }
all_narrow=(); while IFS= read -r a; do all_narrow+=("$a"); done < <(narrow_args)

out=$(notes "${wide[@]}")
for want in "database egress (port 27017)" "external Redis/Sentinel egress" \
  "email relay database egress" "format-migration hook database egress" \
  "format-migration hook Kubernetes API egress"; do
  grep -qF "$want" <<<"$out" || fail "NOTES missing fallback: $want"
done
grep -qF "networkPolicy.strict=true" <<<"$out" || fail "NOTES missing strict hint"

out=$(notes "${wide[@]}" "${all_narrow[@]}")
! grep -qF "fallbacks in effect" <<<"$out" || fail "NOTES list fallbacks although every CIDR is set"

out=$(notes "${wide[@]}" "${all_narrow[@]}" --set networkPolicy.enabled=false)
! grep -qF "fallbacks in effect" <<<"$out" || fail "NOTES list fallbacks with networkPolicy disabled"

# Each unset value must fail strict mode on its own, naming that value.
expect_strict_fail() {
  local setting=$1; shift
  local err
  if err=$(helm template t "$chart" "${base[@]}" "${wide[@]}" "$@" --set networkPolicy.strict=true 2>&1); then
    fail "strict render succeeded without ${setting}"
  fi
  grep -qF "networkPolicy.strict" <<<"$err" && grep -qF "$setting is unset" <<<"$err" ||
    fail "strict failure for ${setting} did not name it: ${err}"
}
for setting in networkPolicy.database.cidrs networkPolicy.redis.cidrs \
  emailGateway.relay.db.networkPolicyCIDRs formatMigrations.networkPolicy.databaseCIDRs \
  formatMigrations.networkPolicy.kubernetesApiTargets; do
  args=()
  while IFS= read -r a; do args+=("$a"); done < <(narrow_args "$setting")
  expect_strict_fail "$setting" "${args[@]}"
done

helm template t "$chart" "${base[@]}" "${wide[@]}" "${all_narrow[@]}" --set networkPolicy.strict=true >/dev/null ||
  fail "strict render failed although every CIDR is set"

err=$(helm template t "$chart" "${base[@]}" "${wide[@]}" --set networkPolicy.strict=true --set networkPolicy.enabled=false 2>&1) &&
  fail "strict with networkPolicy disabled rendered"
grep -qF "requires networkPolicy.enabled=true" <<<"$err" || fail "strict with networkPolicy disabled: ${err}"

helm template t "$chart" "${base[@]}" "${wide[@]}" >/dev/null || fail "non-strict default render failed"
echo "network-policy-strict: ok"
