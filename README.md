# swim-gitops

Public delivery repository for the [SWIM Developer](https://github.com/swim-developer) ecosystem: **CI** (Tekton) and **CD** (Argo CD / OpenShift GitOps).

Covers **three SWIM stacks**: DNOTAM, ED-254, and FF-ICE — each with consumer, provider, consumer-validator, and provider-validator.

## Repository structure

```
swim-gitops/
├── bootstrap/              # Root App-of-Apps (GitHub and Gitea variants)
├── platform/
│   ├── operators/          # OLM Subscriptions (cert-manager, AMQ, RHBK)
│   ├── gitops/             # OpenShift GitOps operator
│   ├── gitea/              # Gitea Helm chart (local Git server for CRC)
│   └── rbac/               # Argo CD namespace permissions
├── infra/
│   ├── swim-core-infra/    # PKI, Kafka cluster, Keycloak
│   ├── swim-shared-brokers/# AMQ Artemis broker instances
│   ├── swim-dnotam-infra/  # DNOTAM Kafka topics, MongoDB, MariaDB, PostgreSQL
│   ├── swim-ed254-infra/   # ED-254 Kafka topics, MongoDB, MariaDB, PostgreSQL
│   └── swim-ffice-infra/   # FF-ICE Kafka topics, MongoDB, MariaDB, PostgreSQL
├── apps/
│   ├── dnotam/             # consumer, provider, validators (values overlays)
│   ├── ed254/              # consumer, provider, validators (values overlays)
│   └── ffice/              # consumer, provider, validators (values overlays)
├── argocd/
│   ├── applications/
│   │   ├── common/         # Platform operators, core infra, shared brokers, Gitea
│   │   ├── dnotam/         # DNOTAM infra + services + validators
│   │   ├── ed254/          # ED-254 infra + services + validators
│   │   └── ffice/          # FF-ICE infra + services + validators
│   └── projects/           # AppProject 'swim'
├── ci/tekton/
│   ├── base/               # 12 pipelines, 9 tasks, triggers, RBAC
│   └── overlays/
│       ├── crc-local/      # Internal registry + Gitea patches
│       └── openshift/      # Quay.io + GitHub patches
├── config/                 # swim.env.example (user-configurable)
├── docs/                   # production-migration.md, deployment-paths.md
└── scripts/                # gitea-init.sh, validate-all-pipelines.sh
```

## Quick start — from zero to working on CRC

> **Requirements**: macOS, Linux, or Windows (PowerShell). On Windows, bash is auto-detected from Git for Windows — no PATH changes needed.
>
> | Tool | Install |
> |------|---------|
> | [Helm](https://helm.sh/docs/intro/install/) | `choco install kubernetes-helm` (Win) · `brew install helm` (macOS) · `snap install helm --classic` (Linux) |
> | GNU Make | `choco install make` (Win) · pre-installed (macOS/Linux) |
> | Git | [gitforwindows.org](https://gitforwindows.org/) (Win) · pre-installed (macOS/Linux) |
>
> Resources depend on how many stacks you deploy:
>
> | Stacks | CPUs | RAM | Command |
> |--------|------|-----|---------|
> | 1 stack (e.g. DNOTAM only — **default**) | 8 | **20 GB** | `make crc-setup` |
> | All 3 stacks (DNOTAM + ED-254 + FF-ICE) | 10 | **24 GB** | `make crc-setup SWIM_STACKS=all` |
>
> Disk is set to 100 GB by default. All values are customizable:
> `make crc-setup CRC_CPUS=4 CRC_MEMORY_MB=16384 CRC_DISK_GB=80`

### Step 1 — Install and start OpenShift Local (CRC)

```bash
# One-time setup — defaults to DNOTAM only (8 CPUs, 20 GB RAM, 100 GB disk)
make crc-setup

# Or, for all 3 stacks (8 CPUs, 24 GB RAM):
# make crc-setup SWIM_STACKS=all

# Download pull-secret.txt from https://console.redhat.com/openshift/create/local
cp ~/Downloads/pull-secret.txt ./pull-secret.txt

# Start CRC (first run takes a few minutes)
make crc-start
```

### Step 2 — Point `oc` to CRC

```bash
eval $(crc oc-env)
make crc-use-local
```

> **Windows:** The Makefile automatically adds CRC's `oc` to PATH, so `make` targets work without manual setup.
> If you need `oc` outside of `make` (e.g. running `oc` commands directly in PowerShell), run:
> `crc oc-env --shell powershell | Invoke-Expression`

### Step 3 — Deploy Gitea (local Git server)

Gitea is the local Git server that Argo CD will read from. It must be deployed **before** Argo CD bootstrap:

```bash
make gitea-deploy         # Installs Gitea via Helm (requires helm CLI)
make gitea-init           # Creates admin user + swim-gitops repo in Gitea
make gitea-push           # Pushes this repo to Gitea
```

Gitea UI: `https://gitea.apps-crc.testing` — login: `swimadmin` / `Swim@Local1`

### Step 4 — Install Argo CD and bootstrap GitOps

```bash
make gitops-install       # Installs OpenShift GitOps operator
make gitops-bootstrap     # Argo CD reads from Gitea, deploys selected stacks

# To deploy all stacks:
# make gitops-bootstrap SWIM_STACKS=all
```

Wait for platform operators to install:

```bash
make operators-wait       # Waits for cert-manager, AMQ, RHBK CRDs
make argocd-status        # Shows all Argo CD Application states
```

### Step 5 — Create Artemis TLS Secrets

All SWIM components use mTLS. Certificates are provisioned automatically by cert-manager — Keycloak, Kafka, and services consume PEM directly. Artemis is the only component that needs JKS (Java KeyStore), so we convert the PEM certificates:

```bash
make artemis-ssl
```

> Run this after `swim-core-infra` and `swim-shared-brokers` show `Synced/Healthy` in `make argocd-status`.

### Step 6 — Bootstrap Pre-built Images

Import pre-built images from Quay.io into the internal registry so all services start immediately:

```bash
make ci-bootstrap-images
```

This uses `skopeo` to copy the latest images from `quay.io/masales` into the cluster's internal registry. Pods that were in `ImagePullBackOff` will automatically pull the imported images and start running.

> These images serve as a baseline. In the next steps, CI pipelines build from source and overwrite them.

### Step 7 — Install Tekton CI

```bash
make ci-install-crc       # Pipelines, tasks, triggers, registry credentials
```

### Step 8 — Run a CI pipeline (validate)

```bash
make ci-run                                        # Builds dnotam-consumer-validator (default)
make ci-run CI_SERVICE=dnotam-provider-validator    # Or specify another service
make ci-status                                     # Check pipeline results
```

Each pipeline clones the source, compiles a JAR, creates a release in Gitea, and pushes a container image to the internal registry — overwriting the pre-built images from Step 6.

### Step 9 — Validate all DNOTAM pipelines

```bash
make ci-run CI_SERVICE=dnotam-consumer-validator
make ci-run CI_SERVICE=dnotam-provider-validator
make ci-run CI_SERVICE=dnotam-consumer
make ci-run CI_SERVICE=dnotam-provider
make ci-status
```

## Build modes

| Parameter | Value | What it does | Resources needed |
|-----------|-------|-------------|-----------------|
| `build-native` | `"false"` (default) | Quarkus fast-jar (JVM) | ~1 Gi RAM, 500m CPU |
| `build-native` | `"true"` | GraalVM native binary | 12+ Gi RAM, 4+ CPUs |

The `dockerfile` parameter selects the container image base:
- `src/main/docker/Containerfile.jvm` (default, for JAR builds)
- `src/main/docker/Containerfile.native-micro` (for native builds)

## Available pipelines (12)

| Pipeline | Service repo | dep-repos |
|----------|-------------|-----------|
| `swim-dnotam-consumer-validator-ci` | swim-dnotam-consumer-validator | swim-developer-validators |
| `swim-dnotam-provider-validator-ci` | swim-dnotam-provider-validator | swim-developer-validators |
| `swim-ed254-consumer-validator-ci` | swim-ed254-consumer-validator | swim-developer-validators |
| `swim-ed254-provider-validator-ci` | swim-ed254-provider-validator | swim-developer-validators |
| `swim-dnotam-consumer-ci` | swim-digital-notam-consumer | framework + extensions + aixm-model |
| `swim-dnotam-provider-ci` | swim-digital-notam-provider | framework + extensions + aixm-model |
| `swim-ed254-consumer-ci` | swim-ed254-consumer | framework + extensions + fixm-ed254 |
| `swim-ed254-provider-ci` | swim-ed254-provider | framework + extensions + fixm-ed254 |
| `swim-ffice-consumer-validator-ci` | swim-ffice-consumer-validator | swim-developer-validators |
| `swim-ffice-provider-validator-ci` | swim-ffice-provider-validator | swim-developer-validators |
| `swim-ffice-consumer-ci` | swim-ffice-consumer | framework + extensions + fixm-ffice |
| `swim-ffice-provider-ci` | swim-ffice-provider | framework + extensions + fixm-ffice |

## Argo CD sync waves

| Wave | Application | Content |
|------|-------------|---------|
| 0 | `swim-platform-operators` | OLM subscriptions (cert-manager, AMQ, RHBK) |
| 1 | `swim-core-infra` | PKI, Kafka cluster, Keycloak |
| 2 | `swim-shared-brokers`, `swim-*-infra` | Artemis brokers, Kafka topics, databases |
| 4 | Validators | MariaDB + validator services |
| 5 | Consumers, Providers | MongoDB/PostgreSQL + service deployments |

## Makefile targets

Run `make help` for the full list. Key targets:

| Target | What it does |
|--------|-------------|
| `make crc-setup` | One-time CRC configuration (auto-sizes RAM by SWIM_STACKS) |
| `make crc-start` | Start CRC with pull secret |
| `make crc-use-local` | Switch `oc` context to CRC |
| `make gitops-install` | Install OpenShift GitOps operator |
| `make gitops-bootstrap` | Deploy common infra + selected stacks (SWIM_STACKS) |
| `make argocd-status` | Show Argo CD Application states |
| `make operators-wait` | Wait for platform operator CRDs |
| `make artemis-ssl` | Create Artemis TLS secrets |
| `make gitea-deploy` | Install Gitea via Helm (before Argo CD) |
| `make gitea-init` | Initialize Gitea (admin user + repo) |
| `make gitea-push` | Push swim-gitops to Gitea |
| `make ci-bootstrap-images` | Import pre-built Quay.io images into internal registry |
| `make ci-install-crc` | Apply Tekton CI (CRC overlay: internal registry + credentials) |
| `make ci-install` | Apply Tekton CI (OpenShift overlay: Quay.io) |
| `make ci-run` | Run a pipeline manually (`CI_SERVICE=dnotam-consumer-validator`) |
| `make ci-status` | Show PipelineRun results |

## Configuring for your environment

Copy and edit `config/swim.env.example`:

```bash
cp config/swim.env.example config/swim.env
# Edit with your registry, Git server, and credentials
```

See [docs/production-migration.md](docs/production-migration.md) for step-by-step instructions to deploy on any OpenShift cluster.

## Deployment paths

Two paths are supported: **GitOps (Argo CD)** — recommended — and **Operator** (legacy). See [docs/deployment-paths.md](docs/deployment-paths.md) for a comparison and migration guide.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `swim-gitops-root` Unknown / InvalidSpecError | `oc apply -f argocd/projects/swim.yaml -n openshift-gitops` |
| App stays OutOfSync | `oc get application <name> -n openshift-gitops -o yaml` → check `status.operationState.message` |
| `oc` hits wrong cluster | `eval $(crc oc-env) && make crc-use-local` |
| Kafka NotReady UnsupportedVersion | Check `infra/overlays/crc-local/values.yaml` Kafka version matches AMQ Streams |
| PipelineRun Pending (insufficient resources) | Scale down unused services or use `build-native: "false"` |
| Buildah push TLS error | CRC overlay sets `TLSVERIFY: "false"` for internal registry |
| git-clone fails in Tekton | Ensure repos are public or provide Git credentials secret |

## References

- [OpenGitOps](https://opengitops.dev/)
- [Red Hat OpenShift GitOps](https://docs.openshift.com/gitops/)
- [Tekton](https://tekton.dev/)
- [swim-deploy-openshift-local](https://github.com/swim-developer/swim-deploy-openshift-local)
