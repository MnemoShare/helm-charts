# helm-charts NetworkPolicy delta report

Cross-reference of `charts/mnemoshare/templates/networkpolicy.yaml` against the
mnemoshare-demo NetworkPolicy lockdown (source of truth in
`mnemoshare-saas-infra/manifests/demo/`, captured during the 2026-05-24
hardening exercise).

Worktree base: `origin/main` (post-`da4b45c`, chart appVersion 0.15.1).

## TL;DR

- **MSC-277 in scope** — five public-CIDR egress rules need `169.254.0.0/16`
  + `100.64.0.0/10` added to their `except:` blocks. The pattern already exists
  in the workflow rule (line 250–262). Mirror it.
- **Post-MSC-277 gap (Critical)** — `email-gateway` and `inbound-gateway` have
  NO NetworkPolicy stanzas, yet `default-deny` selects them via
  `mnemoshare.selectorLabels`. Turning on `networkPolicy.enabled` together
  with either gateway BREAKS the gateway. Same pattern as the existing
  `sftp-gateway` carve-out (added in #12).
- **Container-port-vs-service-port** check: the API ingress already uses
  `.Values.service.targetPort` (defaults `8080`), which is the container
  port. Correct.

## Per-rule audit

| File / rule | Current excepts | Demo posture | Gap |
|---|---|---|---|
| `networkpolicy.yaml:113` S3 egress | RFC1918 only | RFC1918 + 169.254 + 100.64 | Add IMDS + CGNAT |
| `networkpolicy.yaml:179` License Server (public path) | RFC1918 only | RFC1918 + 169.254 + 100.64 | Add IMDS + CGNAT |
| `networkpolicy.yaml:201` SendGrid API | RFC1918 only | RFC1918 + 169.254 + 100.64 | Add IMDS + CGNAT |
| `networkpolicy.yaml:213` OAuth/SSO providers | RFC1918 only | RFC1918 + 169.254 + 100.64 | Add IMDS + CGNAT |
| `networkpolicy.yaml:227` External SMTP | RFC1918 only | RFC1918 + 169.254 + 100.64 | Add IMDS + CGNAT |
| `networkpolicy.yaml:254` Workflow broad TCP | RFC1918 + 169.254 + 100.64 | same | ✓ Already correct |
| `networkpolicy.yaml:303` ClamAV external defs | RFC1918 only | n/a | Add IMDS + CGNAT (defense in depth, opens :80 + :443) |

## Missing NetworkPolicy stanzas

| Pod selector | Why default-deny breaks it | Demo reference |
|---|---|---|
| `app.kubernetes.io/component: email-gateway` | Default-deny matches `mnemoshare.selectorLabels` → catches gateway pods | demo NP `email-gateway-ingress` + `email-gateway-egress` |
| `app.kubernetes.io/component: inbound-gateway` | Same — default-deny applies; no gateway-specific allow rules exist | demo NP `inbound-gateway-ingress` + `inbound-gateway-egress` |

## Out of scope for this PR

- Defaulting `networkPolicy.workflows.enabled` to `true` for workflow-licensed
  customers (per MSC-277 acceptance: "filed separately if you want that").
  Captured in the chart README instead — recommend customers enable it.
- Customer-facing docs (MSC-279) — separate ticket.
- License-server :8443 (vs :443) — only relevant when a customer points at
  an in-cluster license server. The public chart's default assumes
  `https://license.mnemoshare.com` (port 443); customers running their own
  can override `networkPolicy.licenseServer.cidr`. Add a `.port` knob as a
  separate enhancement if requested.

## Plan applied in this PR

1. Add 169.254/16 + 100.64/10 to all six public-CIDR rules (S3, License,
   SendGrid, OAuth, SMTP, ClamAV-defs). Hardcoded (security baseline — not
   customer-tweakable).
2. Add NetworkPolicy stanzas for `email-gateway` and `inbound-gateway` when
   the respective `*.enabled` value is true, mirroring the demo posture and
   the existing `sftp-gateway` carve-out pattern (#12).
   - Email-gateway: ingress on container :25 (configurable `LISTEN_PORTS`)
     + :8081 mgmt; egress to API, DNS, and public SMTP w/ the same except
     list.
   - Inbound-gateway: ingress on :10025/:10070/:8080; egress to API, DNS,
     public :443 (S3 bucket-verify on startup), and ClamAV when configured.
3. Bump chart minor version: `1.17.3 → 1.18.0` (additive feature; no API
   break).

## Operator CRD impact

None. Chart defaults are sufficient. Customer-tweakable knobs (CIDR/port
overrides, ingressNamespace) are already plumbed via `.Values.networkPolicy.*`.
