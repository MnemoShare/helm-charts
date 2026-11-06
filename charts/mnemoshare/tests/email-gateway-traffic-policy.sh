#!/usr/bin/env bash
# The gateway's source-IP allowlist needs the real client IP, so the Service must be able to
# request externalTrafficPolicy: Local and restrict source ranges.
set -euo pipefail

chart=${1:-charts/mnemoshare}
base=(
  --set customerId=ci-test
  --set mongodb.external.uri=mongodb://t:t@l:27017/t
  --set s3.bucket=b --set s3.accessKey=k --set s3.secretKey=s
  --set-string jwt.ecPrivateKey=ec --set encryption.key=test-encryption-key-exactly-32by
  --set license.key=lk --set appUrl=https://t.example.com
  --set network.trustedProxyCIDRs=10.0.0.0/8
  --set emailGateway.enabled=true --set workflowWorker.enabled=true
  --set redis.mode=inCluster --set redis.password=x
)
fail() { echo "email-gateway-traffic-policy: $*" >&2; exit 1; }
svc() {
  helm template t "$chart" "${base[@]}" "$@" | python3 -c '
import sys, yaml, json
d = [d for d in yaml.safe_load_all(sys.stdin) if d and d["kind"] == "Service" and d["metadata"]["name"].endswith("-email-gateway")]
assert len(d) == 1, "expected one email-gateway Service"
print(json.dumps(d[0]["spec"]))'
}
field() { python3 -c 'import sys,json; print(json.dumps(json.load(sys.stdin).get(sys.argv[1])))' "$1"; }

[ "$(svc | field externalTrafficPolicy)" = null ] || fail "unset must render no externalTrafficPolicy"
[ "$(svc | field loadBalancerSourceRanges)" = null ] || fail "unset must render no source ranges"
[ "$(svc --set emailGateway.service.externalTrafficPolicy=Local | field externalTrafficPolicy)" = '"Local"' ] || fail "Local on LoadBalancer"
[ "$(svc --set emailGateway.service.externalTrafficPolicy=Cluster | field externalTrafficPolicy)" = '"Cluster"' ] || fail "Cluster on LoadBalancer"
[ "$(svc --set emailGateway.service.type=NodePort --set emailGateway.service.externalTrafficPolicy=Local | field externalTrafficPolicy)" = '"Local"' ] || fail "Local on NodePort"
[ "$(svc --set emailGateway.service.type=ClusterIP --set emailGateway.service.externalTrafficPolicy=Local | field externalTrafficPolicy)" = null ] || fail "ClusterIP must not render externalTrafficPolicy"
[ "$(svc --set 'emailGateway.service.loadBalancerSourceRanges[0]=203.0.113.0/24' --set 'emailGateway.service.loadBalancerSourceRanges[1]=198.51.100.7/32' | field loadBalancerSourceRanges)" = '["203.0.113.0/24", "198.51.100.7/32"]' ] || fail "source ranges"

set +e; out=$(helm template t "$chart" "${base[@]}" --set emailGateway.service.externalTrafficPolicy=local 2>&1); st=$?; set -e
[ $st -ne 0 ] && echo "$out" | grep -q "emailGateway.service.externalTrafficPolicy" || fail "invalid value must fail naming the key"
set +e; out=$(helm template t "$chart" "${base[@]}" --set emailGateway.service.type=ClusterIP --set 'emailGateway.service.loadBalancerSourceRanges[0]=203.0.113.0/24' 2>&1); st=$?; set -e
[ $st -ne 0 ] && echo "$out" | grep -q "emailGateway.service.loadBalancerSourceRanges" || fail "source ranges on ClusterIP must fail naming the key"
echo "email-gateway-traffic-policy: ok"
