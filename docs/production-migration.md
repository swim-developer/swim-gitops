# SWIM GitOps — Production Migration Guide

This guide describes how to take the SWIM environment validated on OpenShift
Local (CRC) and deploy it to any production OpenShift 4.14+ cluster. Image
registries and Git sources are **fully configurable** — no hardcoded URLs
exist in CI/CD files or Helm charts.

---

## Prerequisites

| Item | Minimum version |
|------|-----------------|
| OpenShift | 4.14 |
| `oc` CLI | compatible with the target cluster |
| Cluster admin access | `cluster-admin` role |
| Git server | GitHub, GitLab, Gitea, Bitbucket, etc. |
| Image registry | OpenShift internal, Quay.io, Harbor, etc. |

---

## Step 1 — Fork/clone the swim-gitops repository

Argo CD on the production cluster needs read access to a Git repository you
control.

```bash
git clone https://github.com/swim-developer/swim-gitops.git
cd swim-gitops
git remote add production https://github.com/<your-org>/swim-gitops.git
git push production main
```

Similarly, clone all service and dependency repositories into your production
Git server (the same repositories mirrored to Gitea in the CRC tutorial).

---

## Step 2 — Reconfigure the Git source (the key step)

All Argo CD Application definitions, Tekton CI pipelines, tasks, and bootstrap
files default to the CRC-local Gitea URL. A single command replaces every
occurrence with your production Git server:

```bash
# GitHub
make configure-git GIT_REPO_BASE=https://github.com/my-org

# GitLab
make configure-git GIT_REPO_BASE=https://gitlab.com/my-group

# Self-hosted Gitea / Forgejo
make configure-git GIT_REPO_BASE=https://git.mycompany.com/swim
```

This updates:
- `argocd/applications/**/*.yaml` — every `repoURL` field
- `argocd/projects/swim.yaml` — `sourceRepos` whitelist
- `ci/tekton/base/pipelines/**/*.yaml` — `git-url` and `dep-repos` defaults
- `ci/tekton/base/tasks/**/*.yaml` — repository references
- `bootstrap/**/*.yaml` — root application source
- `scripts/*.sh` — validation and helper scripts

After running, review the changes and commit:

```bash
git diff
git add -A
git commit -m "Configure Git source: https://github.com/my-org"
git push production main
```

> **Note:** To revert to CRC-local defaults at any time, run:
> ```bash
> git checkout main -- argocd/ ci/ bootstrap/ scripts/
> ```

---

## Step 3 — Choose the image registry

### Option A — OpenShift internal registry

The internal registry is available on every OpenShift 4.x cluster.

```bash
# Expose the external route (needed for push from CI)
oc patch configs.imageregistry.operator.openshift.io/cluster \
  --type merge \
  -p '{"spec":{"defaultRoute":true}}'

REGISTRY=$(oc get route default-route -n openshift-image-registry \
  -o jsonpath='{.spec.host}')
echo "Registry: ${REGISTRY}"
```

Images are accessible at:
`image-registry.openshift-image-registry.svc:5000/<namespace>/<service>:<tag>`

### Option B — Quay.io

```bash
QUAY_USER=<robot-account>
QUAY_TOKEN=<robot-token>
make ci-quay-secret QUAY_USER=${QUAY_USER} QUAY_TOKEN=${QUAY_TOKEN}
```

### Option C — Harbor or another private registry

Follow the same procedure as Quay.io with your registry credentials.

---

## Step 4 — Environment-specific Helm values

Create a production overlay for each service:

```bash
# Example for ed254-consumer
mkdir -p apps/ed254/consumer/overlays/production
cp apps/ed254/consumer/overlays/crc-local/values.yaml \
   apps/ed254/consumer/overlays/production/values.yaml
```

Key values to adjust:

| Value | CRC default | Production |
|-------|-------------|------------|
| `image.repository` | `image-registry...svc:5000/swim-demo/...` | `quay.io/my-org/...` |
| `certManager.issuerKind` | `Issuer` | `ClusterIssuer` |
| `certManager.issuerName` | `swim-ca-issuer` | your production issuer |
| Resource requests/limits | minimal | sized for production load |

Update the Argo CD Application definitions to reference the production
overlay path if you create a separate directory.

---

## Step 5 — Install OpenShift GitOps (Argo CD)

```bash
oc login https://api.<your-cluster>:6443 -u <user> -p <password>
make gitops-install
make gitops-wait
```

---

## Step 6 — Bootstrap Argo CD

```bash
make gitops-bootstrap SWIM_STACKS=all
```

Argo CD will sync and deploy all SWIM applications automatically.

---

## Step 7 — Install Tekton CI

```bash
# Internal registry:
make ci-registry-setup
make ci-install-crc

# External registry (Quay.io):
make ci-quay-secret QUAY_USER=<user> QUAY_TOKEN=<token>
make ci-install
```

---

## Step 8 — Configure webhooks

After Tekton is installed, get the EventListener URL:

```bash
oc get route el-swim-pipelines -n swim-pipeline -o jsonpath='{.spec.host}'
```

Configure webhooks on your Git server for each service repository:
- **Payload URL:** `https://<el-route>/`
- **Content-Type:** `application/json`
- **Events:** `push`

---

## Step 9 — Validate the full flow

```bash
# Run a pipeline manually
make ci-run CI_SERVICE=ed254-consumer-validator

# Check pipeline status
make ci-status

# Check Argo CD sync status
make argocd-status

# Verify pods
oc get pods -n swim-demo
```

---

## Environment comparison reference

| Component | CRC Local | Production OpenShift |
|-----------|-----------|----------------------|
| Git server | Gitea (local, in-cluster) | GitHub / GitLab / Gitea (external) |
| Git URL config | `make configure-git` (default: Gitea) | `make configure-git GIT_REPO_BASE=...` |
| Image registry | OpenShift internal | OpenShift internal or Quay.io |
| Release artifacts | Gitea releases | GitHub Releases / Gitea releases |
| CI secrets | `internal-registry-auth` | `internal-registry-auth` or `quay-push-auth` |
| TLS certificates | Self-signed `Issuer` | CA-issued `ClusterIssuer` |
| Resource sizing | Minimal (8 CPU, 20 GB) | Sized for production load |

---

## Architecture: no hardcoded URLs

The SWIM GitOps repository follows a strict principle: **no URL is hardcoded**.
Every Git reference is configurable through the `GIT_REPO_BASE` Makefile
variable. The `make configure-git` command performs a global replacement across
all YAML and shell files, ensuring consistency.

```
┌─────────────────────────┐
│    GIT_REPO_BASE        │  ← single variable
└──────────┬──────────────┘
           │
    ┌──────┴──────┐
    │  configure  │  ← make configure-git
    │    -git     │
    └──────┬──────┘
           │ replaces URLs in:
           ├── argocd/applications/**/*.yaml   (Argo CD repoURL)
           ├── argocd/projects/swim.yaml       (sourceRepos)
           ├── ci/tekton/base/pipelines/*.yaml (git-url defaults)
           ├── ci/tekton/base/tasks/*.yaml     (clone URLs)
           ├── bootstrap/**/*.yaml             (root app source)
           └── scripts/*.sh                    (validation helpers)
```

This design allows the same repository to be used for CRC-local development
(Gitea), staging (self-hosted GitLab), and production (GitHub) by simply
changing one variable.
