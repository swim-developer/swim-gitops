#!/usr/bin/env bash
# Initializes Gitea after first deployment on CRC:
#   - Creates the admin user (swimadmin) via the Gitea CLI inside the pod
#   - Creates the swim-gitops repository via the Gitea API
#   - Creates service repositories for CI release artifacts
#   - Generates an API token and stores it as a K8s Secret for Tekton
set -euo pipefail

GITEA_NS="${GITEA_NS:-gitea}"
GITEA_ROUTE="${GITEA_ROUTE:-https://gitea.apps-crc.testing}"
GITEA_ADMIN_USER="${GITEA_ADMIN_USER:-swimadmin}"
GITEA_ADMIN_PASS="${GITEA_ADMIN_PASS:-Swim@Local1}"
GITEA_ADMIN_EMAIL="${GITEA_ADMIN_EMAIL:-swim@localhost}"
PIPELINE_NS="${PIPELINE_NS:-swim-pipeline}"

REPOS=(
  "swim-gitops:SWIM GitOps — local CRC mirror"
  # Shared libraries (CI dependency repos)
  "swim-developer-root:Parent POM for SWIM projects"
  "swim-developer-framework:SWIM Developer Framework"
  "swim-developer-extensions:SWIM Developer Extensions"
  "swim-developer-validators:SWIM Developer Validators"
  "swim-aixm-model:AIXM data model (DNOTAM)"
  "swim-fixm-model-ed254:FIXM data model (ED-254)"
  "swim-fixm-ffice-model:FIXM FF-ICE data model"
  # DNOTAM stack
  "swim-digital-notam-consumer:DNOTAM Consumer service"
  "swim-dnotam-consumer-validator:DNOTAM Consumer Validator service"
  "swim-digital-notam-provider:DNOTAM Provider service"
  "swim-dnotam-provider-validator:DNOTAM Provider Validator service"
  # ED-254 stack
  "swim-ed254-consumer:ED-254 Consumer service"
  "swim-ed254-consumer-validator:ED-254 Consumer Validator service"
  "swim-ed254-provider:ED-254 Provider service"
  "swim-ed254-provider-validator:ED-254 Provider Validator service"
  # FF-ICE stack
  "swim-ffice-consumer:FF-ICE Consumer service"
  "swim-ffice-consumer-validator:FF-ICE Consumer Validator service"
  "swim-ffice-provider:FF-ICE Provider service"
  "swim-ffice-provider-validator:FF-ICE Provider Validator service"
)

echo ""
echo "==> Gitea init: ${GITEA_ROUTE}"
echo ""

echo "    Waiting for Gitea pod..."
oc rollout status deployment/gitea -n "${GITEA_NS}" --timeout=300s

GITEA_POD=$(oc get pod -n "${GITEA_NS}" -l app.kubernetes.io/name=gitea -o jsonpath='{.items[0].metadata.name}')
echo "    Pod: ${GITEA_POD}"

oc exec -n "${GITEA_NS}" "${GITEA_POD}" -- \
  /app/gitea/gitea admin user create \
  --username "${GITEA_ADMIN_USER}" \
  --password "${GITEA_ADMIN_PASS}" \
  --email "${GITEA_ADMIN_EMAIL}" \
  --admin \
  --must-change-password=false 2>/dev/null \
  && echo "    Admin user '${GITEA_ADMIN_USER}' created." \
  || echo "    Admin user '${GITEA_ADMIN_USER}' already exists."

echo "    Waiting for Gitea HTTP API..."
for i in $(seq 1 30); do
  STATUS=$(curl -sk -o /dev/null -w "%{http_code}" "${GITEA_ROUTE}/api/v1/version" 2>/dev/null || true)
  [ "${STATUS}" = "200" ] && break
  sleep 5
done
echo "    Gitea API reachable."

# ── Create all repositories ──────────────────────────────────────────────
for entry in "${REPOS[@]}"; do
  REPO_NAME="${entry%%:*}"
  REPO_DESC="${entry#*:}"
  HTTP=$(curl -sk -o /dev/null -w "%{http_code}" \
    -X POST "${GITEA_ROUTE}/api/v1/user/repos" \
    -H "Content-Type: application/json" \
    -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}" \
    -d "{
      \"name\": \"${REPO_NAME}\",
      \"description\": \"${REPO_DESC}\",
      \"private\": false,
      \"default_branch\": \"main\",
      \"auto_init\": true
    }" 2>/dev/null)

  case "${HTTP}" in
    201) echo "    Repo '${REPO_NAME}' created." ;;
    409) echo "    Repo '${REPO_NAME}' already exists." ;;
    *)   echo "    WARNING: HTTP ${HTTP} creating '${REPO_NAME}'." ;;
  esac
done

# ── Create API token and store as K8s Secret for Tekton ──────────────────
TOKEN_RESPONSE=$(curl -sk \
  -X POST "${GITEA_ROUTE}/api/v1/users/${GITEA_ADMIN_USER}/tokens" \
  -H "Content-Type: application/json" \
  -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}" \
  -d '{"name": "swim-ci-token", "scopes": ["write:repository","write:issue"]}' 2>/dev/null)

TOKEN=$(echo "${TOKEN_RESPONSE}" | grep -oE '"(sha1|token)"\s*:\s*"[^"]*"' | head -1 | sed 's/.*:.*"\(.*\)"/\1/' 2>/dev/null || true)

if [ -n "${TOKEN}" ]; then
  echo ""
  echo "    API token created."

  oc create namespace "${PIPELINE_NS}" 2>/dev/null || true
  oc create secret generic gitea-token \
    --from-literal=token="${TOKEN}" \
    -n "${PIPELINE_NS}" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null
  echo "    Secret 'gitea-token' stored in namespace '${PIPELINE_NS}'."
else
  echo "    API token 'swim-ci-token' already exists (reusing)."
fi

echo ""
echo "==> Gitea init complete."
echo ""
echo "    Next steps:"
echo "      make gitea-push       Push swim-gitops to Gitea"
echo "      make gitea-mirror     Mirror service and library repos from GitHub to Gitea"
echo ""
