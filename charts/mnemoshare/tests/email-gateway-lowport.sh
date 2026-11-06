#!/usr/bin/env bash
# The email gateway must be able to bind port 25 as a non-root, capability-dropped
# container, and the sysctl that allows it must stay confined to the gateway pod.
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
fail() { echo "email-gateway-lowport: $*" >&2; exit 1; }
docs() { helm template t "$chart" "${base[@]}" "$@" | python3 -c 'import sys,yaml,json; print(json.dumps([d for d in yaml.safe_load_all(sys.stdin) if d]))'; }

check() {
  python3 - "$1" "$2" <<'PY'
import json, sys
docs = json.loads(sys.argv[1]); want = sys.argv[2]
LOW = {"name": "net.ipv4.ip_unprivileged_port_start", "value": "0"}
deps = [d for d in docs if d["kind"] in ("Deployment", "StatefulSet")]
gw = [d for d in deps if d["metadata"]["name"].endswith("-email-gateway")]
assert len(gw) == 1, "expected one email-gateway Deployment"
for d in deps:
    sysctls = d["spec"]["template"]["spec"].get("securityContext") or {}
    sysctls = sysctls.get("sysctls", [])
    if d is gw[0]:
        continue
    assert LOW not in sysctls, f"{d['metadata']['name']} must not get the low-port sysctl"
gw_sc = gw[0]["spec"]["template"]["spec"]["securityContext"]
sysctls = gw_sc.get("sysctls", [])
names = [x["name"] for x in sysctls]
assert names.count(LOW["name"]) == 1, f"gateway sysctls {sysctls} must carry the low-port sysctl once"
if want == "opLow":
    assert LOW in sysctls, "operator value above the listener port must become 0 on the gateway"
    other = [d for d in deps if d["metadata"]["name"] in ("t-mnemoshare", "t-mnemoshare-workflow-worker")]
    assert other and all({"name": LOW["name"], "value": "1024"} in (d["spec"]["template"]["spec"].get("securityContext") or {}).get("sysctls", []) for d in other), "other pods must keep the operator value"
elif want == "keep20":
    assert {"name": LOW["name"], "value": "20"} in sysctls, "value at or below the listener port must be kept"
else:
    assert LOW in sysctls, sysctls
if want != "nullpsc":
    assert gw_sc["fsGroup"] == 1000, "gateway lost fsGroup"
if want == "extra":
    assert {"name": "net.core.somaxconn", "value": "1024"} in sysctls, "operator sysctl dropped"
ports = {p["name"]: p["containerPort"] for p in gw[0]["spec"]["template"]["spec"]["containers"][0]["ports"]}
assert ports["smtp"] == 25, ports
svc = next(d for d in docs if d["kind"] == "Service" and d["metadata"]["name"].endswith("-email-gateway"))
assert svc["spec"]["ports"][0]["targetPort"] == "smtp" and svc["spec"]["ports"][0]["port"] == 25
PY
}

check "$(docs --set emailGateway.listenPorts=25:starttls)" plain || fail "25:starttls"
check "$(docs --set-string "emailGateway.listenPorts=25:starttls\\,587:starttls")" plain || fail "25 and 587"
check "$(docs --set emailGateway.listenPorts=25:starttls \
  --set 'podSecurityContext.sysctls[0].name=net.core.somaxconn' \
  --set-string 'podSecurityContext.sysctls[0].value=1024')" extra || fail "operator sysctl"

check "$(docs --set podSecurityContext=null --set emailGateway.listenPorts=25:starttls)" nullpsc || fail "null podSecurityContext"
check "$(docs --set 'podSecurityContext.sysctls[0].name=net.ipv4.ip_unprivileged_port_start' \
  --set-string 'podSecurityContext.sysctls[0].value=1024')" opLow || fail "operator low-port sysctl"
check "$(docs --set 'podSecurityContext.sysctls[0].name=net.ipv4.ip_unprivileged_port_start' \
  --set-string 'podSecurityContext.sysctls[0].value=20')" keep20 || fail "operator value 20 kept"
set +e; out=$(helm template t "$chart" "${base[@]}" --set 'podSecurityContext.sysctls[0].name=net.ipv4.ip_unprivileged_port_start' \
  --set-string 'podSecurityContext.sysctls[0].value=abc' 2>&1); st=$?; set -e
[ $st -ne 0 ] && echo "$out" | grep -q "podSecurityContext.sysctls" || fail "non-integer sysctl should fail"
check "$(docs --set emailGateway.listenPorts=25)" plain || fail "bare port"
check "$(docs --set-string "emailGateway.listenPorts=25\\,587")" plain || fail "bare ports"
check "$(docs --set-string "emailGateway.listenPorts=25:starttls\\,")" plain || fail "trailing comma"
tls=(--set emailGateway.tls.existingSecret=gw-tls)
check "$(docs "${tls[@]}" --set-string "emailGateway.listenPorts=25:starttls\\,")" plain || fail "TLS trailing comma"
# Without a TLS secret listenPorts is ignored, so even an invalid value renders.
check "$(docs --set emailGateway.listenPorts=2525:starttls)" plain || fail "non-TLS custom listenPorts"
check "$(docs --set emailGateway.listenPorts=bogus)" plain || fail "non-TLS ignored listenPorts"

for ports in 2525:starttls 587:starttls bogus 25:nope 70000:plain 0:plain 025:plain "25:plain\\,25:starttls" "25:plain\\,0587:tls"; do
  set +e; out=$(helm template t "$chart" "${base[@]}" "${tls[@]}" --set-string "emailGateway.listenPorts=$ports" 2>&1); st=$?; set -e
  [ $st -ne 0 ] && echo "$out" | grep -q "emailGateway.listenPorts" || fail "TLS listenPorts=$ports should fail with a listenPorts message"
done
echo "email-gateway-lowport: ok"
