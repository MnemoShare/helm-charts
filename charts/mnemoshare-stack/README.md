# MnemoShare Stack Helm Chart

Complete MnemoShare deployment with all dependencies. Perfect for evaluation or production.

## Quick Start

```bash
# Add dependencies
helm dependency update ./mnemoshare-stack

# Install with defaults (all services bundled)
helm install mnemoshare ./mnemoshare-stack -n mnemoshare --create-namespace

# Or use quickstart values
helm install mnemoshare ./mnemoshare-stack -f values-quickstart.yaml -n mnemoshare --create-namespace
```

## What's Included

| Service | Purpose | Bundled | External Option |
|---------|---------|---------|-----------------|
| PostgreSQL | Database | Bitnami chart | AWS RDS, Cloud SQL, etc. |
| Keycloak | Identity Provider | Bitnami chart | Okta, Azure AD, Google |
| MinIO | S3 Storage | Bitnami chart | AWS S3, GCS, Azure Blob |
| ClamAV | Virus Scanning | Custom | - |
| Step-CA | mTLS Certificates | Custom | - |
| MnemoShare | Application | MnemoShare chart | - |

## Configuration Options

### Use Bundled Services (Default)

Everything runs in your cluster - great for evaluation:

```yaml
postgresql:
  enabled: true
keycloak:
  enabled: true
minio:
  enabled: true
```

### Use External Database

```yaml
postgresql:
  enabled: false

externalDatabase:
  type: postgres  # or mongodb
  host: "your-db-host.example.com"
  port: 5432
  database: mnemoshare
  username: mnemoshare
  password: "your-password"
```

### Use External Identity Provider

```yaml
keycloak:
  enabled: false

externalIdP:
  enabled: true
  type: okta  # okta, azure-ad, google-workspace
  issuerUrl: "https://your-org.okta.com"
  clientId: "your-client-id"
  clientSecret: "your-client-secret"
```

### Use AWS S3

```yaml
minio:
  enabled: false

externalStorage:
  enabled: true
  type: s3
  endpoint: "s3.amazonaws.com"
  region: "us-west-2"
  bucket: "your-bucket"
  accessKey: "AKIA..."
  secretKey: "your-secret"
  useSSL: true
```

### Use Google Cloud Storage

```yaml
minio:
  enabled: false

externalStorage:
  enabled: true
  type: gcs
  endpoint: "storage.googleapis.com"
  region: "us-central1"
  bucket: "your-bucket"
  accessKey: "your-access-key"
  secretKey: "your-secret"
  useSSL: true
```

## Values Files

| File | Purpose |
|------|---------|
| `values.yaml` | Default configuration |
| `values-quickstart.yaml` | Quick evaluation setup |
| `values-production.yaml` | Production example with external services |

## License

MnemoShare runs without a license in evaluation mode. For production use, get a license at [mnemoshare.com/pricing](https://mnemoshare.com/pricing).

```yaml
mnemoshare:
  license:
    key: "your-license-key"
```

Or enter the license key in the Settings page after deployment.

## Upgrading

```bash
helm upgrade mnemoshare ./mnemoshare-stack -n mnemoshare -f your-values.yaml
```

## Uninstalling

```bash
helm uninstall mnemoshare -n mnemoshare
```

**Note:** PersistentVolumeClaims are not deleted automatically. To fully clean up:

```bash
kubectl delete pvc -l app.kubernetes.io/instance=mnemoshare -n mnemoshare
```
