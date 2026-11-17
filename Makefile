# keptn-flux-5gc-lab
#   make up         create the Kind cluster (PROFILE=light|full, CNI=kindnet|cilium)
#   make bootstrap  cluster (if missing) + Flux bootstrap + runtime Secrets
#   make ui         port-forward Grafana, Prometheus, Alertmanager and Jaeger
#   make down       delete the Kind cluster
#   make tools      install the pinned validation tools into .tools/bin
#   make validate   kustomize build + kubeconform (Kubernetes 1.37.0 + CRD schemas) + shellcheck
#   make lint       actionlint, SHA-pinned actions check, gitleaks

SHELL := bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

PROFILE ?= light
CNI ?= kindnet
export PROFILE CNI

TOOLS_DIR := $(CURDIR)/.tools
export PATH := $(TOOLS_DIR)/bin:$(PATH)

# Validation tool versions (scripts/install-tools.sh).
# renovate: datasource=github-releases depName=kubernetes-sigs/kustomize extractVersion=^kustomize/v(?<version>.+)$
KUSTOMIZE_VERSION ?= 5.8.3
# renovate: datasource=github-releases depName=yannh/kubeconform extractVersion=^v(?<version>.+)$
KUBECONFORM_VERSION ?= 0.8.0
# renovate: datasource=github-releases depName=mikefarah/yq extractVersion=^v(?<version>.+)$
YQ_VERSION ?= 4.54.3
# renovate: datasource=github-releases depName=rhysd/actionlint extractVersion=^v(?<version>.+)$
ACTIONLINT_VERSION ?= 1.7.12
# renovate: datasource=github-releases depName=gitleaks/gitleaks extractVersion=^v(?<version>.+)$
GITLEAKS_VERSION ?= 8.30.1
export KUSTOMIZE_VERSION KUBECONFORM_VERSION YQ_VERSION ACTIONLINT_VERSION GITLEAKS_VERSION

# Versions whose CRDs the schemas are built from (scripts/crd-schemas.sh). Keep in sync with
# the Flux CLI used for bootstrap, platform/keptn/helmrelease.yaml and infrastructure/sources/oci.yaml.
# renovate: datasource=github-releases depName=fluxcd/flux2 extractVersion=^v(?<version>.+)$
FLUX_VERSION ?= 2.10.0
# renovate: datasource=helm depName=keptn registryUrl=https://charts.lifecycle.keptn.sh
KEPTN_CHART_VERSION ?= 0.11.0
# renovate: datasource=docker depName=ghcr.io/prometheus-community/charts/kube-prometheus-stack
KPS_CHART_VERSION ?= 93.3.0
export FLUX_VERSION KEPTN_CHART_VERSION KPS_CHART_VERSION

KUBERNETES_VERSION ?= 1.37.0
SCHEMA_DIR := $(TOOLS_DIR)/schemas
# Built-in Kubernetes schemas, pinned to a commit of yannh/kubernetes-json-schema.
K8S_SCHEMAS_REF ?= 6ea44f54bb5cdedb2f61fba42c9b342e97959262
KUBECONFORM_FLAGS := -strict -summary -output text \
  -kubernetes-version $(KUBERNETES_VERSION) \
  -schema-location 'https://raw.githubusercontent.com/yannh/kubernetes-json-schema/$(K8S_SCHEMAS_REF)/{{.NormalizedKubernetesVersion}}-standalone{{.StrictSuffix}}/{{.ResourceKind}}{{.KindSuffix}}.json' \
  -schema-location '$(SCHEMA_DIR)/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

# Every kustomization in the repo, and plain manifests that no kustomization includes.
KUSTOMIZATIONS = $(sort $(dir $(shell find . -name kustomization.yaml -not -path './.tools/*' -not -path './.git/*')))
LOOSE_MANIFESTS = $(wildcard examples/*.yaml)
SCRIPTS = $(wildcard scripts/*.sh)

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

##@ Lab
.PHONY: up bootstrap ui down
up: ## Create the Kind cluster for PROFILE (light|full) and CNI (kindnet|cilium)
	scripts/bootstrap.sh cluster

bootstrap: ## Cluster (if missing), Flux bootstrap and runtime Secrets; needs GITHUB_USER, GITHUB_TOKEN, KEPTN_DISPATCH_TOKEN
	scripts/bootstrap.sh

ui: ## Port-forward Grafana :3000, Prometheus :9090, Alertmanager :9093, Jaeger :16686
	scripts/ui.sh

down: ## Delete the Kind cluster
	kind delete cluster --name keptn-5gc

##@ Scenarios (scripts from the apps slice)
.PHONY: bump fault heal
bump: ## Bump RELEASE_ID (new Keptn app version), commit and push
	scripts/bump-release.sh lab

fault: ## Switch Open5GS to the faulty config (SMF DNN mismatch), commit and push
	scripts/inject-fault.sh

heal: ## Switch Open5GS back to the good config, commit and push
	scripts/heal.sh

##@ Checks
.PHONY: tools schemas validate lint
tools: ## Install pinned kustomize, kubeconform, yq, actionlint, gitleaks into .tools/bin
	BIN_DIR=$(TOOLS_DIR)/bin scripts/install-tools.sh

$(SCHEMA_DIR)/.stamp: scripts/crd-schemas.sh Makefile
	SCHEMA_DIR=$(SCHEMA_DIR) scripts/crd-schemas.sh
	touch $@

schemas: $(SCHEMA_DIR)/.stamp ## Build CRD JSON schemas for Flux, Keptn and prometheus-operator

validate: schemas ## kustomize build + kubeconform on every kustomization, shellcheck on scripts
	@for d in $(KUSTOMIZATIONS); do \
	  echo "==> kustomize build $$d"; \
	  kustomize build "$$d" | kubeconform $(KUBECONFORM_FLAGS) -; \
	done
	@if [ -n "$(LOOSE_MANIFESTS)" ]; then \
	  echo "==> kubeconform $(LOOSE_MANIFESTS)"; \
	  kubeconform $(KUBECONFORM_FLAGS) $(LOOSE_MANIFESTS); \
	fi
	@echo "==> shellcheck $(SCRIPTS)"
	@shellcheck $(SCRIPTS)

lint: ## actionlint, check that every action is pinned to a full commit SHA, gitleaks
	actionlint
	@echo "==> actions pinned by commit SHA"
	@if grep -rnE '^\s*-?\s*uses:\s*' .github/workflows | grep -vE 'uses:\s*\./' | grep -vE '@[0-9a-f]{40}(\s|$$)'; then \
	  echo "error: the actions above are not pinned to a full commit SHA" >&2; exit 1; \
	fi
	gitleaks git --no-banner --redact .
