# Contributing to MnemoShare Helm Charts

Thank you for contributing! This document explains how to make changes to the charts.

## Development Workflow

### 1. Make Changes

Edit files in `charts/mnemoshare/`:

```bash
cd charts/mnemoshare

# Edit templates, values, or Chart.yaml
vim templates/deployment.yaml
vim values.yaml
```

### 2. Bump Version

**Important:** Always increment the chart version in `Chart.yaml`:

```yaml
# charts/mnemoshare/Chart.yaml
version: 1.0.1  # Increment patch version for bug fixes
                # Increment minor version for new features
                # Increment major version for breaking changes
appVersion: "0.3.1"  # Update when new Docker image is released
```

### 3. Test Locally

```bash
# Lint the chart
helm lint charts/mnemoshare

# Render templates to check for errors
helm template mnemoshare charts/mnemoshare

# Test with custom values
helm template mnemoshare charts/mnemoshare \
  --set mongodb.external.uri="mongodb://test" \
  --set s3.bucket="test" \
  --set license.key="test"

# Install locally (requires Kubernetes cluster)
helm install mnemoshare-test ./charts/mnemoshare \
  --namespace test \
  --create-namespace \
  --dry-run --debug
```

### 4. Commit and Push

```bash
git add charts/mnemoshare/
git commit -m "Update chart: describe your changes

- Added support for XYZ
- Fixed issue with ABC
- Updated to appVersion 0.3.2"

git push origin main
```

### 5. Automatic Release

GitHub Actions will automatically:
1. Run linting and tests
2. Package the chart
3. Create a GitHub Release
4. Update the Helm repository index
5. Publish to GitHub Pages

Monitor progress: https://github.com/mnemoshare/helm-charts/actions

## Chart Structure

```
charts/mnemoshare/
├── Chart.yaml              # Chart metadata (name, version, description)
├── values.yaml             # Default configuration values
├── README.md               # Chart documentation
└── templates/
    ├── _helpers.tpl        # Template helper functions
    ├── deployment.yaml     # Kubernetes Deployment
    ├── service.yaml        # Kubernetes Service
    ├── ingress.yaml        # Kubernetes Ingress (optional)
    ├── secrets.yaml        # Kubernetes Secrets
    ├── serviceaccount.yaml # Kubernetes ServiceAccount
    └── hpa.yaml           # HorizontalPodAutoscaler (optional)
```

## Testing Guidelines

### Mandatory Tests

Before pushing, ensure:

1. ✅ Chart passes linting: `helm lint charts/mnemoshare`
2. ✅ Templates render without errors: `helm template mnemoshare charts/mnemoshare`
3. ✅ All required values are documented in `values.yaml`
4. ✅ README.md is updated with new configuration options
5. ✅ Chart version is bumped in `Chart.yaml`

### Optional Tests

For major changes:

1. Test installation on a real Kubernetes cluster
2. Test upgrades from previous chart versions
3. Test with different value combinations

## Common Tasks

### Adding a New Template

1. Create file in `charts/mnemoshare/templates/`
2. Use helper functions from `_helpers.tpl`
3. Add configuration to `values.yaml`
4. Document in README.md
5. Bump chart version

### Adding a New Value

1. Add to `values.yaml` with sensible default
2. Use in templates with `{{ .Values.newValue }}`
3. Document in README.md
4. Bump chart version (patch)

### Updating Docker Image Version

1. Update `appVersion` in `Chart.yaml`
2. Optionally update `image.tag` default in `values.yaml`
3. Bump chart version (patch)
4. Update README.md if needed

## Versioning Strategy

We follow [Semantic Versioning](https://semver.org/):

- **MAJOR** (1.0.0 → 2.0.0): Breaking changes requiring manual intervention
- **MINOR** (1.0.0 → 1.1.0): New features, backward compatible
- **PATCH** (1.0.0 → 1.0.1): Bug fixes, backward compatible

Examples:
- Adding a new template → MINOR
- Changing default value → PATCH (unless breaking)
- Removing a value → MAJOR
- Fixing a bug → PATCH
- Updating appVersion only → PATCH

## Pull Request Process

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/new-feature`
3. Make changes and test locally
4. Bump chart version appropriately
5. Update documentation
6. Commit with descriptive message
7. Push and create Pull Request
8. Wait for CI checks to pass
9. Request review from maintainers

## Questions?

- Email: support@mnemoshare.com
- Issues: https://github.com/mnemoshare/helm-charts/issues
