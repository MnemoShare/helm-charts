#!/usr/bin/env bash
# Which components may reach in-cluster ClamAV (ICAP) and Redis. That the policies select real
# pods is checked generically by hack/check-render.py (render-matrix.sh).
set -euo pipefail

chart=${1:-charts/mnemoshare}
base=(
  --set customerId=ci-test
  --set mongodb.external.uri=mongodb://t:t@l:27017/t
  --set s3.bucket=b --set s3.accessKey=k --set s3.secretKey=s
  --set-string jwt.ecPrivateKey=ec --set encryption.key=test-encryption-key-exactly-32by
  --set license.key=lk --set appUrl=https://t.example.com
  --set network.trustedProxyCIDRs=10.0.0.0/8
  --set clamav.enabled=true --set redis.mode=inCluster --set redis.password=x
)
fail() { echo "clamav-networkpolicy: $*" >&2; exit 1; }

# docs <extra helm args...>: rendered manifests as a JSON list
docs() { helm template t "$chart" "${base[@]}" "$@" | python3 -c 'import sys,yaml,json; print(json.dumps([d for d in yaml.safe_load_all(sys.stdin) if d]))'; }
check() {
  python3 - "$1" "$2" <<'PY'
import json, sys
docs = json.loads(sys.argv[1]); want = set(sys.argv[2].split(","))
pols = {d["metadata"]["name"]: d for d in docs if d["kind"] == "NetworkPolicy"}
pod_labels = next(d["spec"]["template"]["metadata"]["labels"] for d in docs
                  if d["kind"] == "Deployment" and d["metadata"]["name"].endswith("-clamav"))
cp = pols["t-mnemoshare-clamav"]
sel = cp["spec"]["podSelector"]["matchLabels"]
assert sel == pod_labels, f"clamav policy selector {sel} does not match pod labels {pod_labels}"
frm = cp["spec"]["ingress"][0]["from"][0]["podSelector"]
got = set(frm["matchExpressions"][0]["values"])
assert got == want, f"ICAP ingress components {sorted(got)} != {sorted(want)}"
rp = pols["t-mnemoshare-redis"]
rgot = set(rp["spec"]["ingress"][0]["from"][0]["podSelector"]["matchExpressions"][0]["values"])
rwant = want & {"api", "workflow-worker", "ices"}
assert rgot == rwant, f"Redis ingress components {sorted(rgot)} != {sorted(rwant)}"
api = pols["t-mnemoshare-api-egress"]
icap = [r for r in api["spec"]["egress"] if r.get("ports") == [{"protocol": "TCP", "port": 1344}]]
assert icap, "api egress has no ICAP rule"
to = icap[0]["to"][0]["podSelector"]["matchLabels"]
assert to == pod_labels, f"api ICAP egress selector {to} does not match pod labels {pod_labels}"
PY
}
check "$(docs)" api || fail "default shape"
check "$(docs --set workflowWorker.enabled=true --set ices.enabled=true)" api,workflow-worker,ices || fail "worker+ices"
check "$(docs --set emailGateway.enabled=true --set inboundGateway.enabled=true --set inboundGateway.relayHost=p:25)" api,email-gateway,inbound-gateway || fail "gateways"
echo "clamav-networkpolicy: ok"
