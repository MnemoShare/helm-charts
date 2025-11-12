# Helm Charts Repository Setup Guide

This guide will help you set up the MnemoShare Helm charts repository with automatic publishing to GitHub Pages and Artifact Hub.

## Step 1: Create GitHub Repository

1. Go to https://github.com/mnemoshare
2. Click "New repository"
3. Name: `helm-charts`
4. Description: "Public Helm charts for deploying MnemoShare"
5. Set to **Public**
6. Click "Create repository"

## Step 2: Push Initial Code

```bash
cd /Users/derrick/projects/trading/helm-charts

# Add remote
git remote add origin https://github.com/mnemoshare/helm-charts.git

# Add all files
git add .

# Commit
git commit -m "Initial Helm chart for MnemoShare

- Add mnemoshare chart v1.0.0
- Add GitHub Actions for automatic releases
- Add linting and testing workflows
- Add comprehensive documentation"

# Push to main
git push -u origin main
```

## Step 3: Enable GitHub Pages

1. Go to repository Settings → Pages
2. Source: **Deploy from a branch**
3. Branch: **gh-pages** / (root)
4. Click **Save**

**Note:** The `gh-pages` branch will be created automatically by the GitHub Action on the first release.

## Step 4: Verify Automatic Release

After pushing to `main`, the GitHub Action will:

1. ✅ Lint and test the chart
2. ✅ Package the chart into a `.tgz` file
3. ✅ Create a GitHub Release
4. ✅ Create/update the `gh-pages` branch with `index.yaml`
5. ✅ Make the chart available at `https://mnemoshare.github.io/helm-charts`

Check the Actions tab to see the workflow running:
https://github.com/mnemoshare/helm-charts/actions

## Step 5: Test the Chart Repository

After the Action completes (usually 1-2 minutes):

```bash
# Add the repository
helm repo add mnemoshare https://mnemoshare.github.io/helm-charts

# Update repositories
helm repo update

# Search for charts
helm search repo mnemoshare

# Should show:
# NAME                    CHART VERSION   APP VERSION     DESCRIPTION
# mnemoshare/mnemoshare   1.0.0           0.3.1           HIPAA-compliant secure file transfer system...
```

## Step 6: Register on Artifact Hub

1. Go to https://artifacthub.io
2. Sign in with GitHub
3. Click "Control Panel" → "Add repository"
4. Fill in:
   - **Name:** MnemoShare
   - **Display name:** MnemoShare Helm Charts
   - **URL:** `https://mnemoshare.github.io/helm-charts`
   - **Type:** Helm charts
   - **Publisher:** MnemoShare
5. Click "Add"

Artifact Hub will automatically:
- Index your charts
- Make them searchable at https://artifacthub.io
- Scan for security issues
- Generate badges

## Step 7: Update Artifact Hub Metadata

After registering on Artifact Hub, you'll get a repository ID. Update `artifacthub-repo.yml`:

```yaml
repositoryID: your-actual-repository-id-here  # Update this!
owners:
  - name: MnemoShare
    email: support@mnemoshare.com
```

Commit and push the change:

```bash
git add artifacthub-repo.yml
git commit -m "Update Artifact Hub repository ID"
git push
```

## Step 8: Update Website Documentation

Update the installation docs in `../mnemoshare-website/src/pages/Documentation.tsx`:

Replace the Kubernetes section with:

```typescript
<h2 className="text-2xl font-bold text-gray-900 mt-8 mb-4">Kubernetes Deployment with Helm</h2>
<p className="text-gray-600 mb-4">
  For production deployments, use our public Helm charts.
</p>

<div className="bg-gray-900 rounded-lg p-6 text-white font-mono text-sm mb-6">
  <div className="mb-2 text-gray-400"># Add MnemoShare Helm repository</div>
  <div className="mb-4">$ helm repo add mnemoshare https://mnemoshare.github.io/helm-charts</div>
  <div className="mb-4">$ helm repo update</div>
  <div className="mb-2 text-gray-400"># Install MnemoShare</div>
  <div>$ helm install mnemoshare mnemoshare/mnemoshare --namespace mnemoshare</div>
</div>
```

## Future Updates (Automatic!)

To release a new chart version:

1. Edit files in `charts/mnemoshare/`
2. Bump version in `charts/mnemoshare/Chart.yaml`:
   ```yaml
   version: 1.0.1  # Increment this
   appVersion: "0.3.2"  # Update if new Docker image
   ```
3. Commit and push to `main`:
   ```bash
   git add charts/mnemoshare/
   git commit -m "Update chart to v1.0.1"
   git push
   ```
4. GitHub Actions automatically packages and publishes!

## Monitoring

- **GitHub Actions:** https://github.com/mnemoshare/helm-charts/actions
- **Releases:** https://github.com/mnemoshare/helm-charts/releases
- **Chart Index:** https://mnemoshare.github.io/helm-charts/index.yaml
- **Artifact Hub:** https://artifacthub.io/packages/search?repo=mnemoshare

## Troubleshooting

### Action fails with "gh-pages branch not found"

This is normal on the first run. The action will create the branch automatically.

### Chart not appearing in search

Wait 5-10 minutes after the action completes, then:
```bash
helm repo update
helm search repo mnemoshare
```

### Artifact Hub not updating

Artifact Hub scans repositories periodically (every few hours). You can trigger a manual scan from the Artifact Hub control panel.

## Support

Questions? Email support@mnemoshare.com
