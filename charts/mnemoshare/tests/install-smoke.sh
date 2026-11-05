#!/usr/bin/env bash
# A first install (migrations disabled) reaches deployed with hooks on, a
# retried failed first install recovers, dry-runs succeed, and commonLabels are
# always strings. Needs a disposable cluster: refuses any context not named
# kind-* unless INSTALL_SMOKE_CONTEXT is set to that exact context name.
set -euo pipefail

chart=${1:-charts/mnemoshare}
ctx=$(kubectl config current-context)
case "$ctx" in
  kind-*) ;;
  *) [ "${INSTALL_SMOKE_CONTEXT:-}" = "$ctx" ] || { echo "install-smoke: refusing context '$ctx'" >&2; exit 1; } ;;
esac
fail() { echo "install-smoke: $*" >&2; exit 1; }
h() { helm --kube-context "$ctx" "$@"; }
min=(--set customerId=ci-test --set network.trustedProxyCIDRs=none)
ns=install-smoke-$$
trap 'kubectl --context "$ctx" delete namespace "$ns" "$ns-retry" "$ns-cmretry" "$ns-live" "$ns-stray" "$ns-warm" --wait=false >/dev/null 2>&1 || true' EXIT

h install smoke "$chart" "${min[@]}" --dry-run=server >/dev/null || fail "dry-run=server failed"
h install smoke "$chart" "${min[@]}" --dry-run=client >/dev/null || fail "dry-run=client failed"
h install smoke "$chart" "${min[@]}" --set commonLabels.flag=true --set commonLabels.tier=3 --dry-run=server >/dev/null \
  || fail "non-string commonLabels rejected by the API server"

# The default image lacks mnemoshare-migrate until the 1.x default-image ticket lands.
h install smoke "$chart" "${min[@]}" --set formatMigrations.mode=disabled -n "$ns" --create-namespace --timeout 3m >/dev/null || fail "default install did not complete"
[ "$(h status smoke -n "$ns" -o json | jq -r .info.status)" = deployed ] || fail "release is not deployed"

# An unpullable hook image makes the pre-install hook fail the first install before the chart Secret exists.
broken=(--set formatMigrations.mode=automatic --set formatMigrations.orchestratorImage.repository=registry.invalid/none)
failed_first_install() { # <driver> <release> <namespace>
  HELM_DRIVER=$1 h install "$2" "$chart" "${min[@]}" "${broken[@]}" -n "$3" --create-namespace --timeout 30s >/dev/null 2>&1 \
    && fail "install with an unpullable hook image unexpectedly succeeded ($1)"
  [ "$(HELM_DRIVER=$1 h status "$2" -n "$3" -o json | jq -r .info.status)" = failed ] || fail "first install did not fail ($1)"
  kubectl --context "$ctx" -n "$3" get secret "$2-mnemoshare-secrets" >/dev/null 2>&1 && fail "chart Secret exists after failed first install ($1)"
  return 0
}

# Warm the orchestrator image so a cold node's pull cannot time out the retry's mode-fence hook.
orchestrator=$(helm template w "$chart" "${min[@]}" --set formatMigrations.mode=automatic | sed -n 's/^ *image: "\(docker.io\/alpine\/k8s@[^"]*\)".*/\1/p' | head -1)
[ -n "$orchestrator" ] || fail "orchestrator image not found in the render"
kubectl --context "$ctx" create namespace "$ns-warm" >/dev/null
kubectl --context "$ctx" -n "$ns-warm" run warm --image="$orchestrator" --restart=Never --command -- true >/dev/null
kubectl --context "$ctx" -n "$ns-warm" wait --for=jsonpath='{.status.phase}'=Succeeded pod/warm --timeout=10m >/dev/null || fail "orchestrator image did not pull"

# The retry runs the pre-upgrade mode-fence hook, which may pull the orchestrator image on a cold node.
retry_upgrade() { # <driver> <release> <namespace>
  local out
  out=$(HELM_DRIVER=$1 h upgrade --install "$2" "$chart" "${min[@]}" --set formatMigrations.mode=disabled -n "$3" --timeout 10m 2>&1) || {
    if grep -q "refusing to generate" <<<"$out"; then fail "retry of a failed first install was refused ($1 driver)"; fi
    fail "retry upgrade failed ($1 driver): $out"
  }
}

failed_first_install secret retry "$ns-retry"
retry_upgrade secret retry "$ns-retry"
[ "$(h status retry -n "$ns-retry" -o json | jq -r .info.status)" = deployed ] || fail "retried release is not deployed (secret driver)"

failed_first_install configmap cmretry "$ns-cmretry"
retry_upgrade configmap cmretry "$ns-cmretry"
[ "$(HELM_DRIVER=configmap h status cmretry -n "$ns-cmretry" -o json | jq -r .info.status)" = deployed ] || fail "retried release is not deployed (configmap driver)"

# A deployed release whose chart Secret went missing must never be given new keys, whatever the storage driver.
HELM_DRIVER=configmap h install live "$chart" "${min[@]}" --set formatMigrations.mode=disabled -n "$ns-live" --create-namespace --timeout 3m >/dev/null || fail "configmap-driver install failed"
err=$(HELM_DRIVER=configmap h upgrade live "$chart" "${min[@]}" --set formatMigrations.mode=disabled --set nameOverride=other -n "$ns-live" 2>&1) \
  && fail "configmap-driver upgrade without the chart Secret generated new keys"
grep -q "refusing to generate" <<<"$err" || fail "unexpected configmap-driver upgrade failure: $err"
# A failed record without revision 1 is not a first-install retry, whatever the storage left behind.
failed_first_install secret stray "$ns-stray"
kubectl --context "$ctx" -n "$ns-stray" get secret sh.helm.release.v1.stray.v1 -o json \
  | jq '.metadata.name="sh.helm.release.v1.stray.v3" | .metadata.labels.version="3" | del(.metadata.resourceVersion,.metadata.uid,.metadata.creationTimestamp)' \
  | kubectl --context "$ctx" create -f - >/dev/null
kubectl --context "$ctx" -n "$ns-stray" delete secret sh.helm.release.v1.stray.v1 >/dev/null
err=$(h upgrade stray "$chart" "${min[@]}" --set formatMigrations.mode=disabled -n "$ns-stray" --timeout 10m 2>&1) \
  && fail "upgrade with only a stray non-first failed record generated new keys"
grep -q "refusing to generate" <<<"$err" || fail "unexpected stray-record failure: $err"
echo "install-smoke: ok"
