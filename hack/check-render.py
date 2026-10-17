#!/usr/bin/env python3
"""Render guards over `helm template` output (stdin or file arg).

1. Every NetworkPolicy egress rule must list explicit ports, each with a `port`
   (an omitted ports list or a protocol-only entry means every port).
2. Any egress rule to a public ipBlock (0.0.0.0/0 or any non-RFC1918 CIDR) is
   covered by (1); reported separately for clarity.
3. An endPort range must never target a /0 ipBlock.
4. Referenced ServiceAccounts are rendered.
5. Every app pod (component api, workflow-worker, ices, mcp, email-gateway,
   inbound-gateway, sftp-gateway) sets automountServiceAccountToken: false, and
   no Role/RoleBinding other than the format-migration hook's is rendered.
"""
import sys
import yaml

APP_COMPONENTS = {"api", "workflow-worker", "ices", "mcp", "email-gateway",
                  "inbound-gateway", "sftp-gateway"}
errors = []
docs = [d for d in yaml.safe_load_all(open(sys.argv[1]) if len(sys.argv) > 1 else sys.stdin) if d]

for d in docs:
    kind, name = d.get("kind"), d.get("metadata", {}).get("name")
    comp_label = d.get("metadata", {}).get("labels", {}).get("app.kubernetes.io/component", "")
    if kind in ("Role", "RoleBinding") and not comp_label.startswith("format-migration"):
        errors.append(f"{kind}/{name}: only the format-migration hook may render Kubernetes RBAC")
    if kind == "NetworkPolicy":
        for i, rule in enumerate(d["spec"].get("egress") or []):
            ports = rule.get("ports") or []
            public = any("ipBlock" in p and not p["ipBlock"]["cidr"].startswith(("10.", "172.16.", "192.168."))
                         for p in rule.get("to") or [])
            for p in ports:
                if "endPort" in p and any(
                        "ipBlock" in t and t["ipBlock"]["cidr"].endswith("/0") for t in rule.get("to") or []):
                    errors.append(f"NetworkPolicy/{name} egress[{i}]: endPort range paired with a public-any ipBlock")
            if not ports or any("port" not in p for p in ports):
                errors.append(f"NetworkPolicy/{name} egress[{i}]: "
                              f"{'public ipBlock rule' if public else 'rule'} lacks explicit ports")
    if kind in ("Deployment", "StatefulSet", "Job", "CronJob"):
        tpl = d["spec"].get("jobTemplate", {}).get("spec", {}).get("template") or d["spec"]["template"]
        comp = tpl["metadata"].get("labels", {}).get("app.kubernetes.io/component")
        if comp in APP_COMPONENTS and tpl["spec"].get("automountServiceAccountToken") is not False:
            errors.append(f"{kind}/{name} (component={comp}): automountServiceAccountToken is not false")

sas = {d["metadata"]["name"] for d in docs if d.get("kind") == "ServiceAccount"}
for d in docs:
    if d.get("kind") in ("Deployment", "StatefulSet", "Job"):
        sa = d["spec"]["template"]["spec"].get("serviceAccountName")
        if sa and sa not in sas and not sa.endswith("-format-migration"):
            errors.append(f"{d['kind']}/{d['metadata']['name']}: ServiceAccount {sa} is referenced but not rendered")

if errors:
    print("\n".join("FAIL: " + e for e in errors))
    sys.exit(1)
print(f"ok: {sum(1 for d in docs if d.get('kind') == 'NetworkPolicy')} NetworkPolicies checked")
