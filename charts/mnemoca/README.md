# MnemoCA Helm Chart

Deploys [MnemoCA](https://github.com/MnemoShare/mnemoca) — the open-source
post-quantum certificate authority (ML-DSA / FIPS 204, hybrid chains, ACME,
multi-tenant) — using the FIPS 140-3 enabled image from Docker Hub
(`mnemoshare/mnemoca`, Docker Scout vetted).

## Quick start

```bash
kubectl create namespace mnemoshare-ca
kubectl -n mnemoshare-ca create secret generic mnemoca-passphrase \
  --from-literal=passphrase="$(openssl rand -base64 32)"

helm repo add mnemoshare https://mnemoshare.github.io/helm-charts
helm install mnemoca mnemoshare/mnemoca -n mnemoshare-ca \
  --set ca.existingSecret=mnemoca-passphrase
```

Default mode is `bolt`: a single replica (StatefulSet) with all state on a
PVC. Root initialization runs automatically as an idempotent initContainer
(`mnemoca init --if-needed`) using `ca.init.alg` / `ca.init.pairAlg`
(default: hybrid ML-DSA-87 + ECDSA P-384 roots).

## High availability (MongoDB)

```yaml
storage:
  backend: mongo
  mongo:
    existingSecret: mnemoca-mongo   # Secret key "uri": mongodb://...
    database: mnemoca
replicaCount: 3
ca:
  existingSecret: mnemoca-passphrase
```

In mongo mode all state — documents, encrypted key envelopes, and the signed
audit chain — lives in MongoDB; pods are stateless and horizontally
scalable. Root initialization runs as a single post-install hook Job.

## TLS

The pod listens on cluster-internal HTTP; terminate TLS at the ingress
(`ingress.enabled=true`). A CA has a bootstrap problem issuing its own
serving certificate — if you need end-to-end TLS to the pod, issue a serving
cert from MnemoCA itself after install and mount it (`mnemoca issue`), or
front it with mesh mTLS. Go's TLS stack negotiates the ML-KEM-768 hybrid
key exchange (FIPS 203) by default on any TLS hop MnemoCA serves.

## Terraform

The same chart drives Terraform-managed deployments:

```hcl
resource "helm_release" "mnemoca" {
  name             = "mnemoca"
  repository       = "https://mnemoshare.github.io/helm-charts"
  chart            = "mnemoca"
  version          = "0.1.0"
  namespace        = "mnemoshare-ca"
  create_namespace = true

  values = [file("${path.module}/values/mnemoca.yaml")]
}
```

## Key values

| Value | Default | Description |
|---|---|---|
| `storage.backend` | `bolt` | `bolt` (single replica, PVC) or `mongo` (HA) |
| `storage.mongo.existingSecret` | — | Secret with key `uri` (mongo mode) |
| `replicaCount` | `2` | Replicas (mongo mode only) |
| `ca.existingSecret` | — | **Required.** Secret with key `passphrase` |
| `ca.init.alg` / `ca.init.pairAlg` | `ml-dsa-87` / `ecdsa-p384` | Root algorithm(s) |
| `ca.acmeEAB` | `false` | Require ACME External Account Binding |
| `ca.externalURL` | — | Public URL for ACME directory objects |
| `ingress.enabled` | `false` | Expose API/ACME via ingress |
| `image.repository` | `mnemoshare/mnemoca` | Use `ghcr.io/mnemoshare/mnemoca` for dev builds |
