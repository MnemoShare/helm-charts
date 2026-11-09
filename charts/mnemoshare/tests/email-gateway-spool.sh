#!/usr/bin/env bash
# Gateway mode keeps an encrypted deferral spool on a ReadWriteOnce PVC: one replica, Recreate,
# read-only root filesystem with the mount as the only writable path, and a claim helm uninstall keeps.
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
fail() { echo "email-gateway-spool: $*" >&2; exit 1; }
docs() { helm template t "$chart" "${base[@]}" "$@" | python3 -c 'import sys,yaml,json; print(json.dumps([d for d in yaml.safe_load_all(sys.stdin) if d]))'; }

check() {
  python3 - "$1" "$2" "${3:-}" <<'PY'
import json, sys
docs = json.loads(sys.argv[1]); want = sys.argv[2]; extra = sys.argv[3]
gw = [d for d in docs if d["kind"] == "Deployment" and d["metadata"]["name"].endswith("-email-gateway")]
assert len(gw) == 1, "expected one email-gateway Deployment"
spec = gw[0]["spec"]
pod = spec["template"]["spec"]
c = pod["containers"][0]
env = {e["name"]: e.get("value") for e in c["env"]}
mounts = {m["name"]: m["mountPath"] for m in c.get("volumeMounts", [])}
vols = {v["name"]: v for v in pod.get("volumes", [])}
pvcs = [d for d in docs if d["kind"] == "PersistentVolumeClaim" and d["metadata"]["name"].endswith("-gateway-spool")]
assert c["securityContext"]["readOnlyRootFilesystem"] is True, "root filesystem must stay read-only"
if want == "on":
    assert spec["strategy"]["type"] == "Recreate", spec.get("strategy")
    assert spec["replicas"] == 1
    psc = pod["securityContext"]
    assert psc["fsGroup"] == 1000, psc
    assert psc["fsGroupChangePolicy"] == "OnRootMismatch", psc
    assert env["GATEWAY_SPOOL_DIR"] == "/var/spool/mnemo-gateway", env.get("GATEWAY_SPOOL_DIR")
    assert mounts["gateway-spool"] == "/var/spool/mnemo-gateway", mounts
    assert "ENCRYPTION_KEY" in env
    claim = vols["gateway-spool"]["persistentVolumeClaim"]["claimName"]
    if extra == "existing":
        assert claim == "my-claim", claim
        assert not pvcs, "existingClaim must not render a PVC"
    else:
        assert len(pvcs) == 1, "expected one spool PVC"
        p = pvcs[0]
        assert p["metadata"]["name"] == claim
        assert p["metadata"]["annotations"]["helm.sh/resource-policy"] == "keep"
        assert p["spec"]["accessModes"] == ["ReadWriteOnce"]
        assert p["spec"]["resources"]["requests"]["storage"] == ("20Gi" if extra == "sized" else "5Gi")
        if extra == "sized":
            assert p["spec"]["storageClassName"] == "fast"
else:
    assert "GATEWAY_SPOOL_DIR" not in env, "opt-out must not export GATEWAY_SPOOL_DIR"
    assert "gateway-spool" not in mounts and "gateway-spool" not in vols
    assert not pvcs, "opt-out must not render a spool PVC"
    assert "strategy" not in spec, spec.get("strategy")
    if extra == "two":
        assert spec["replicas"] == 2
PY
}

check "$(docs)" on || fail "default gateway mode"
check "$(docs --set emailGateway.spool.persistence.size=20Gi --set emailGateway.spool.persistence.storageClass=fast)" on sized || fail "size and storageClass"
check "$(docs --set emailGateway.spool.persistence.existingClaim=my-claim)" on existing || fail "existingClaim"
check "$(docs --set emailGateway.spool=null)" on || fail "missing spool key must render the defaults (--reuse-values)"
check "$(docs --set emailGateway.spool.persistence.enabled=false --set emailGateway.spool.persistence.existingClaim=my-claim)" on existing || fail "persistence.enabled=false with existingClaim"
check "$(docs --set emailGateway.spool.enabled=false)" off || fail "opt-out"
check "$(docs --set emailGateway.spool.enabled=false --set emailGateway.replicas=2)" off two || fail "opt-out with 2 replicas"

if helm template t "$chart" "${base[@]}" --set emailGateway.replicas=2 >/dev/null 2>&1; then
  fail "replicas=2 with the spool on must fail to render"
fi
if helm template t "$chart" "${base[@]}" --set emailGateway.replicas=0 >/dev/null 2>&1; then
  fail "replicas=0 with the spool on must fail to render"
fi

for bad in "emailGateway.spool.persistence.enabled=false" "emailGateway.spool.dir=/var/spool/other" "emailGateway.spool.persistence.size=" "podSecurityContext.fsGroup=null"; do
  if helm template t "$chart" "${base[@]}" --set "$bad" >/dev/null 2>&1; then
    fail "$bad with the spool on must fail to render"
  fi
done
check "$(docs --set emailGateway.spool.enabled=false --set podSecurityContext.fsGroup=null)" off || fail "opt-out needs no fsGroup"

relay=(--set emailGateway.mode=relay --set emailGateway.relay.allowedSourceCIDRs=10.0.0.0/8)
python3 - "$(docs "${relay[@]}")" <<'PY' || fail "relay mode must not get the gateway spool"
import json, sys
docs = json.loads(sys.argv[1])
gw = next(d for d in docs if d["kind"] == "Deployment" and d["metadata"]["name"].endswith("-email-gateway"))
env = {e["name"] for e in gw["spec"]["template"]["spec"]["containers"][0]["env"]}
assert "GATEWAY_SPOOL_DIR" not in env
assert not [d for d in docs if d["kind"] == "PersistentVolumeClaim" and d["metadata"]["name"].endswith("-gateway-spool")]
PY

for m in relay inbound-relay; do
  python3 - "$(docs --set emailGateway.mode=$m --set emailGateway.relay.allowedSourceCIDRs=10.0.0.0/8)" <<'PY' || fail "$m mode must not get the gateway spool"
import json, sys
docs = json.loads(sys.argv[1])
gw = next(d for d in docs if d["kind"] == "Deployment" and d["metadata"]["name"].endswith("-email-gateway"))
assert "strategy" not in gw["spec"], gw["spec"].get("strategy")
assert "fsGroupChangePolicy" not in gw["spec"]["template"]["spec"]["securityContext"]
assert not [d for d in docs if d["kind"] == "PersistentVolumeClaim" and d["metadata"]["name"].endswith("-gateway-spool")]
PY
done

echo "email-gateway-spool: ok"
