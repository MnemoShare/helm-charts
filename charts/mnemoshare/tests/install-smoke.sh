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
trap 'kubectl --context "$ctx" delete namespace "$ns" "$ns-retry" --wait=false >/dev/null 2>&1 || true' EXIT

h install smoke "$chart" "${min[@]}" --dry-run=server >/dev/null || fail "dry-run=server failed"
h install smoke "$chart" "${min[@]}" --dry-run=client >/dev/null || fail "dry-run=client failed"
h install smoke "$chart" "${min[@]}" --set commonLabels.flag=true --set commonLabels.tier=3 --dry-run=server >/dev/null \
  || fail "non-string commonLabels rejected by the API server"

# The default image lacks mnemoshare-migrate until the 1.x default-image ticket lands.
h install smoke "$chart" "${min[@]}" --set formatMigrations.mode=disabled -n "$ns" --create-namespace --timeout 3m >/dev/null || fail "default install did not complete"
[ "$(h status smoke -n "$ns" -o json | jq -r .info.status)" = deployed ] || fail "release is not deployed"

# A pre-install hook that cannot finish fails the first install before the chart Secret exists.
h install retry "$chart" "${min[@]}" --set formatMigrations.mode=automatic -n "$ns-retry" --create-namespace --timeout 30s >/dev/null 2>&1 \
  && fail "automatic migration hook unexpectedly succeeded"
[ "$(h status retry -n "$ns-retry" -o json | jq -r .info.status)" = failed ] || fail "first install did not fail"
h upgrade --install retry "$chart" "${min[@]}" --set formatMigrations.mode=disabled -n "$ns-retry" --timeout 3m >/dev/null || fail "retry of a failed first install was refused"
[ "$(h status retry -n "$ns-retry" -o json | jq -r .info.status)" = deployed ] || fail "retried release is not deployed"
echo "install-smoke: ok"
