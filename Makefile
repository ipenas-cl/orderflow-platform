SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help
CLUSTER ?= orderflow
STEADY  ?= 7m
ORDERFLOW_DIR ?= ../orderflow
TF_DIRS := terraform/bootstrap terraform/envs/dev terraform/envs/staging terraform/envs/prod

help: ## list targets
	@grep -hE '^[a-z0-9-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

prove: up run collect ## full proof: cluster + add-ons + orderflow + k6 + chaos + canary, then report

images: ## build the orderflow images at the pinned ref (clones ipenas-cl/orderflow into $(ORDERFLOW_DIR) if missing)
	@test -d $(ORDERFLOW_DIR) || git clone -q https://github.com/ipenas-cl/orderflow $(ORDERFLOW_DIR)
	git -C $(ORDERFLOW_DIR) fetch -q origin && git -C $(ORDERFLOW_DIR) -c advice.detachedHead=false checkout -q $$(tr -d '[:space:]' < release/orderflow.ref)
	cd $(ORDERFLOW_DIR) && for s in orders payments inventory fulfillment payprovider devissuer; do docker build -q --build-arg SERVICE=$$s -t orderflow-$$s:latest . || exit 1; done && docker build -q -f Dockerfile.admin -t orderflow-admin:latest .
	docker pull -q postgres:16-alpine && docker pull -q nats:2.10-alpine

up: ## kind cluster, add-ons, Argo CD sync of orderflow
	proof/up.sh

run: ## game day (k6 + chaos) and the bad canary release
	STEADY=$(STEADY) proof/run.sh

collect: ## query Prometheus and write docs/results (report + charts)
	@kubectl -n monitoring port-forward svc/prometheus-server 9090:80 >/dev/null 2>&1 & pf=$$!; \
	  trap "kill $$pf" EXIT; sleep 3; PROM_URL=http://127.0.0.1:9090 python3 proof/collect.py

down: ## delete the kind cluster
	kind delete cluster --name $(CLUSTER)

cost: ## infracost breakdown of prod (needs INFRACOST_API_KEY)
	@test -n "$$INFRACOST_API_KEY" || { echo "set INFRACOST_API_KEY (free key: infracost auth login)"; exit 1; }
	infracost breakdown --path terraform/envs/prod --usage-file docs/infracost-usage.yml

lint: tf-lint k8s-lint ## all static checks

tf-lint: ## terraform fmt/validate, tflint, checkov
	terraform fmt -check -recursive terraform
	@for d in $(TF_DIRS); do (cd $$d && terraform init -backend=false -input=false >/dev/null && terraform validate) || exit 1; done
	@for d in terraform/modules/* $(TF_DIRS); do tflint --chdir=$$d --config=$(CURDIR)/terraform/.tflint.hcl || exit 1; done
	checkov -d terraform --framework terraform --config-file .checkov.yaml

k8s-lint: ## render every overlay and app-of-apps, check pod templates against Kyverno policies
	@for d in gitops/orderflow/overlays/* gitops/apps/* gitops/platform/kyverno-policies*; do kustomize build $$d >/dev/null && echo "ok  $$d" || exit 1; done
	@for o in kind dev staging prod; do scripts/policy-check.sh gitops/orderflow/overlays/$$o || exit 1; done

.PHONY: images help prove up run collect down cost lint tf-lint k8s-lint
