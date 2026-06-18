# SWIM Deployment Paths — GitOps vs Operator

This document describes the two supported deployment paths for SWIM services on OpenShift / Kubernetes. **GitOps (Argo CD)** is the recommended path for new deployments. The **Operator** path remains available as a legacy alternative.

---

## Overview

| Aspect | GitOps (Argo CD) | Operator (swim-openshift-operator) |
|--------|-----------------|--------------------------|
| **Status** | **Recommended** — actively maintained | Legacy — optional, frozen |
| **Repository** | [swim-developer/swim-gitops](https://github.com/swim-developer/swim-gitops) | [swim-developer/swim-openshift-operator](https://github.com/swim-developer/swim-openshift-operator) |
| **Target audience** | INSPs, ANSPs, community contributors | Advanced users comfortable with Go operators |
| **Prerequisites** | OpenShift GitOps or Argo CD, Tekton/OpenShift Pipelines | OLM, Go toolchain (for development) |
| **Infrastructure** | Helm charts (declarative CRs for Kafka, Artemis, DBs) | Operator creates infrastructure per CR |
| **Audit trail** | Full Git history — every change is a merge/commit | CR spec changes, controller logs |
| **Rollback** | `git revert` + Argo CD sync | Delete/recreate CR |
| **RBAC** | AppProject per stack, CODEOWNERS per folder | Namespace-scoped operator RBAC |
| **Stacks covered** | DNOTAM, ED-254, FF-ICE (Phases 1–3) | DNOTAM, ED-254 (partial FF-ICE) |

---

## Path 1: GitOps with Argo CD (Recommended)

### Architecture

```
swim-gitops/
├── platform/operators/     # OLM Subscriptions (cert-manager, AMQ, RHBK)
├── infra/                  # Kafka topics, databases, brokers (Helm charts)
│   ├── swim-core-infra/    # PKI, Kafka cluster, Keycloak
│   ├── swim-shared-brokers/# AMQ Artemis instances
│   ├── swim-dnotam-infra/  # DNOTAM-specific topics, DBs
│   ├── swim-ed254-infra/   # ED-254-specific topics, DBs
│   └── swim-ffice-infra/   # FF-ICE-specific topics, DBs
├── apps/                   # Service overlays (values per environment)
│   ├── dnotam/             # consumer, provider, validators
│   ├── ed254/              # consumer, provider, validators
│   └── ffice/              # consumer, provider, validators
├── argocd/                 # Application and AppProject definitions
├── ci/tekton/              # CI pipelines, tasks, triggers
└── bootstrap/              # Root Application (App of Apps)
```

### Sync Wave Order

| Wave | Components | What happens |
|------|-----------|--------------|
| 0 | `platform-operators` | OLM installs cert-manager, AMQ Streams, AMQ Broker, RHBK |
| 1 | `swim-core-infra` | PKI, Kafka cluster, Keycloak |
| 2 | `swim-shared-brokers`, `swim-*-infra` | Artemis brokers, topics, databases |
| 3–4 | Validators | MariaDB + validator services |
| 5 | Providers/Consumers | Postgres/Mongo + service deployments |

### CI/CD Flow

1. Developer pushes code to a service repo (e.g. `swim-dnotam-consumer-validator`)
2. Tekton pipeline triggers (webhook or manual): clone → build JAR/native → push image
3. CI publishes artifacts: container image (registry), JAR/binary (GitHub/Gitea releases)
4. Argo CD detects change and syncs the new deployment

### Quick Start

```bash
# 1. Install OpenShift GitOps
make gitops-install

# 2. Bootstrap Argo CD (App of Apps)
make gitops-bootstrap

# 3. Wait for all apps to sync
make argocd-status

# 4. (Optional) Install Tekton CI
make ci-install-crc

# 5. (Optional) Run a CI pipeline
oc create -f <pipeline-run.yaml> -n swim-pipeline
```

---

## Path 2: Operator (Legacy, Optional)

### When to use

- You need a single CR to provision an entire SWIM service stack
- Your organization requires operator-based lifecycle management
- You are extending the operator for custom use cases

### Architecture

The `swim-openshift-operator` defines Custom Resources (CRDs) that encapsulate each SWIM service:

```yaml
apiVersion: swim.github.com/v1alpha1
kind: SwimDigitalNotamProvider
metadata:
  name: dnotam-provider
spec:
  # Operator creates PostgreSQL, Artemis addresses, Kafka topics,
  # and the Quarkus deployment from this single CR
```

### Limitations

| Limitation | Impact |
|-----------|--------|
| Go maintenance required | Not all teams have Go expertise |
| 5 CRDs only in Go (FF-ICE + ED-254 PV) | Incomplete coverage |
| OLM bundle packaging | Complex release process |
| Implicit infrastructure | Harder to audit what is deployed |
| No native GitOps audit trail | Changes are CR patches, not Git commits |

### Usage

```bash
# Install the operator via OLM
oc apply -f swim-openshift-operator/config/samples/catalog-source.yaml
oc apply -f swim-openshift-operator/config/samples/subscription.yaml

# Create a SWIM service
oc apply -f swim-openshift-operator/config/samples/swim_v1alpha1_digitalnotamprovider.yaml
```

---

## Migration: Operator → GitOps

If you are currently using the operator and want to migrate to GitOps:

1. **Inventory**: List all `Swim*` CRs in your cluster
2. **Map**: Each CR corresponds to an infra chart + app chart in `swim-gitops`
3. **Deploy GitOps**: Install Argo CD and bootstrap `swim-gitops` alongside the operator
4. **Validate**: Confirm Argo CD apps are Synced/Healthy
5. **Cutover**: Delete operator CRs (Argo CD now manages the same resources)
6. **Cleanup**: Uninstall the operator subscription

Both paths manage the same underlying resources (Kafka CRs, Artemis CRs, Deployments). They should not run simultaneously for the same service to avoid conflicts.

---

## Decision Matrix for INSPs/ANSPs

| Criteria | Choose GitOps | Choose Operator |
|----------|--------------|-----------------|
| Team has Git/DevOps experience | Yes | — |
| Team has Go/operator experience | — | Yes |
| Audit/compliance requirements | Yes (Git history) | Partial (logs) |
| Multi-environment (dev/staging/prod) | Yes (overlays) | Manual |
| CI/CD automation needed | Yes (Tekton included) | Separate setup |
| Minimal maintenance burden | Yes | No (Go + OLM) |
| Single-command provisioning | No (but scripted) | Yes (one CR) |

**Recommendation**: Start with GitOps. If a specific INSP requires single-CR provisioning, the operator can complement GitOps for that use case.
