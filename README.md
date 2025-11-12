# MnemoShare Helm Charts

[![Artifact Hub](https://img.shields.io/endpoint?url=https://artifacthub.io/badge/repository/mnemoshare)](https://artifacthub.io/packages/search?repo=mnemoshare)
[![Release Charts](https://github.com/mnemoshare/helm-charts/actions/workflows/release.yml/badge.svg)](https://github.com/mnemoshare/helm-charts/actions/workflows/release.yml)

Public Helm charts for deploying MnemoShare - HIPAA-compliant secure file transfer system.

## Usage

Add the Helm repository:

```bash
helm repo add mnemoshare https://mnemoshare.github.io/helm-charts
helm repo update
```

Search available charts:

```bash
helm search repo mnemoshare
```

Install a chart:

```bash
helm install mnemoshare mnemoshare/mnemoshare --namespace mnemoshare --create-namespace
```

## Available Charts

- **[mnemoshare](./charts/mnemoshare)** - Main application chart with API server, web interface, and CLI

## Chart Documentation

Each chart has its own README with detailed installation and configuration instructions:

- [MnemoShare Chart Documentation](./charts/mnemoshare/README.md)

## Prerequisites

- Kubernetes 1.20+
- Helm 3.8+
- MongoDB 6.0+ (external or managed)
- S3-compatible object storage (AWS S3, MinIO, GCS)
- Valid MnemoShare license key ([get one here](https://mnemoshare.com/pricing))

## Quick Start

```bash
# Create namespace
kubectl create namespace mnemoshare

# Install with required values
helm install mnemoshare mnemoshare/mnemoshare \
  --namespace mnemoshare \
  --set mongodb.external.uri="mongodb://user:pass@host:27017/mnemoshare" \
  --set s3.bucket="your-bucket" \
  --set s3.accessKey="your-key" \
  --set s3.secretKey="your-secret" \
  --set jwt.secret="your-jwt-secret-min-32-chars" \
  --set encryption.key="your-32-byte-key" \
  --set license.key="your-license-key" \
  --set appUrl="https://mnemoshare.example.com" \
  --set ingress.hosts[0].host="mnemoshare.example.com"
```

## Development

### Testing Charts Locally

```bash
# Lint charts
helm lint charts/mnemoshare

# Test template rendering
helm template mnemoshare charts/mnemoshare --values charts/mnemoshare/values.yaml

# Install locally
helm install mnemoshare ./charts/mnemoshare --namespace mnemoshare --create-namespace
```

### Contributing

Charts are automatically released when changes are pushed to the `main` branch. The workflow:

1. Make changes to charts in `charts/` directory
2. Bump chart version in `Chart.yaml`
3. Commit and push to `main` branch
4. GitHub Actions automatically packages and publishes the chart
5. Chart becomes available at `https://mnemoshare.github.io/helm-charts`

## Automatic Updates

This repository uses GitHub Actions to automatically:

- ✅ **Lint and test** charts on every commit
- ✅ **Package charts** when changes are detected in `charts/`
- ✅ **Publish to GitHub Pages** automatically
- ✅ **Update index.yaml** with new chart versions
- ✅ **Create GitHub Releases** with packaged chart archives

Simply commit changes to `charts/` and the workflow handles the rest!

## Support

- 📖 **Documentation:** https://mnemoshare.com/docs
- 💬 **Support:** support@mnemoshare.com
- 🐛 **Issues:** https://github.com/mnemoshare/helm-charts/issues
- 🌐 **Website:** https://mnemoshare.com

## License

Commercial - License required to run MnemoShare. Charts are open source.

Get a license at [mnemoshare.com/pricing](https://mnemoshare.com/pricing)
