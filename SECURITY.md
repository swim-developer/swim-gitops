# Security — swim-gitops

## What this repository contains

- Public Kubernetes/OpenShift manifests, Helm values, and Tekton pipeline definitions.
- Passwords in YAML files are **CRC/local demo credentials only** (for example `swim`, `admin`, `swim123`) and sample Keycloak client secrets for the demo realm.
- **Do not use these values in production.**

## What must not be committed

| Forbidden | Configure instead |
|-----------|-------------------|
| Quay.io or GitHub tokens | `oc create secret` in namespace `swim-pipeline` |
| Real TLS material (`.pem`, `.key`, `.p12`, `.jks`) | cert-manager in the cluster |
| `keycloak-swim-role-spi.jar` | Fetched at deploy time from GitHub Release into cluster secret (not stored in git) |
| Personal kubeconfig | Local environment only |
| `pull-secret.txt` / Red Hat pull secret JSON | [Download](https://console.redhat.com/openshift/create/local); repo root, `.gitignore` only; `make crc-start` |
| Production or regulatory passwords | Private overlays or Sealed Secrets (future) |

## Before each push

```bash
./scripts/pre-push-security-check.sh
```

## Production

For operational ANSP/INSP environments:

1. Replace all demo passwords in overlays.
2. Use [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets) or External Secrets Operator.
3. Configure Argo CD sync policy (manual sync or approval) per your audit requirements.
4. Never copy cluster secrets (`oc get secret -o yaml`) into git.

## Reporting issues

Open an issue on `swim-developer/swim-gitops` without attaching real secrets.
