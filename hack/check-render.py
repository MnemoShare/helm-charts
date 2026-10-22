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
   no Role/RoleBinding other than the format-migration hook's and the sandbox
   runner's is rendered.
6. No container (init or main) invokes sh/bash/busybox/wget/curl/nc/pgrep in
   command/args, probe exec or lifecycle hooks (shell-free runtime, MNS-1549).
   Third-party images that ship their own shell are allowlisted below.
"""
import sys
import yaml

APP_COMPONENTS = {"api", "workflow-worker", "ices", "mcp", "email-gateway",
                  "inbound-gateway", "sftp-gateway"}
SHELL_TOOLS = {"sh", "bash", "ash", "dash", "zsh", "busybox", "wget", "curl", "nc", "ncat", "pgrep"}
# (substring of workload name, container name).
SHELL_ALLOWLIST = {
    # smallstep/step-ca image, not built from our runtime image.
    ("-step-ca", "init-ca"),
}
# Containers on formatMigrations.orchestratorImage (docker.io/alpine/k8s: kubectl + shell, not ours).
SHELL_ALLOWED_IMAGE_PREFIXES = ("docker.io/alpine/k8s",)
errors = []
SANDBOX_COMPONENT = "sandbox-runner"
SANDBOX_ALLOWED = {
    ("batch", "jobs"): {"create", "get", "list", "watch", "patch", "delete"},
    ("networking.k8s.io", "networkpolicies"): {"create", "get", "list", "delete"},
    ("", "pods"): {"get", "list"},
    ("", "pods/log"): {"get"},
}
SANDBOX_EGRESS_PORTS = {53, 443, 6443}


def shell_hits(c):
    probes = [(k, ((c.get(k) or {}).get("exec") or {}).get("command") or []) for k in ("livenessProbe", "readinessProbe", "startupProbe")]
    hooks = [(f"lifecycle.{h}", (((c.get("lifecycle") or {}).get(h) or {}).get("exec") or {}).get("command") or []) for h in ("postStart", "preStop")]
    for where, argv in [("command", (c.get("command") or []) + (c.get("args") or []))] + probes + hooks:
        for a in argv:
            if isinstance(a, str) and a.split("/")[-1] in SHELL_TOOLS:
                yield where, a
docs = [d for d in yaml.safe_load_all(open(sys.argv[1]) if len(sys.argv) > 1 else sys.stdin) if d]

for d in docs:
    kind, name = d.get("kind"), d.get("metadata", {}).get("name")
    comp_label = d.get("metadata", {}).get("labels", {}).get("app.kubernetes.io/component", "")
    if kind in ("Role", "RoleBinding") and not comp_label.startswith("format-migration") and comp_label != SANDBOX_COMPONENT:
        errors.append(f"{kind}/{name}: only the format-migration hook and the sandbox runner may render Kubernetes RBAC")
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

for d in docs:
    if d.get("kind") not in ("Deployment", "StatefulSet", "Job", "CronJob", "DaemonSet"):
        continue
    tpl = d["spec"].get("jobTemplate", {}).get("spec", {}).get("template") or d["spec"]["template"]
    for c in (tpl["spec"].get("containers") or []) + (tpl["spec"].get("initContainers") or []):
        if any(w in d["metadata"]["name"] and c["name"] == n for w, n in SHELL_ALLOWLIST):
            continue
        if c.get("image", "").startswith(SHELL_ALLOWED_IMAGE_PREFIXES):
            continue
        for where, a in shell_hits(c):
            errors.append(f"{d['kind']}/{d['metadata']['name']} container {c['name']} {where}: invokes {a}")

sas = {d["metadata"]["name"] for d in docs if d.get("kind") == "ServiceAccount"}
for d in docs:
    if d.get("kind") in ("Deployment", "StatefulSet", "Job"):
        sa = d["spec"]["template"]["spec"].get("serviceAccountName")
        if sa and sa not in sas and not sa.endswith("-format-migration"):
            errors.append(f"{d['kind']}/{d['metadata']['name']}: ServiceAccount {sa} is referenced but not rendered")

def check_sandbox():
    workloads = [d for d in docs if d.get("kind") in ("Deployment", "StatefulSet")]
    runners = [d for d in workloads
               if d["spec"]["template"]["metadata"].get("labels", {}).get("app.kubernetes.io/component") == SANDBOX_COMPONENT]
    rbac = [d for d in docs if d.get("kind") in ("Role", "RoleBinding")
            and d["metadata"].get("labels", {}).get("app.kubernetes.io/component") == SANDBOX_COMPONENT]
    for d in docs:
        if d.get("kind") in ("ClusterRole", "ClusterRoleBinding"):
            errors.append(f"{d['kind']}/{d['metadata']['name']}: cluster-scoped RBAC is not allowed")
    if not runners:
        if rbac:
            errors.append("sandbox Role/RoleBinding rendered without a runner workload")
        return
    sandbox_ns, sas = "", set()
    for d in runners:
        spec = d["spec"]["template"]["spec"]
        name = f"{d['kind']}/{d['metadata']['name']}"
        sas.add(spec.get("serviceAccountName"))
        if spec.get("automountServiceAccountToken") is not True or spec.get("enableServiceLinks") is not False:
            errors.append(f"{name}: runner must automount its token and set enableServiceLinks=false")
        for v in spec.get("volumes") or []:
            if "hostPath" in v:
                errors.append(f"{name}: hostPath volume {v['name']}")
        for c in spec.get("containers", []) + spec.get("initContainers", []):
            for e in c.get("env") or []:
                if e.get("name") == "SANDBOX_NAMESPACE":
                    sandbox_ns = e.get("value", "")
            sc = c.get("securityContext") or {}
            if not (sc.get("runAsNonRoot") is True and sc.get("readOnlyRootFilesystem") is True
                    and sc.get("allowPrivilegeEscalation") is False
                    and "ALL" in (sc.get("capabilities") or {}).get("drop", [])
                    and (sc.get("seccompProfile") or {}).get("type") == "RuntimeDefault"):
                errors.append(f"{name} container {c['name']}: not hardened")
    if not sandbox_ns:
        errors.append("sandbox runner has no SANDBOX_NAMESPACE")
    for d in workloads:
        if d not in runners and d["spec"]["template"]["spec"].get("serviceAccountName") in sas:
            errors.append(f"{d['kind']}/{d['metadata']['name']}: uses the sandbox runner ServiceAccount")
    for d in rbac:
        name = f"{d['kind']}/{d['metadata']['name']}"
        if d["metadata"].get("namespace") != sandbox_ns:
            errors.append(f"{name}: namespace {d['metadata'].get('namespace')!r} is not the sandbox namespace {sandbox_ns!r}")
        if d["kind"] == "Role":
            for rule in d.get("rules") or []:
                for g in rule.get("apiGroups", []):
                    for r in rule.get("resources", []):
                        allowed = SANDBOX_ALLOWED.get((g, r))
                        extra = set(rule.get("verbs", [])) - allowed if allowed is not None else set(rule.get("verbs", []))
                        if allowed is None or extra:
                            errors.append(f"{name}: grants {sorted(extra)} on {g or 'core'}/{r}")
        else:
            if d["roleRef"]["kind"] != "Role":
                errors.append(f"{name}: roleRef must be a Role")
            for sub in d.get("subjects") or []:
                if sub.get("kind") != "ServiceAccount" or sub.get("name") not in sas:
                    errors.append(f"{name}: binds {sub.get('kind')}/{sub.get('name')}, not the runner ServiceAccount")
    if rbac and not any(
            d.get("kind") == "NetworkPolicy" and d["metadata"].get("namespace") == sandbox_ns
            and d["spec"].get("podSelector") == {} and not d["spec"].get("ingress") and not d["spec"].get("egress")
            and set(d["spec"].get("policyTypes", [])) == {"Ingress", "Egress"} for d in docs):
        errors.append(f"no default-deny NetworkPolicy in sandbox namespace {sandbox_ns!r}")
    for d in docs:
        if d.get("kind") == "NetworkPolicy":
            sel = ((d["spec"].get("podSelector") or {}).get("matchLabels") or {}).get("app.kubernetes.io/component")
            if sel == SANDBOX_COMPONENT:
                for rule in d["spec"].get("egress") or []:
                    for p in rule.get("ports") or []:
                        if p.get("port") not in SANDBOX_EGRESS_PORTS:
                            errors.append(f"NetworkPolicy/{d['metadata']['name']}: runner egress port {p.get('port')} is not DNS or the Kubernetes API")


check_sandbox()

if errors:
    print("\n".join("FAIL: " + e for e in errors))
    sys.exit(1)
print(f"ok: {sum(1 for d in docs if d.get('kind') == 'NetworkPolicy')} NetworkPolicies checked")
