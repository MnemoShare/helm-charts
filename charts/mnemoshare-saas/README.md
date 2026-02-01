# MnemoShare SaaS Customer Helm Chart

This Helm chart deploys an isolated MnemoShare instance for SaaS customers. It's designed for the MnemoShare multi-tenant SaaS platform where centralized services (Step-CA, ClamAV, Redis Sentinel, DigitalOcean Spaces) are shared across tenants.

## Features

- **Tier-based resource limits**: Starter, Professional, Business, Enterprise
- **KEDA autoscaling**: TCP connections + memory for app, Redis queue depth for workers
- **Customer isolation**: Per-customer database, S3 prefix, encryption keys
- **Workflow worker**: Optional, auto-enabled for Business+ tiers
- **Custom domains**: Enterprise tier supports custom domain ingress

## Prerequisites

- Kubernetes 1.24+
- Helm 3.8+
- KEDA 2.10+ (for autoscaling)
- cert-manager (for TLS certificates)
- nginx-ingress or similar ingress controller
- Wildcard TLS certificate for `*.mnemoshare.io` (or your domain)

### Centralized Services (NOT deployed by this chart)

These services are deployed once for the entire SaaS platform:

- **MongoDB Replica Set**: Shared database cluster
- **Redis Sentinel**: Shared job queue cluster
- **Step-CA**: Centralized mTLS certificate authority
- **ClamAV ICAP**: Centralized virus scanning
- **DigitalOcean Spaces**: Shared object storage

## Installation

### Quick Start

```bash
helm install acme-clinic mnemoshare-saas \
  --namespace acme-clinic \
  --create-namespace \
  --set customer.id=acme-clinic \
  --set customer.subdomain=acme-clinic \
  --set tier=professional \
  -f customer-secrets.yaml
```

### Using Values File

Create `customer-values.yaml`:

```yaml
customer:
  id: "acme-clinic"
  subdomain: "acme-clinic"
  name: "ACME Medical Clinic"

tier: professional

database:
  uri: "mongodb://admin:PASSWORD@mnemodb:27017,mongo-nyc:27017,mongo-atl:27017/mnemoshare-saas-acme-clinic?authSource=admin&replicaSet=rs0"

redis:
  url: "redis+sentinel://:PASSWORD@redis-shared-node-0:26379,redis-shared-node-1:26379,redis-shared-node-2:26379/mymaster/0"

storage:
  endpoint: "https://sfo3.digitaloceanspaces.com"
  region: "sfo3"
  bucket: "mnemoshare-saas"
  accessKey: "ACCESS_KEY"
  secretKey: "SECRET_KEY"

encryption:
  key: "32-byte-encryption-key-here-xxx"

jwt:
  secret: "32-character-jwt-secret-here-xx"

license:
  key: "customer-license-key"
```

Install:

```bash
helm install acme-clinic mnemoshare-saas \
  --namespace acme-clinic \
  --create-namespace \
  -f customer-values.yaml
```

## Tier Examples

### Starter Tier ($199/mo)

Small clinics, solo practitioners (up to 10 users, 100GB storage).

```yaml
customer:
  id: "small-clinic"
  subdomain: "small-clinic"

tier: starter

# Resources: 250m-1000m CPU, 512Mi-1Gi memory
# 2 replicas, max 3 with autoscaling
# No workflow worker
```

### Professional Tier ($499/mo)

Small clinics, small legal firms (up to 50 users, 500GB storage).

```yaml
customer:
  id: "legal-firm"
  subdomain: "legal-firm"

tier: professional

# Resources: 500m-2000m CPU, 1Gi-2Gi memory
# 2 replicas, max 5 with autoscaling
# No workflow worker
```

### Business Tier ($999/mo)

Medical billing companies, mid-size orgs (up to 200 users, 2TB storage).

```yaml
customer:
  id: "billing-company"
  subdomain: "billing-company"

tier: business

# Resources: 1000m-4000m CPU, 2Gi-4Gi memory
# 2 replicas, max 10 with autoscaling
# Workflow worker enabled (2 replicas, auto-scaling to 5)
```

### Enterprise Tier (Custom pricing)

Large organizations with custom requirements.

```yaml
customer:
  id: "enterprise-health"
  subdomain: "enterprise-health"
  name: "Enterprise Health Systems"
  customDomain: "files.enterprisehealth.com"  # Custom domain

tier: enterprise

# Resources: 2000m-8000m CPU, 4Gi-8Gi memory
# 2 replicas, max 20 with autoscaling
# Workflow worker enabled (3 replicas, auto-scaling to 10)

# Override autoscaling for custom requirements
autoscaling:
  app:
    maxReplicas: 25
  workflowWorker:
    maxReplicas: 15
```

## Configuration

### Required Values

| Parameter | Description |
|-----------|-------------|
| `customer.id` | Unique customer identifier |
| `customer.subdomain` | Subdomain for customer URL |
| `tier` | Pricing tier (starter/professional/business/enterprise) |
| `database.uri` | MongoDB connection URI |
| `storage.accessKey` | S3 access key |
| `storage.secretKey` | S3 secret key |
| `encryption.key` | 32-byte encryption key |
| `jwt.secret` | JWT signing secret |
| `license.key` | Customer license key |

### Optional Values

| Parameter | Description | Default |
|-----------|-------------|---------|
| `redis.url` | Redis Sentinel URL (required for workflow worker) | `""` |
| `customer.name` | Display name | `""` |
| `customer.customDomain` | Custom domain (Enterprise only) | `""` |
| `ingress.domainSuffix` | Domain suffix for subdomains | `mnemoshare.io` |
| `icap.url` | Centralized ICAP URL | `icap://clamav...` |
| `stepCA.url` | Centralized Step-CA URL | `""` |

### Using Existing Secrets

For production, use existing Kubernetes secrets:

```yaml
existingDatabaseSecret: "acme-clinic-db"
existingStorageSecret: "acme-clinic-s3"
existingEncryptionSecret: "acme-clinic-encryption"
existingJWTSecret: "acme-clinic-jwt"
existingLicenseSecret: "acme-clinic-license"
existingRedisSecret: "acme-clinic-redis"
```

## Autoscaling

### Application Autoscaling

The app scales based on memory utilization and TCP connections:

```yaml
autoscaling:
  app:
    enabled: true
    minReplicas: 2
    maxReplicas: 5  # Set by tier
    memory:
      enabled: true
      targetUtilization: 80
    tcp:
      enabled: true
      targetValue: 100  # Connections per pod
```

### Workflow Worker Autoscaling

Workers scale based on Redis queue depth:

```yaml
autoscaling:
  workflowWorker:
    enabled: true
    minReplicas: 1
    maxReplicas: 5
    listLengthTarget: 5  # Tasks per worker
```

## Architecture Decisions

### Centralized Services

1. **Step-CA (mTLS)**: Centralized CA for all SaaS customers. A single platform-wide certificate authority handles all mTLS signing. This simplifies certificate management and is sufficient for expected request volumes.

2. **ICAP/ClamAV**: Consistent URL across all regions. A single ICAP endpoint (`icap://clamav.mnemoshare-platform.svc.cluster.local:1344`) handles virus scanning for all tenants.

### Storage

3. **S3 Bucket Strategy**:
   - **Starter/Professional/Business**: Shared bucket (`mnemoshare-saas`) with per-customer prefix (`customers/{customer_id}/`)
   - **Enterprise**: Dedicated bucket per customer (`mnemoshare-{customer_id}`)
   
   Enterprise tier automatically gets a dedicated bucket when `tier: enterprise` or when `storage.dedicatedBucket: true` is set.

### Redis Queue Isolation

4. **Redis Queues**: Prefix-based isolation using `asynq:{customer_id}:*` pattern.
   - Workers only consume jobs from their customer's queues
   - Shared Redis Sentinel cluster for all customers
   - **Note**: Requires mnemoshare code changes (see MNS-36)

## Troubleshooting

### Check deployment status

```bash
kubectl get pods -n acme-clinic
kubectl logs -n acme-clinic deployment/acme-clinic-mnemoshare-saas
```

### Verify KEDA scaling

```bash
kubectl get scaledobject -n acme-clinic
kubectl describe scaledobject acme-clinic-mnemoshare-saas-app -n acme-clinic
```

### Test connectivity

```bash
kubectl exec -it -n acme-clinic deployment/acme-clinic-mnemoshare-saas -- wget -qO- localhost:8080/health
```

## License

Copyright © 2026 MnemoShare. All rights reserved.
