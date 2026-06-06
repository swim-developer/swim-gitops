# ── Windows: GNU Make needs bash (provided by Git for Windows) ───────────
# Make on Windows defaults to cmd.exe, which cannot run Bash recipes.
# We derive the bash path from git's install location (git --exec-path),
# which avoids issues with spaces in "Program Files" and disabled 8.3 names.
ifeq ($(OS),Windows_NT)
  _GIT_EXEC := $(subst \,/,$(shell git --exec-path 2>nul))
  ifdef _GIT_EXEC
    SHELL := $(subst /mingw64/libexec/git-core,/usr/bin/bash.exe,$(_GIT_EXEC))
  else
    SHELL := C:/PROGRA~1/Git/usr/bin/bash.exe
  endif
  .SHELLFLAGS := -c
  # Verify bash actually works
  ifeq ($(shell echo ok 2>/dev/null),)
    $(info )
    $(info  ERROR: bash not found at $(SHELL))
    $(info  This Makefile requires bash provided by Git for Windows.)
    $(info  Install:  https://gitforwindows.org  or  choco install git)
    $(info  Then ensure git is in PATH and restart your terminal.)
    $(info )
    $(error bash not found)
  endif
  # Ensure Git for Windows tools (sed, grep, awk ...) and CRC's oc are in PATH.
  # Make invokes bash with -c (non-interactive), so the bash profile that
  # normally sets /usr/bin in PATH is not sourced.
  _GIT_USR_BIN := $(subst /mingw64/libexec/git-core,/usr/bin,$(_GIT_EXEC))
  _CRC_OC_DIR  := $(subst \,/,$(USERPROFILE))/.crc/bin/oc
  export PATH   := $(_GIT_USR_BIN):$(_CRC_OC_DIR):$(PATH)
endif

NS ?= swim-demo

# Repository root (directory of this Makefile)
SWIM_GITOPS_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

# Git source — base URL where Argo CD and Tekton find all repositories.
# CRC-local default uses the in-cluster Gitea service.
# For production, override with your Git server:
#   make configure-git GIT_REPO_BASE=https://github.com/my-org
GIT_REPO_BASE     ?= http://gitea-http.gitea.svc.cluster.local:3000/swimadmin
GIT_REPO_BASE_CRC := http://gitea-http.gitea.svc.cluster.local:3000/swimadmin

# Which SWIM stacks to deploy: dnotam, ed254, ffice, or "all" for everything.
# Default: dnotam only (16 GB RAM). Use SWIM_STACKS=all for the full platform (24 GB RAM).
SWIM_STACKS ?= dnotam
ifeq ($(SWIM_STACKS),all)
  override SWIM_STACKS := dnotam ed254 ffice
endif

.PHONY: help crc-setup crc-check-pull-secret crc-start crc-show-domain crc-use-local \
	gitops-install gitops-wait gitops-bootstrap argocd-status operators operators-wait \
	crc-phase-infra artemis-ssl security-check \
	ci-bootstrap-images ci-install ci-install-crc ci-quay-secret ci-registry-setup ci-status \
	gitea-deploy gitea-wait gitea-init gitea-push gitea-mirror \
	configure-git

CRC_CPUS ?= $(if $(filter 1,$(words $(SWIM_STACKS))),8,10)
CRC_MEMORY_MB ?= $(if $(filter 1,$(words $(SWIM_STACKS))),20480,24576)
CRC_DISK_GB ?= 100
CRC_PULL_SECRET ?= $(SWIM_GITOPS_ROOT)/pull-secret.txt

help:
	@echo ""
	@echo "  swim-gitops — GitOps deployment for SWIM (Argo CD + Tekton CI)"
	@echo ""
	@echo "  SWIM_STACKS=$(SWIM_STACKS)  (override with SWIM_STACKS=\"dnotam ed254 ffice\" or SWIM_STACKS=all)"
	@echo "  CRC_CPUS=$(CRC_CPUS)  CRC_MEMORY_MB=$(CRC_MEMORY_MB)  CRC_DISK_GB=$(CRC_DISK_GB)"
	@echo "  (auto: 8 CPU / 20 GB for 1 stack, 10 CPU / 24 GB for multiple)"
	@echo ""
	@echo "  CRC:"
	@echo "    make crc-setup         crc config ($(CRC_CPUS) CPU, $(CRC_MEMORY_MB) MiB) + crc setup"
	@echo "    make crc-start         crc start (requires ./pull-secret.txt)"
	@echo "    make crc-use-local     Point oc at CRC (context crc-admin)"
	@echo ""
	@echo "  GitOps:"
	@echo "    make gitops-install    Install OpenShift GitOps operator + wait for Argo CD"
	@echo "    make gitops-bootstrap  Deploy common infra + selected stacks (SWIM_STACKS)"
	@echo "    make argocd-status     Application sync/health"
	@echo "    make operators-wait    Wait for platform operator CRDs"
	@echo "    make artemis-ssl       Artemis TLS secrets (after cert-manager is ready)"
	@echo ""
	@echo "  CI (Tekton):"
	@echo "    make ci-bootstrap-images  Import pre-built Quay.io images into internal registry"
	@echo "    make ci-install-crc       Apply Tekton CRC overlay (internal registry)"
	@echo "    make ci-registry-setup    Create internal-registry-auth secret + grant image-builder"
	@echo "    make ci-run               Run a pipeline manually (CI_SERVICE=dnotam-consumer-validator)"
	@echo "    make ci-status            List PipelineRuns"
	@echo ""
	@echo "  Gitea (local Git server — deployed before Argo CD):"
	@echo "    make gitea-deploy      Install Gitea via Helm"
	@echo "    make gitea-init        Create admin user + swim-gitops repo"
	@echo "    make gitea-push        Push swim-gitops to local Gitea"
	@echo "    make gitea-mirror      Mirror all service repos from GitHub to Gitea"
	@echo "    make gitea-wait        Wait for Gitea pod"
	@echo ""
	@echo "  Production migration:"
	@echo "    make configure-git GIT_REPO_BASE=https://github.com/my-org"
	@echo "    (Replaces all Gitea URLs with your production Git server)"
	@echo ""

crc-setup:
	@echo "  Setting CRC resources: $(CRC_CPUS) CPUs, $(CRC_MEMORY_MB) MiB RAM, $(CRC_DISK_GB) GB disk..."
	crc config set cpus $(CRC_CPUS)
	crc config set memory $(CRC_MEMORY_MB)
	crc config set disk-size $(CRC_DISK_GB)
	crc setup

crc-check-pull-secret:
	@if [ ! -f "$(CRC_PULL_SECRET)" ]; then \
		echo ""; \
		echo "  ERROR: pull secret not found:"; \
		echo "         $(CRC_PULL_SECRET)"; \
		echo ""; \
		echo "  Download from: https://console.redhat.com/openshift/create/local"; \
		echo "  Save as pull-secret.txt in the repository root (next to this Makefile)."; \
		echo "  Do not commit this file (listed in .gitignore)."; \
		echo ""; \
		exit 1; \
	fi

crc-start: crc-check-pull-secret
	@echo "  Starting CRC with pull secret: $(CRC_PULL_SECRET)"
	crc config set pull-secret-file "$(CRC_PULL_SECRET)"
	crc start -p "$(CRC_PULL_SECRET)"
	@echo ""
	@echo "  CRC started."
	@echo ""

crc-show-domain:
	@echo ""
	@crc status 2>/dev/null | grep -E 'OpenShift|Ingress|Domain' || true
	@echo ""

crc-use-local:
	@oc config use-context crc-admin 2>/dev/null || true
	@oc whoami --show-server 2>/dev/null || \
		(echo "  ERROR: oc cannot reach CRC. Run 'eval \$$(crc oc-env)' (Linux/macOS) or 'crc oc-env --shell powershell | Invoke-Expression' (Windows)." && exit 1)

gitops-install: crc-use-local
	oc apply -f platform/gitops/
	$(MAKE) gitops-wait

gitops-bootstrap: crc-use-local
	@oc create namespace $(NS) --dry-run=client -o yaml | oc apply -f -
	oc apply -f platform/rbac/argocd-swim-demo.yaml
	oc apply -f argocd/projects/swim.yaml
	oc apply -f bootstrap/root-application.yaml -n openshift-gitops
	@for stack in $(SWIM_STACKS); do \
		echo "  Deploying stack: $$stack"; \
		oc apply -f bootstrap/root-$$stack.yaml -n openshift-gitops; \
	done
	@echo ""
	@echo "  Stacks deployed: $(SWIM_STACKS)"

argocd-status: crc-use-local
	@oc get application -n openshift-gitops -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status

gitops-wait:
	@printf "    OpenShift GitOps subscription..." && \
	until oc get subscription openshift-gitops-operator -n openshift-gitops-operator -o jsonpath='{.status.state}' 2>/dev/null | grep -qE 'AtLatestKnown|UpgradePending'; do sleep 10; done && echo " ok"
	@printf "    OpenShift GitOps CSV..." && \
	until oc get csv -n openshift-gitops-operator -o jsonpath='{.items[?(@.spec.displayName=="Red Hat OpenShift GitOps")].status.phase}' 2>/dev/null | grep -q Succeeded; do sleep 10; done && echo " ok"
	@printf "    openshift-gitops namespace..." && \
	until oc get namespace openshift-gitops >/dev/null 2>&1; do sleep 5; done && echo " ok"
	@printf "    Argo CD server deployment..." && \
	until oc get deployment openshift-gitops-server -n openshift-gitops >/dev/null 2>&1; do sleep 5; done && echo " found"
	@printf "    Argo CD server ready..." && \
	oc wait --for=condition=Available deployment/openshift-gitops-server -n openshift-gitops --timeout=900s >/dev/null && echo " ok"

operators:
	oc apply -f platform/operators/

operators-wait:
	@printf "    Kafka..." && until oc get crd kafkas.kafka.strimzi.io >/dev/null 2>&1; do sleep 5; done && echo " ok"
	@printf "    ClusterIssuer..." && until oc get crd clusterissuers.cert-manager.io >/dev/null 2>&1; do sleep 5; done && echo " ok"
	@printf "    ActiveMQArtemis..." && until oc get crd activemqartemises.broker.amq.io >/dev/null 2>&1; do sleep 5; done && echo " ok"
	@printf "    Keycloak..." && until oc get crd keycloaks.k8s.keycloak.org >/dev/null 2>&1; do sleep 5; done && echo " ok"

crc-phase-infra: crc-use-local operators-wait
	$(MAKE) artemis-ssl

artemis-ssl:
	@. scripts/crc-artemis-ssl-secrets.sh $(NS)

security-check:
	@. scripts/pre-push-security-check.sh

# ── Gitea (deployed independently — Argo CD reads from it) ────────────────

GITEA_NS         ?= gitea
GITEA_ROUTE      ?= https://gitea.apps-crc.testing
GITEA_ADMIN_USER ?= swimadmin
GITEA_ADMIN_PASS ?= Swim@Local1
GITEA_TOKEN      ?=

gitea-deploy: crc-use-local
	@command -v helm >/dev/null 2>&1 || \
		(echo "  ERROR: helm CLI required. Install from https://helm.sh/docs/intro/install/" && exit 1)
	@oc create namespace $(GITEA_NS) --dry-run=client -o yaml | oc apply -f -
	@echo "  Adding Gitea Helm repo..."
	@helm repo add gitea-charts https://dl.gitea.com/charts/ 2>/dev/null || true
	@echo "  Building Gitea Helm chart dependencies..."
	helm dependency build platform/gitea/chart/
	@echo "  Installing Gitea via Helm..."
	helm upgrade --install gitea platform/gitea/chart/ -n $(GITEA_NS) --wait --timeout=300s
	@echo "  Gitea deployed in namespace $(GITEA_NS)."

gitea-wait: crc-use-local
	@printf "    Gitea deployment..."
	@oc rollout status deployment/gitea -n $(GITEA_NS) --timeout=300s >/dev/null && echo " ok"

gitea-init: crc-use-local
	@export GITEA_NS=$(GITEA_NS) GITEA_ROUTE=$(GITEA_ROUTE) \
	 GITEA_ADMIN_USER=$(GITEA_ADMIN_USER) GITEA_ADMIN_PASS=$(GITEA_ADMIN_PASS) && \
	 . scripts/gitea-init.sh

gitea-push: crc-use-local
	@GITEA_URL=$$(echo $(GITEA_ROUTE) | sed 's|https://||'); \
	if [ -n "$(GITEA_TOKEN)" ]; then \
	  CRED="$(GITEA_ADMIN_USER):$(GITEA_TOKEN)"; \
	else \
	  ENCODED_PASS=$$(echo '$(GITEA_ADMIN_PASS)' | sed 's/@/%40/g;s/!/%21/g;s/#/%23/g;s/\$$/%24/g;s/&/%26/g'); \
	  CRED="$(GITEA_ADMIN_USER):$${ENCODED_PASS}"; \
	fi; \
	REMOTE="https://$${CRED}@$${GITEA_URL}/$(GITEA_ADMIN_USER)/swim-gitops.git"; \
	git -C . remote get-url gitea >/dev/null 2>&1 && \
	  git -C . remote set-url gitea "$${REMOTE}" || \
	  git -C . remote add gitea "$${REMOTE}"; \
	GIT_TERMINAL_PROMPT=0 GIT_SSL_NO_VERIFY=true git -c credential.helper= -C . push gitea main --force
	@echo "  swim-gitops pushed to $(GITEA_ROUTE)/$(GITEA_ADMIN_USER)/swim-gitops"

# Mirror all service and dependency repos from GitHub into Gitea so the CRC
# environment has zero dependency on GitHub at runtime.
GITHUB_ORG ?= swim-developer

COMMON_MIRROR_REPOS := swim-developer-root swim-developer-framework swim-developer-extensions swim-developer-validators
DNOTAM_MIRROR_REPOS := swim-aixm-model \
	swim-digital-notam-consumer swim-dnotam-consumer-validator \
	swim-digital-notam-provider swim-dnotam-provider-validator
ED254_MIRROR_REPOS  := swim-fixm-model-ed254 \
	swim-ed254-consumer swim-ed254-consumer-validator \
	swim-ed254-provider swim-ed254-provider-validator
FFICE_MIRROR_REPOS  := swim-fixm-ffice-model \
	swim-ffice-consumer swim-ffice-consumer-validator \
	swim-ffice-provider swim-ffice-provider-validator

MIRROR_REPOS = $(COMMON_MIRROR_REPOS) \
	$(if $(filter all,$(SWIM_STACKS)),\
	  $(DNOTAM_MIRROR_REPOS) $(ED254_MIRROR_REPOS) $(FFICE_MIRROR_REPOS),\
	  $(foreach s,$(SWIM_STACKS),$($(shell echo $(s) | tr a-z A-Z)_MIRROR_REPOS)))

gitea-mirror: crc-use-local
	@GITEA_URL=$$(echo $(GITEA_ROUTE) | sed 's|https://||'); \
	if [ -n "$(GITEA_TOKEN)" ]; then \
	  CRED="$(GITEA_ADMIN_USER):$(GITEA_TOKEN)"; \
	else \
	  ENCODED_PASS=$$(echo '$(GITEA_ADMIN_PASS)' | sed 's/@/%40/g;s/!/%21/g;s/#/%23/g;s/\$$/%24/g;s/&/%26/g'); \
	  CRED="$(GITEA_ADMIN_USER):$${ENCODED_PASS}"; \
	fi; \
	TMPDIR=$$(mktemp -d); \
	echo ""; \
	echo "  Mirroring repos from github.com/$(GITHUB_ORG) to Gitea..."; \
	echo "  Repos: $(MIRROR_REPOS)"; \
	echo ""; \
	for repo in $(MIRROR_REPOS); do \
		printf "    $$repo ... "; \
		if git clone --bare "https://github.com/$(GITHUB_ORG)/$$repo.git" "$$TMPDIR/$$repo.git" 2>/dev/null; then \
			GIT_SSL_NO_VERIFY=true GIT_TERMINAL_PROMPT=0 \
			  git -c credential.helper= -C "$$TMPDIR/$$repo.git" push --mirror \
			  "https://$${CRED}@$${GITEA_URL}/$(GITEA_ADMIN_USER)/$$repo.git" 2>/dev/null && \
			  echo "ok" || echo "FAILED (push)"; \
		else \
			echo "SKIP (not found on GitHub)"; \
		fi; \
	done; \
	rm -rf "$$TMPDIR"; \
	echo ""; \
	echo "  Mirror complete."

# ── CI / Tekton ──────────────────────────────────────────────────────────────

QUAY_ORG ?= masales

DNOTAM_SERVICES := swim-dnotam-consumer swim-dnotam-provider swim-dnotam-provider-validator swim-dnotam-consumer-validator
ED254_SERVICES  := swim-ed254-consumer swim-ed254-provider swim-ed254-provider-validator swim-ed254-consumer-validator
FFICE_SERVICES  := swim-ffice-consumer swim-ffice-provider swim-ffice-provider-validator swim-ffice-consumer-validator

SWIM_SERVICES ?= $(if $(filter all,$(SWIM_STACKS)),\
  $(DNOTAM_SERVICES) $(ED254_SERVICES) $(FFICE_SERVICES),\
  $(foreach s,$(SWIM_STACKS),$($(shell echo $(s) | tr a-z A-Z)_SERVICES)))

# Copy pre-built images from Quay.io into the OpenShift internal registry
# using skopeo. This allows all services to start immediately after GitOps
# deployment. CI pipelines will later overwrite these with locally-built versions.
ci-bootstrap-images: crc-use-local
	@echo ""
	@echo "  Copying pre-built images from quay.io/$(QUAY_ORG) into internal registry..."
	@echo ""
	@REGISTRY=$$(oc get route default-route -n openshift-image-registry \
		-o jsonpath='{.spec.host}' 2>/dev/null); \
	if [ -z "$$REGISTRY" ]; then \
		echo "  ERROR: OpenShift image registry route not found."; \
		echo "  Ensure the internal registry has an external route enabled."; \
		exit 1; \
	fi; \
	TOKEN=$$(oc whoami -t); \
	for svc in $(SWIM_SERVICES); do \
		printf "    $$svc ... "; \
		skopeo copy --dest-tls-verify=false \
			--dest-creds=kubeadmin:$$TOKEN \
			docker://quay.io/$(QUAY_ORG)/$$svc:latest \
			docker://$$REGISTRY/$(NS)/$$svc:latest 2>/dev/null && \
			echo "ok" || \
			echo "SKIP (image not found on quay.io/$(QUAY_ORG)/$$svc)"; \
	done
	@echo ""
	@echo "  Done. Pods will pull these images from the internal registry."
	@echo ""

# Create the Quay.io push secret used by all pipeline image-build tasks.
# Usage: QUAY_USER=masales QUAY_TOKEN=<robot-token> make ci-quay-secret
ci-quay-secret: crc-use-local
	@if [ -z "$(QUAY_USER)" ] || [ -z "$(QUAY_TOKEN)" ]; then \
		echo ""; \
		echo "  ERROR: QUAY_USER and QUAY_TOKEN must be set."; \
		echo "  Usage: QUAY_USER=masales QUAY_TOKEN=<robot-token> make ci-quay-secret"; \
		echo ""; \
		exit 1; \
	fi
	@oc create namespace swim-pipeline --dry-run=client -o yaml | oc apply -f -
	@oc create secret docker-registry quay-push-auth \
		--docker-server=quay.io \
		--docker-username=$(QUAY_USER) \
		--docker-password=$(QUAY_TOKEN) \
		-n swim-pipeline \
		--dry-run=client -o yaml | oc apply -f -
	@echo "  Secret quay-push-auth created in swim-pipeline."

# Install (or update) all Tekton tasks, pipelines and triggers — external registry overlay.
ci-install: crc-use-local
	oc apply -k ci/tekton/overlays/openshift/
	@echo ""
	@echo "  Tekton CI installed."
	@echo ""

# Install CRC overlay: internal registry + Gitea release task.
# Order: apply kustomize first (creates pipeline SA), then setup registry credentials.
ci-install-crc: crc-use-local
	@oc create namespace swim-pipeline --dry-run=client -o yaml | oc apply -f -
	@oc patch configmap feature-flags -n openshift-pipelines --type merge \
	  -p '{"data":{"coschedule":"disabled"}}' 2>/dev/null || true
	oc apply -k ci/tekton/overlays/crc-local/
	$(MAKE) ci-registry-setup
	@echo ""
	@echo "  Tekton CI installed."
	@echo ""

# Grant pipeline SA image-builder access and create internal-registry-auth secret.
# Requires the pipeline SA to exist (run ci-install-crc or ci-install first).
ci-registry-setup: crc-use-local
	@echo "  Granting system:image-builder to pipeline SA in swim-demo..."
	@oc policy add-role-to-user system:image-builder \
	  system:serviceaccount:swim-pipeline:pipeline \
	  -n swim-demo --rolebinding-name=swim-pipeline-image-builder 2>/dev/null || true
	@echo "  Creating internal-registry-auth secret..."
	@TOKEN=$$(oc create token pipeline -n swim-pipeline --duration=87600h 2>/dev/null || \
	          oc serviceaccounts get-token pipeline -n swim-pipeline 2>/dev/null || echo ""); \
	if [ -z "$${TOKEN}" ]; then \
	  echo "  WARNING: Could not get pipeline SA token — ensure pipeline SA exists first."; \
	else \
	  oc create secret docker-registry internal-registry-auth \
	    --docker-server=image-registry.openshift-image-registry.svc:5000 \
	    --docker-username=serviceaccount \
	    --docker-password="$${TOKEN}" \
	    -n swim-pipeline \
	    --dry-run=client -o yaml | oc apply -f -; \
	  echo "  Secret internal-registry-auth ready."; \
	fi

# Run a pipeline manually (for testing). Usage: make ci-run CI_SERVICE=dnotam-consumer-validator
CI_SERVICE ?= dnotam-consumer-validator
ci-run: crc-use-local
	@echo "  Starting PipelineRun for swim-$(CI_SERVICE)-ci..."
	@printf 'apiVersion: tekton.dev/v1\nkind: PipelineRun\nmetadata:\n  generateName: swim-$(CI_SERVICE)-manual-\n  namespace: swim-pipeline\nspec:\n  pipelineRef:\n    name: swim-$(CI_SERVICE)-ci\n  workspaces:\n    - name: shared-workspace\n      volumeClaimTemplate:\n        spec:\n          accessModes: [ReadWriteOnce]\n          resources:\n            requests:\n              storage: 10Gi\n    - name: maven-cache\n      persistentVolumeClaim:\n        claimName: maven-repo-pvc\n    - name: docker-credentials\n      secret:\n        secretName: internal-registry-auth\n    - name: git-token\n      secret:\n        secretName: gitea-token\n' | oc create -f -
	@echo "  PipelineRun created."

# List recent PipelineRuns.
ci-status: crc-use-local
	@oc get pipelineruns -n swim-pipeline \
		--sort-by=.metadata.creationTimestamp \
		-o custom-columns=NAME:.metadata.name,PIPELINE:.spec.pipelineRef.name,STATUS:.status.conditions[0].reason,START:.status.startTime \
		2>/dev/null || echo "  No PipelineRuns found in swim-pipeline."

# ── Git source configuration ────────────────────────────────────────────────
# Reconfigure ALL Argo CD applications, CI pipelines and tasks to use a
# different Git server. Useful when migrating from CRC-local (Gitea) to a
# production OpenShift cluster backed by GitHub, GitLab, or any Git host.
#
# Usage:
#   make configure-git GIT_REPO_BASE=https://github.com/my-org
#   make configure-git GIT_REPO_BASE=https://gitlab.com/my-group
#
# After running, commit and push the changes so Argo CD picks them up.
configure-git:
	@if [ "$(GIT_REPO_BASE)" = "$(GIT_REPO_BASE_CRC)" ]; then \
		echo ""; \
		echo "  ERROR: GIT_REPO_BASE is still the CRC default."; \
		echo "  Usage: make configure-git GIT_REPO_BASE=https://github.com/my-org"; \
		echo ""; \
		exit 1; \
	fi
	@echo ""
	@echo "  Reconfiguring Git source URLs..."
	@echo "    From: $(GIT_REPO_BASE_CRC)"
	@echo "    To:   $(GIT_REPO_BASE)"
	@echo ""
	@for f in $$(find argocd/ ci/tekton/base/ bootstrap/ scripts/ \
	    -name '*.yaml' -o -name '*.sh' 2>/dev/null); do \
		if grep -q '$(GIT_REPO_BASE_CRC)' "$$f" 2>/dev/null; then \
			sed -i 's|$(GIT_REPO_BASE_CRC)|$(GIT_REPO_BASE)|g' "$$f"; \
			echo "    updated: $$f"; \
		fi; \
	done
	@echo ""
	@echo "  Done. Review the changes, then commit and push:"
	@echo "    git add -A && git commit -m 'Configure Git source: $(GIT_REPO_BASE)'"
	@echo "    git push origin main"
	@echo ""
