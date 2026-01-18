# MnemoShare Helm Chart

HIPAA-compliant secure file transfer system with knowledge-based authentication.

## Features

- 🔒 **HIPAA Compliant** - Built for healthcare and financial data
- 🔐 **Knowledge-Based Authentication** - Dynamic questionnaire validation
- 🔑 **Multi-Factor Authentication** - TOTP-based 2FA
- 🔏 **Hardware mTLS** - Enterprise+ hardware key authentication
- 🛡️ **HSM Support** - FIPS 140-2/140-3 compliant key protection (PKCS#11)
- 📊 **Comprehensive Audit Logging** - Track all file access
- 🚀 **Horizontal Scaling** - Auto-scaling with HPA support
- 📦 **S3-Compatible Storage** - AWS S3, MinIO, GCS support
- 🏛️ **External CA Integration** - Vault PKI, EJBCA support

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

### Disk Buffer Configuration (Large File Uploads)

When processing large file uploads, MnemoShare buffers chunk data during ICAP virus scanning and encryption. For multi-GB files, this can cause memory pressure with concurrent uploads. Enable disk buffering to offload chunk data to disk.

**Behavior:**
- **ICAP enabled**: Always uses disk buffering (ICAP is slow, extends memory pressure)
- **ICAP disabled**: Uses disk buffering only for files exceeding `thresholdMB`

**Important:** Always mount a dedicated volume to avoid filling node ephemeral storage.

#### RAM Disk (Fastest)

```yaml
diskBuffer:
  enabled: true
  thresholdMB: 1536  # Files > 1.5GB use disk buffering
  encrypt: true      # Encrypt temp files at rest
  volume:
    type: "emptyDir"
    emptyDir:
      medium: "Memory"  # tmpfs (uses node RAM)
      sizeLimit: "4Gi"
```

#### NVMe/SSD Ephemeral Volume (Best Balance)

```yaml
diskBuffer:
  enabled: true
  thresholdMB: 1536
  encrypt: true
  volume:
    type: "ephemeral"
    ephemeral:
      storageClassName: "nvme-fast"  # Your fast storage class
      size: "4Gi"  # Handles ~100 concurrent chunks
```

#### Existing PVC (Maximum Capacity)

```yaml
diskBuffer:
  enabled: true
  thresholdMB: 1536
  encrypt: true
  volume:
    type: "existingClaim"
    existingClaim:
      claimName: "mnemoshare-disk-buffer"
```

| Parameter | Description | Default |
|-----------|-------------|---------|
| `diskBuffer.enabled` | Enable disk buffering | `false` |
| `diskBuffer.thresholdMB` | File size threshold for disk buffering (MB) | `1536` |
| `diskBuffer.encrypt` | Encrypt temp files at rest | `true` |
| `diskBuffer.volume.type` | Volume type: emptyDir, ephemeral, existingClaim | `emptyDir` |
| `diskBuffer.volume.emptyDir.medium` | "" for disk, "Memory" for tmpfs | `Memory` |
| `diskBuffer.volume.emptyDir.sizeLimit` | Size limit for emptyDir | `4Gi` |

## Certificate Authority Configuration

MnemoShare supports hardware mTLS authentication (Enterprise+ tier) using certificate authorities. Choose from the built-in Step-CA or integrate with external CA providers.

### Step-CA (Built-in)

Enable the built-in Smallstep CA for mTLS certificate management:

```yaml
stepCA:
  enabled: true
  ca:
    name: "MnemoShare CA"
    dns: "step-ca"
  provisioner:
    name: "mnemoshare"
    password: "your-provisioner-password"
  persistence:
    enabled: true
    size: 1Gi
```

### Step-CA with HSM (FIPS 140-2/140-3 Compliant)

For organizations requiring FIPS-compliant key protection, Step-CA can store CA signing keys in a Hardware Security Module (HSM) using PKCS#11.

**Requirements:**
- Node with HSM access (USB passthrough or network HSM)
- Vendor-specific PKCS#11 library
- Pre-initialized HSM with appropriate slots/tokens

**Supported HSMs:**
- YubiKey 5 series (PIV mode)
- Thales Luna Network HSM
- AWS CloudHSM
- Azure Dedicated HSM
- Google Cloud HSM
- SafeNet/Gemalto HSMs
- SoftHSM2 (for testing only)

#### YubiKey HSM Example

```yaml
stepCA:
  enabled: true
  ca:
    name: "MnemoShare CA"
  hsm:
    enabled: true
    image:
      repository: smallstep/step-ca-hsm
      tag: "0.27.5"
    pkcs11:
      modulePath: "/usr/lib/libykcs11.so"
      uri: "pkcs11:token=YubiKey%20PIV;slot-id=0"
      pin: "123456"  # Use existingPinSecret in production
    hostMounts:
      pkcs11Lib:
        enabled: true
        hostPath: "/usr/lib/libykcs11.so"
        mountPath: "/usr/lib/libykcs11.so"
      usbDevice:
        enabled: true
        hostPath: "/dev/bus/usb"
    pcscd:
      enabled: true
      image:
        repository: pcscd
        tag: "latest"
    securityContext:
      runAsRoot: true
    nodeAffinity:
      enabled: true
      requiredNodeLabels:
        hsm-attached: "true"
        hsm-type: "yubikey"
```

#### AWS CloudHSM Example

```yaml
stepCA:
  enabled: true
  hsm:
    enabled: true
    pkcs11:
      modulePath: "/opt/cloudhsm/lib/libcloudhsm_pkcs11.so"
      uri: "pkcs11:token=cavium;object=ca-key;type=private"
      existingPinSecret: "cloudhsm-credentials"  # Contains 'pin' key
    hostMounts:
      extraMounts:
        - name: cloudhsm-config
          hostPath: /opt/cloudhsm
          mountPath: /opt/cloudhsm
          readOnly: true
    nodeAffinity:
      enabled: true
      requiredNodeLabels:
        cloudhsm-attached: "true"
```

#### SoftHSM2 (Testing Only)

For development/testing environments:

```yaml
stepCA:
  enabled: true
  hsm:
    enabled: true
    pkcs11:
      modulePath: "/usr/lib/softhsm/libsofthsm2.so"
      uri: "pkcs11:module-path=/usr/lib/softhsm/libsofthsm2.so;token=step-ca"
      pin: "1234"
```

**Node Preparation for USB HSMs:**

```bash
# Label HSM-attached nodes
kubectl label node <node-name> hsm-attached=true hsm-type=yubikey

# Verify USB device is accessible
kubectl debug node/<node-name> -it --image=alpine -- ls /dev/bus/usb/
```

### HashiCorp Vault PKI (External Integration)

Integrate with an existing HashiCorp Vault deployment for certificate management.

> **Note:** MnemoShare does NOT deploy Vault. You must have an existing Vault installation.

```yaml
vaultPKI:
  enabled: true
  address: "https://vault.example.com:8200"
  mountPath: "pki"
  roleName: "mnemoshare"
  auth:
    method: "kubernetes"
    kubernetes:
      role: "mnemoshare"
      mountPath: "auth/kubernetes"
```

#### Vault Enterprise with Managed Keys (HSM-backed)

> **Warning:** Managed Keys require **Vault Enterprise** license.

For HSM-backed keys in Vault Enterprise:

```yaml
vaultPKI:
  enabled: true
  address: "https://vault.example.com:8200"
  mountPath: "pki"
  roleName: "mnemoshare"
  auth:
    method: "kubernetes"
    kubernetes:
      role: "mnemoshare"
  managedKeys:
    enabled: true
    keyName: "hsm-ca-key"  # Configured in Vault
```

HSM/KMS configuration is done in Vault, not in this chart. See [Vault Managed Keys documentation](https://developer.hashicorp.com/vault/docs/enterprise/managed-keys).

### EJBCA (External Integration)

Integrate with an existing EJBCA installation.

> **Important:** MnemoShare does **NOT** deploy or manage EJBCA. You must have an existing EJBCA installation.

```yaml
ejbca:
  enabled: true
  apiUrl: "https://ejbca.example.com/ejbca/ejbca-rest-api"
  certificateProfile: "mnemoshare"
  endEntityProfile: "mnemoshare"
  caName: "MnemoShareCA"
  auth:
    clientCert:
      existingSecret: "ejbca-client-cert"
      certKey: "tls.crt"
      keyKey: "tls.key"
```

EJBCA supports PKCS#11-backed CA keys natively. Configure HSM integration in EJBCA directly. See [EJBCA Crypto Tokens documentation](https://doc.primekey.com/ejbca/ejbca-operations/ejbca-ca-concept-guide/crypto-tokens).

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
