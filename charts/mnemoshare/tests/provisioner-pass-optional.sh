#!/usr/bin/env bash
# With mtls.caProvider.existingSecret, CA_SMALLSTEP_PROVISIONER_PASS reads provisioner-pass as an
# optional secretKeyRef (a Secret without it must not block pod start) and
# CA_SMALLSTEP_PROVISIONER_KEY stays required.
set -euo pipefail

chart=${1:-charts/mnemoshare}
helm template t "$chart" \
  --set customerId=ci-test \
  --set mongodb.external.uri=mongodb://t:t@l:27017/t \
  --set s3.bucket=b --set s3.accessKey=k --set s3.secretKey=s \
  --set-string jwt.ecPrivateKey=ec --set encryption.key=test-encryption-key-exactly-32by \
  --set license.key=lk \
  --set network.trustedProxyCIDRs=10.0.0.0/8 \
  --set redis.mode=inCluster --set redis.password=x \
  --set mtls.enabled=true --set mtls.caProvider.existingSecret=ca-creds |
python3 -c '
import sys, yaml
refs = {}
for d in yaml.safe_load_all(sys.stdin):
    if not d or d["kind"] not in ("Deployment", "StatefulSet"):
        continue
    for c in d["spec"]["template"]["spec"].get("containers", []):
        for e in c.get("env", []):
            r = e.get("valueFrom", {}).get("secretKeyRef")
            if e["name"] in ("CA_SMALLSTEP_PROVISIONER_PASS", "CA_SMALLSTEP_PROVISIONER_KEY") and r:
                refs.setdefault(e["name"], []).append(r)
errs = []
for name, want_key, want_optional in (
    ("CA_SMALLSTEP_PROVISIONER_PASS", "provisioner-pass", True),
    ("CA_SMALLSTEP_PROVISIONER_KEY", "provisioner-key", False),
):
    rs = refs.get(name, [])
    if not rs:
        errs.append(f"{name}: no secretKeyRef rendered")
    for r in rs:
        if r.get("key") != want_key or r.get("name") != "ca-creds":
            errs.append(f"{name}: unexpected ref {r}")
        got = bool(r.get("optional", False))
        if got != want_optional:
            errs.append(f"{name}: optional must be {want_optional}, got {got}")
if errs:
    sys.exit("provisioner-pass-optional: " + "; ".join(errs))
print("provisioner-pass-optional: ok")
'
