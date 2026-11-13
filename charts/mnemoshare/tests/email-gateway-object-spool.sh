#!/usr/bin/env bash
# Gateway mode spools to the database and object storage: no volume, no Recreate, any replica count,
# database and storage env plus egress. Relay modes keep their relay spool and get none of it.
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
fail() { echo "email-gateway-object-spool: $*" >&2; exit 1; }
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
env = {e["name"]: e for e in c["env"]}
mounts = {m["name"] for m in c.get("volumeMounts", [])}
vols = {v["name"] for v in pod.get("volumes", [])}
pvcs = [d["metadata"]["name"] for d in docs if d["kind"] == "PersistentVolumeClaim"]
object_env = ["OUTBOUND_SPOOL_BACKEND", "DB_DRIVER", "MONGODB_URI", "MONGODB_DATABASE",
              "S3_ENDPOINT", "S3_ACCESS_KEY", "S3_SECRET_KEY", "S3_BUCKET", "S3_USE_SSL"]
assert c["securityContext"]["readOnlyRootFilesystem"] is True, "root filesystem must stay read-only"
assert "GATEWAY_SPOOL_DIR" not in env, "the volume spool is gone"
assert not [p for p in pvcs if p.endswith("-gateway-spool")], pvcs
assert "gateway-spool" not in mounts and "gateway-spool" not in vols
assert "strategy" not in spec, spec.get("strategy")
assert "fsGroupChangePolicy" not in pod["securityContext"], pod["securityContext"]
if want == "gateway":
    assert env["OUTBOUND_SPOOL_BACKEND"]["value"] == "object", env.get("OUTBOUND_SPOOL_BACKEND")
    assert env["DB_DRIVER"]["value"] == "mongodb"
    assert env["MONGODB_URI"]["valueFrom"]["secretKeyRef"]["key"] == "mongodb-uri"
    assert "MONGODB_DATABASE" in env
    for n in ("S3_ENDPOINT", "S3_BUCKET", "S3_USE_SSL"):
        assert n in env, n
    assert env["S3_ACCESS_KEY"]["valueFrom"]["secretKeyRef"]["key"] == "s3-access-key"
    assert env["S3_SECRET_KEY"]["valueFrom"]["secretKeyRef"]["key"] == "s3-secret-key"
    assert env["ENCRYPTION_KEY"]["valueFrom"]["secretKeyRef"]["key"] == "encryption-key"
    assert spec["replicas"] == (2 if extra == "two" else 1), spec["replicas"]
else:
    present = [n for n in object_env if n in env]
    assert not present, "relay mode must not get the object spool env: %s" % present
    assert "RELAY_SPOOL_DIR" in env
    assert "relay-spool" in mounts and "relay-spool" in vols
    assert any(p.endswith("-relay-spool") for p in pvcs), pvcs

if want == "gateway":
    np = [d for d in docs if d["kind"] == "NetworkPolicy" and d["metadata"]["name"].endswith("-email-gateway")]
    assert len(np) == 1, "expected one email-gateway NetworkPolicy"
    ports = set()
    for rule in np[0]["spec"]["egress"]:
        assert rule.get("ports"), "every egress rule needs explicit ports: %s" % rule
        for p in rule["ports"]:
            ports.add(p["port"])
    assert 27017 in ports, "database egress missing: %s" % sorted(ports)
    assert 443 in ports and 9000 in ports, "storage egress missing: %s" % sorted(ports)
PY
}

check "$(docs)" gateway || fail "default gateway mode"
check "$(docs --set emailGateway.replicas=2)" gateway two || fail "replicas=2"

pg=$(docs --set database.driver=postgres --set-string postgres.dsn=postgres://u:p@h:5432/d)
python3 - "$pg" <<'PY' || fail "postgres gateway mode"
import json, sys
docs = json.loads(sys.argv[1])
gw = next(d for d in docs if d["kind"] == "Deployment" and d["metadata"]["name"].endswith("-email-gateway"))
env = {e["name"]: e for e in gw["spec"]["template"]["spec"]["containers"][0]["env"]}
assert env["DB_DRIVER"]["value"] == "postgres"
assert env["POSTGRES_DSN"]["valueFrom"]["secretKeyRef"]["key"] == "postgres-dsn"
assert "MONGODB_URI" not in env
np = next(d for d in docs if d["kind"] == "NetworkPolicy" and d["metadata"]["name"].endswith("-email-gateway"))
assert 5432 in {p["port"] for r in np["spec"]["egress"] for p in r["ports"]}
PY

minio=$(docs --set minio.enabled=true --set emailGateway.mode=gateway)
python3 - "$minio" <<'PY' || fail "bundled MinIO gateway mode"
import json, sys
docs = json.loads(sys.argv[1])
gw = next(d for d in docs if d["kind"] == "Deployment" and d["metadata"]["name"].endswith("-email-gateway"))
env = {e["name"]: e for e in gw["spec"]["template"]["spec"]["containers"][0]["env"]}
assert env["OUTBOUND_SPOOL_BACKEND"]["value"] == "object"
assert env["S3_ENDPOINT"]["value"].endswith("-minio:9000"), env["S3_ENDPOINT"]
assert env["S3_USE_SSL"]["value"] == "false"
assert env["S3_ACCESS_KEY"]["valueFrom"]["secretKeyRef"]["key"] == "rootUser"
assert env["S3_SECRET_KEY"]["valueFrom"]["secretKeyRef"]["key"] == "rootPassword"
np = next(d for d in docs if d["kind"] == "NetworkPolicy" and d["metadata"]["name"].endswith("-email-gateway"))
assert 9000 in {p["port"] for r in np["spec"]["egress"] for p in r["ports"]}
PY

old_key() {
  python3 - "$1" "$2" <<'PY'
import json, sys
docs = json.loads(sys.argv[1]); want = sys.argv[2]
def env(suffix):
    d = next(d for d in docs if d["kind"] == "Deployment" and d["metadata"]["name"].endswith(suffix))
    return {e["name"]: e for e in d["spec"]["template"]["spec"]["containers"][0]["env"]}
gw = env("-email-gateway")
if want == "unset":
    assert "OLD_ENCRYPTION_KEY" not in gw, "OLD_ENCRYPTION_KEY must be absent without encryption.oldKey"
else:
    ref = gw["OLD_ENCRYPTION_KEY"]["valueFrom"]["secretKeyRef"]
    api = [d for d in docs if d["kind"] == "Deployment" and d["metadata"]["name"] == "t-mnemoshare"]
    assert len(api) == 1, "expected the API Deployment"
    want_ref = next(e for e in api[0]["spec"]["template"]["spec"]["containers"][0]["env"] if e["name"] == "OLD_ENCRYPTION_KEY")["valueFrom"]["secretKeyRef"]
    assert ref == want_ref, (ref, want_ref)
    assert ref["key"] == "old-encryption-key", ref
    if want == "existing":
        assert ref["name"] == "my-enc", ref
    else:
        sec = [d for d in docs if d["kind"] == "Secret" and d["metadata"]["name"] == ref["name"]]
        assert len(sec) == 1, "expected the chart Secret " + ref["name"]
        assert "old-encryption-key" in {**sec[0].get("data", {}), **sec[0].get("stringData", {})}, "chart Secret lacks old-encryption-key"
PY
}
for m in gateway relay inbound-relay; do
  mode=(--set emailGateway.mode=$m --set emailGateway.relay.allowedSourceCIDRs=10.0.0.0/8)
  old_key "$(docs "${mode[@]}")" unset || fail "$m: OLD_ENCRYPTION_KEY must be absent without encryption.oldKey"
  old_key "$(docs "${mode[@]}" --set encryption.oldKey=old-encryption-key-exactly-32by)" set || fail "$m: OLD_ENCRYPTION_KEY must match the API Deployment"
  old_key "$(docs "${mode[@]}" --set encryption.oldKey=old-encryption-key-exactly-32by --set existingSecrets.encryption=my-enc)" existing || fail "$m: OLD_ENCRYPTION_KEY must follow existingSecrets.encryption"
done

for m in relay inbound-relay; do
  check "$(docs --set emailGateway.mode=$m --set emailGateway.relay.allowedSourceCIDRs=10.0.0.0/8)" relay || fail "$m mode"
  python3 - "$(docs --set emailGateway.mode=$m --set emailGateway.relay.allowedSourceCIDRs=10.0.0.0/8)" <<'PY' || fail "$m mode must have no database or storage egress"
import json, sys
docs = json.loads(sys.argv[1])
np = next(d for d in docs if d["kind"] == "NetworkPolicy" and d["metadata"]["name"].endswith("-email-gateway"))
ports = {p["port"] for r in np["spec"]["egress"] for p in r["ports"]}
assert not ports & {27017, 9000}, sorted(ports)
PY
done

expect_fail() {
  local want=$1; shift
  local out
  if out=$(helm template t "$chart" "${base[@]}" "$@" 2>&1); then
    fail "$* must fail to render"
  fi
  grep -q "$want" <<<"$out" || fail "$* failed with the wrong message: $out"
}
expect_fail "emailGateway.mode=gateway" --set workflowWorker.enabled=false --set database.driver=sqlite
expect_fail "emailGateway.maxRecipients" --set emailGateway.maxRecipients=101
expect_fail "emailGateway.maxRecipients" --set emailGateway.maxRecipients=0
expect_fail "mongodb.external.database" --set mongodb.external.database=
helm template t "$chart" "${base[@]}" --set emailGateway.maxRecipients=100 >/dev/null || fail "maxRecipients=100 must render"

echo "email-gateway-object-spool: ok"
