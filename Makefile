SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help
CLUSTER ?= orderflow
STEADY  ?= 7m
TF_DIRS := terraform/bootstrap terraform/envs/dev terraform/envs/staging terraform/envs/prod

help: ## list targets
	@grep -hE '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

prove: up run collect ## full proof: cluster + add-ons + orderflow + k6 + chaos + canary, then report

up: ## kind cluster, add-ons, Argo CD sync of orderflow
	proof/up.sh

run: ## game day (k6 + chaos) and the bad canary release
	STEADY=$(STEADY) proof/run.sh

collect: ## query Prometheus and write docs/results (report + charts)
	@kubectl -n monitoring port-forward svc/prometheus-server 9090:80 >/dev/null 2>&1 & pf=$$!; \
	  trap "kill $$pf" EXIT; sleep 3; PROM_URL=http://127.0.0.1:9090 python3 proof/collect.py

down: ## delete the kind cluster
	kind delete cluster --name $(CLUSTER)

lint: tf-lint k8s-lint ## all static checks

tf-lint: ## terraform fmt/validate, tflint, checkov
	terraform fmt -check -recursive terraform
	@for d in $(TF_DIRS); do (cd $$d && terraform init -backend=false -input=false >/dev/null && terraform validate) || exit 1; done
	@for d in terraform/modules/* $(TF_DIRS); do tflint --chdir=$$d --config=$(CURDIR)/terraform/.tflint.hcl || exit 1; done
	checkov -d terraform --framework terraform --config-file .checkov.yaml

k8s-lint: ## render every overlay and app-of-apps
	@for d in gitops/orderflow/overlays/* gitops/apps/* gitops/platform/kyverno-policies*; do kustomize build $$d >/dev/null && echo "ok  $$d" || exit 1; done

.PHONY: help prove up run collect down lint tf-lint k8s-lint
