#!/usr/bin/env bash
# Validates all 12 SWIM CI pipelines one by one (JAR build mode).
# Each PipelineRun is deleted after completion to free cluster resources.
set -euo pipefail

NAMESPACE="swim-pipeline"
REGISTRY="image-registry.openshift-image-registry.svc:5000/swim-demo"
TIMEOUT_SECS=900   # 15 min per pipeline
RESULTS=()

run_pipeline() {
  local pipeline="$1"
  local git_url="$2"
  local image_suffix="$3"

  echo ""
  echo "════════════════════════════════════════════════════════════"
  echo "  Pipeline : ${pipeline}"
  echo "  Repo     : ${git_url}"
  echo "  Image    : ${REGISTRY}/${image_suffix}:latest"
  echo "════════════════════════════════════════════════════════════"

  local run_name
  run_name=$(oc create -f - -o name <<EOF
apiVersion: tekton.dev/v1
kind: PipelineRun
metadata:
  generateName: validate-${image_suffix}-
  namespace: ${NAMESPACE}
  labels:
    swim.validate/batch: "all-pipelines"
spec:
  pipelineRef:
    name: ${pipeline}
  params:
    - name: git-url
      value: "${git_url}"
    - name: git-revision
      value: main
    - name: image-name
      value: "${REGISTRY}/${image_suffix}"
    - name: image-tag
      value: latest
    - name: build-native
      value: "false"
    - name: dockerfile
      value: src/main/docker/Containerfile.jvm
  workspaces:
    - name: shared-workspace
      volumeClaimTemplate:
        spec:
          accessModes:
            - ReadWriteOnce
          resources:
            requests:
              storage: 10Gi
    - name: maven-cache
      persistentVolumeClaim:
        claimName: maven-repo-pvc
    - name: docker-credentials
      secret:
        secretName: internal-registry-auth
    - name: git-token
      secret:
        secretName: gitea-token
EOF
  )

  local run_short="${run_name#pipelinerun.tekton.dev/}"
  echo "  PipelineRun: ${run_short}"
  echo "  Waiting up to ${TIMEOUT_SECS}s..."

  local elapsed=0
  local result="TIMEOUT"
  while [ ${elapsed} -lt ${TIMEOUT_SECS} ]; do
    sleep 30
    elapsed=$((elapsed + 30))

    local succeeded
    succeeded=$(oc get pipelinerun "${run_short}" -n "${NAMESPACE}" \
      -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].status}' 2>/dev/null || echo "")

    local reason
    reason=$(oc get pipelinerun "${run_short}" -n "${NAMESPACE}" \
      -o jsonpath='{.status.conditions[?(@.type=="Succeeded")].reason}' 2>/dev/null || echo "")

    if [ "${succeeded}" = "True" ]; then
      result="SUCCESS"
      break
    elif [ "${succeeded}" = "False" ]; then
      result="FAILED (${reason})"
      # Print last logs for debugging
      echo "  ── FAILURE DETAILS ──"
      oc get pipelinerun "${run_short}" -n "${NAMESPACE}" \
        -o jsonpath='{.status.conditions[0].message}' 2>/dev/null || true
      echo ""
      break
    fi

    echo "  [${elapsed}s] Still running... (${reason:-Pending})"
  done

  echo "  RESULT: ${result}"
  echo "  Deleting PipelineRun ${run_short}..."
  oc delete pipelinerun "${run_short}" -n "${NAMESPACE}" --wait=false 2>/dev/null || true

  RESULTS+=("${pipeline}: ${result}")
}

echo "═══════════════════════════════════════════════"
echo "  SWIM Pipeline Validation — All 12 Services"
echo "  Mode: JAR (build-native=false)"
echo "═══════════════════════════════════════════════"
echo "Start: $(date)"

# ── Validators (dep-repos: swim-developer-validators) ──
run_pipeline "swim-dnotam-consumer-validator-ci" \
  "http://gitea-http.gitea.svc.cluster.local:3000/swimadmin/swim-dnotam-consumer-validator.git" \
  "swim-dnotam-consumer-validator"

run_pipeline "swim-dnotam-provider-validator-ci" \
  "http://gitea-http.gitea.svc.cluster.local:3000/swimadmin/swim-dnotam-provider-validator.git" \
  "swim-dnotam-provider-validator"

run_pipeline "swim-ed254-consumer-validator-ci" \
  "http://gitea-http.gitea.svc.cluster.local:3000/swimadmin/swim-ed254-consumer-validator.git" \
  "swim-ed254-consumer-validator"

run_pipeline "swim-ed254-provider-validator-ci" \
  "http://gitea-http.gitea.svc.cluster.local:3000/swimadmin/swim-ed254-provider-validator.git" \
  "swim-ed254-provider-validator"

run_pipeline "swim-ffice-consumer-validator-ci" \
  "http://gitea-http.gitea.svc.cluster.local:3000/swimadmin/swim-ffice-consumer-validator.git" \
  "swim-ffice-consumer-validator"

run_pipeline "swim-ffice-provider-validator-ci" \
  "http://gitea-http.gitea.svc.cluster.local:3000/swimadmin/swim-ffice-provider-validator.git" \
  "swim-ffice-provider-validator"

# ── DNOTAM services (dep-repos: framework + extensions + aixm) ──
run_pipeline "swim-dnotam-consumer-ci" \
  "http://gitea-http.gitea.svc.cluster.local:3000/swimadmin/swim-digital-notam-consumer.git" \
  "swim-dnotam-consumer"

run_pipeline "swim-dnotam-provider-ci" \
  "http://gitea-http.gitea.svc.cluster.local:3000/swimadmin/swim-digital-notam-provider.git" \
  "swim-dnotam-provider"

# ── ED-254 services (dep-repos: framework + extensions + fixm) ──
run_pipeline "swim-ed254-consumer-ci" \
  "http://gitea-http.gitea.svc.cluster.local:3000/swimadmin/swim-ed254-consumer.git" \
  "swim-ed254-consumer"

run_pipeline "swim-ed254-provider-ci" \
  "http://gitea-http.gitea.svc.cluster.local:3000/swimadmin/swim-ed254-provider.git" \
  "swim-ed254-provider"

# ── FF-ICE services (dep-repos: framework + extensions + fixm-ffice) ──
run_pipeline "swim-ffice-consumer-ci" \
  "http://gitea-http.gitea.svc.cluster.local:3000/swimadmin/swim-ffice-consumer.git" \
  "swim-ffice-consumer"

run_pipeline "swim-ffice-provider-ci" \
  "http://gitea-http.gitea.svc.cluster.local:3000/swimadmin/swim-ffice-provider.git" \
  "swim-ffice-provider"

echo ""
echo "═══════════════════════════════════════════════"
echo "  FINAL RESULTS"
echo "═══════════════════════════════════════════════"
for r in "${RESULTS[@]}"; do
  echo "  ${r}"
done
echo ""
echo "End: $(date)"
