# MnemoShare Helm Chart

HIPAA-compliant secure file transfer system with knowledge-based authentication.

## Features

- 🔒 **HIPAA Compliant** - Built for healthcare and financial data
- 🔐 **Knowledge-Based Authentication** - Dynamic questionnaire validation
- 🔑 **Multi-Factor Authentication** - TOTP-based 2FA
- 📊 **Comprehensive Audit Logging** - Track all file access
- 🚀 **Horizontal Scaling** - Auto-scaling with HPA support
- 📦 **S3-Compatible Storage** - AWS S3, MinIO, GCS support

## Prerequisites

- Kubernetes 1.20+
- Helm 3.8+
- MongoDB 6.0+ (external or managed)
- S3-compatible object storage
- Valid MnemoShare license key

## Quick Start

### Add Helm Repository

```bash
helm repo add mnemoshare https://mnemoshare.github.io/helm-charts
helm repo update
```

### Install Chart

```bash
# Create namespace
kubectl create namespace mnemoshare

# Install with minimum required values
helm install mnemoshare mnemoshare/mnemoshare \
  --namespace mnemoshare \
  --set mongodb.external.uri="mongodb://user:pass@host:27017/mnemoshare" \
  --set s3.bucket="your-bucket" \
  --set s3.accessKey="your-access-key" \
  --set s3.secretKey="your-secret-key" \
  --set jwt.secret="your-jwt-secret-minimum-32-chars" \
  --set encryption.key="your-32-byte-encryption-key" \
  --set license.key="your-license-key" \
  --set appUrl="https://mnemoshare.example.com" \
  --set ingress.hosts[0].host="mnemoshare.example.com"
```

### Install with Custom Values File

```bash
# Create values file
cat > my-values.yaml <<EOF
mongodb:
  external:
    enabled: true
    uri: "mongodb://user:pass@mongo.example.com:27017/mnemoshare"

s3:
  endpoint: "https://s3.amazonaws.com"
  region: "us-east-1"
  bucket: "mnemoshare-files"
  accessKey: "AKIA..."
  secretKey: "xxx"

jwt:
  secret: "your-super-secret-jwt-key-min-32-characters"

encryption:
  key: "your-32-byte-encryption-key-here!"

license:
  key: "your-license-key-from-purchase"
  serverUrl: "https://license.mnemoshare.com"

appUrl: "https://mnemoshare.example.com"

ingress:
  enabled: true
  className: "nginx"
  hosts:
    - host: mnemoshare.example.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: mnemoshare-tls
      hosts:
        - mnemoshare.example.com

resources:
  requests:
    cpu: 500m
    memory: 1Gi
  limits:
    cpu: 2000m
    memory: 4Gi
EOF

# Install
helm install mnemoshare mnemoshare/mnemoshare \
  --namespace mnemoshare \
  --values my-values.yaml
```

## Configuration

### Required Values

| Parameter | Description | Example |
|-----------|-------------|---------|
| `mongodb.external.uri` | MongoDB connection string | `mongodb://user:pass@host:27017/db` |
| `s3.bucket` | S3 bucket name | `mnemoshare-files` |
| `s3.accessKey` | S3 access key | `AKIA...` |
| `s3.secretKey` | S3 secret key | `xxx` |
| `jwt.secret` | JWT signing secret (min 32 chars) | `your-secret` |
| `encryption.key` | File encryption key (32 bytes) | `your-key` |
| `license.key` | MnemoShare license key | `your-license` |
| `appUrl` | Application URL | `https://example.com` |

### Optional Values

| Parameter | Description | Default |
|-----------|-------------|---------|
| `replicaCount` | Number of replicas | `2` |
| `image.tag` | Image tag | `latest` |
| `ingress.enabled` | Enable ingress | `true` |
| `autoscaling.enabled` | Enable HPA | `false` |
| `sendgrid.apiKey` | SendGrid API key for emails | `""` |

See [values.yaml](./values.yaml) for all configuration options.

## Advanced Configuration

### Using Existing Secrets

Instead of storing sensitive data in values, use existing Kubernetes secrets:

```yaml
existingSecrets:
  mongodb: "my-mongodb-secret"  # Must have 'mongodb-uri' key
  s3: "my-s3-secret"            # Must have 's3-access-key' and 's3-secret-key' keys
  jwt: "my-jwt-secret"          # Must have 'jwt-secret' key
  encryption: "my-encryption-secret"  # Must have 'encryption-key' key
  license: "my-license-secret"  # Must have 'license-key' key
```

### Enable Auto-Scaling

```yaml
autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 10
  targetCPUUtilizationPercentage: 80
  targetMemoryUtilizationPercentage: 80
```

### Configure SendGrid for Email Notifications

```yaml
sendgrid:
  apiKey: "SG.xxx"
  fromEmail: "noreply@example.com"
  fromName: "MnemoShare"
```

### Custom Resource Limits

```yaml
resources:
  requests:
    cpu: 1000m
    memory: 2Gi
  limits:
    cpu: 4000m
    memory: 8Gi
```

## Upgrading

```bash
# Update repository
helm repo update

# Upgrade release
helm upgrade mnemoshare mnemoshare/mnemoshare \
  --namespace mnemoshare \
  --values my-values.yaml
```

## Uninstalling

```bash
helm uninstall mnemoshare --namespace mnemoshare
```

## Troubleshooting

### Check Pod Status

```bash
kubectl get pods -n mnemoshare
kubectl logs -n mnemoshare deployment/mnemoshare
```

### Verify License

```bash
kubectl exec -n mnemoshare deployment/mnemoshare -- mnemocli --version
```

### Test Connection

```bash
kubectl port-forward -n mnemoshare svc/mnemoshare 8080:80
curl http://localhost:8080/health
```

## Support

- Documentation: https://mnemoshare.com/docs
- Email: support@mnemoshare.com
- Issues: https://github.com/mnemoshare/helm-charts/issues

## License

Commercial - License required to run. Get a license at https://mnemoshare.com/pricing
