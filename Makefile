# ==============================================================================
# iVolve CloudDevOpsProject — task runner
# ==============================================================================
# Wraps the long, easily-mistyped commands each phase needs, so the workflow is
# discoverable (`make help`) rather than buried in documentation.
#
# NOTE: recipe lines must be indented with a TAB, not spaces. This is a hard
# Make requirement — spaces produce "missing separator" errors.
# ==============================================================================

.DEFAULT_GOAL := help
SHELL := /bin/bash

# Every target is "phony" — none of them produce a file with that name, so Make
# must not skip one because a same-named file exists.
.PHONY: help \
        up down logs ps rebuild \
        tf-init tf-plan tf-apply tf-destroy tf-fmt tf-validate tf-output \
        ansible-check ansible-run ansible-inventory vault-edit vault-view \
        k8s-build k8s-validate k8s-apply k8s-delete k8s-status \
        argo-install argo-apply argo-password \
        mon-install mon-grafana grafana-dashboard \
        lint validate-all clean

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------
TF_DIR        := 02-Terraform
ANSIBLE_DIR   := 03-Ansible
K8S_DIR       := 04-Kubernetes/manifests
ARGO_DIR      := 06-ArgoCD
MON_DIR       := 07-Monitoring
AWS_REGION    ?= us-east-1
CLUSTER_NAME  ?= ivolve-dev-eks

# ANSI colours for readable output.
BLUE  := \033[0;34m
GREEN := \033[0;32m
YELL  := \033[0;33m
RESET := \033[0m

# ==============================================================================
help: ## Show this help
	@echo ""
	@echo "$(BLUE)iVolve CloudDevOpsProject$(RESET)"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(GREEN)%-22s$(RESET) %s\n", $$1, $$2}'
	@echo ""

# ==============================================================================
# Phase 1 — Docker Compose (local development)
# ==============================================================================
up: ## Build and start the full local stack
	@if [ ! -f 01-Docker/.env ]; then \
	  echo "$(YELL)No 01-Docker/.env — copying from .env.example$(RESET)"; \
	  cp 01-Docker/.env.example 01-Docker/.env; \
	  echo "$(YELL)Edit 01-Docker/.env and replace the CHANGE_ME values, then re-run.$(RESET)"; \
	  exit 1; \
	fi
	cd 01-Docker && docker compose up --build -d
	@echo "$(GREEN)Stack is up → http://localhost:3000$(RESET)"

down: ## Stop the local stack (keeps the database volume)
	cd 01-Docker && docker compose down

destroy-local: ## Stop the local stack AND DELETE the database volume
	cd 01-Docker && docker compose down -v

logs: ## Tail logs from all local services
	cd 01-Docker && docker compose logs -f

ps: ## Show local service status and health
	cd 01-Docker && docker compose ps

rebuild: ## Force a clean rebuild of all local images
	cd 01-Docker && docker compose build --no-cache && docker compose up -d

# ==============================================================================
# Phase 2 — Terraform
# ==============================================================================
tf-bootstrap: ## Create the S3 remote-state bucket (run ONCE, first)
	cd $(TF_DIR)/bootstrap && terraform init && terraform apply

tf-init: ## Initialise Terraform with the S3 backend
	@if [ ! -f $(TF_DIR)/backend.hcl ]; then \
	  echo "$(YELL)Missing $(TF_DIR)/backend.hcl — copy backend.hcl.example and fill in the bucket from 'make tf-bootstrap'.$(RESET)"; \
	  exit 1; \
	fi
	cd $(TF_DIR) && terraform init -backend-config=backend.hcl

tf-fmt: ## Format all Terraform files
	cd $(TF_DIR) && terraform fmt -recursive

tf-validate: ## Validate the Terraform configuration (offline)
	cd $(TF_DIR) && terraform validate

tf-plan: ## Preview infrastructure changes (read-only)
	cd $(TF_DIR) && terraform plan

tf-apply: ## Provision the AWS infrastructure
	cd $(TF_DIR) && terraform apply

tf-output: ## Show all Terraform outputs
	cd $(TF_DIR) && terraform output

tf-destroy: ## DESTROY all AWS infrastructure
	@echo "$(YELL)This destroys the EKS cluster, the Jenkins server, the VPC and all ECR images.$(RESET)"
	cd $(TF_DIR) && terraform destroy

# ==============================================================================
# Phase 3 — Ansible
# ==============================================================================
ansible-deps: ## Install the required Ansible collections and Python libraries
	cd $(ANSIBLE_DIR) && ansible-galaxy collection install -r requirements.yml
	pip install boto3 botocore

ansible-inventory: ## Show the hosts discovered by the AWS dynamic inventory
	cd $(ANSIBLE_DIR) && ansible-inventory --graph

ansible-ping: ## Verify SSH connectivity to the Jenkins server
	cd $(ANSIBLE_DIR) && ansible role_jenkins -m ping

ansible-check: ## Dry-run the playbook, showing what would change
	cd $(ANSIBLE_DIR) && ansible-playbook playbook.yml --check --diff

ansible-run: ## Configure the Jenkins server
	cd $(ANSIBLE_DIR) && ansible-playbook playbook.yml

vault-create: ## Create the encrypted Ansible Vault from the template
	cd $(ANSIBLE_DIR) && cp group_vars/all/vault.yml.example group_vars/all/vault.yml \
	  && ansible-vault encrypt group_vars/all/vault.yml

vault-edit: ## Edit the encrypted vault in place
	cd $(ANSIBLE_DIR) && ansible-vault edit group_vars/all/vault.yml

vault-view: ## View the vault contents without decrypting to disk
	cd $(ANSIBLE_DIR) && ansible-vault view group_vars/all/vault.yml

# ==============================================================================
# Phase 4 — Kubernetes
# ==============================================================================
kubeconfig: ## Point kubectl at the EKS cluster
	aws eks update-kubeconfig --region $(AWS_REGION) --name $(CLUSTER_NAME)

k8s-build: ## Render the manifests with Kustomize (no cluster needed)
	kubectl kustomize $(K8S_DIR)

k8s-validate: ## Validate the manifests against the Kubernetes schemas
	@command -v kubeconform >/dev/null 2>&1 || { \
	  echo "$(YELL)kubeconform not found — https://github.com/yannh/kubeconform$(RESET)"; exit 1; }
	kubectl kustomize $(K8S_DIR) | kubeconform -strict -summary -kubernetes-version 1.31.0

k8s-diff: ## Show what applying the manifests would change
	kubectl diff -k $(K8S_DIR) || true

k8s-apply: ## Apply the manifests directly (bypasses ArgoCD — use for testing only)
	kubectl apply -k $(K8S_DIR)

k8s-status: ## Show the state of everything in the ivolve namespace
	@kubectl get all,ingress,pvc,hpa,pdb -n ivolve

k8s-delete: ## Delete all application resources
	kubectl delete -k $(K8S_DIR)

# ==============================================================================
# Phase 6 — ArgoCD
# ==============================================================================
argo-install: ## Install ArgoCD into the cluster
	kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
	kubectl wait --for=condition=available --timeout=600s \
	  deployment/argocd-server -n argocd

argo-apply: ## Register the AppProject and Application with ArgoCD
	kubectl apply -f $(ARGO_DIR)/project.yaml
	kubectl apply -f $(ARGO_DIR)/applications/

argo-password: ## Print the initial ArgoCD admin password
	@kubectl -n argocd get secret argocd-initial-admin-secret \
	  -o jsonpath="{.data.password}" | base64 -d && echo

argo-ui: ## Open the ArgoCD UI on https://localhost:8080
	@echo "$(GREEN)ArgoCD UI → https://localhost:8080 (user: admin)$(RESET)"
	kubectl port-forward svc/argocd-server -n argocd 8080:443

# ==============================================================================
# Phase 7 — Monitoring
# ==============================================================================
mon-install: ## Install the kube-prometheus-stack
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
	helm repo update
	kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
	helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
	  --namespace monitoring \
	  --values $(MON_DIR)/kube-prometheus-stack-values.yaml \
	  --wait --timeout 15m
	kubectl apply -f $(MON_DIR)/manifests/

mon-grafana: ## Open Grafana on http://localhost:3000
	@echo "$(GREEN)Grafana → http://localhost:3000 (user: admin)$(RESET)"
	kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80

mon-prometheus: ## Open Prometheus on http://localhost:9090
	kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090

grafana-dashboard: ## Regenerate the dashboard ConfigMap from the JSON source
	@cd $(MON_DIR) && python -c "import json,textwrap; \
d=open('dashboards/ivolve-overview.json',encoding='utf-8').read(); json.loads(d); \
h=open('manifests/02-grafana-dashboard.yaml',encoding='utf-8').read().split('  ivolve-overview.json: |')[0]; \
open('manifests/02-grafana-dashboard.yaml','w',encoding='utf-8').write(h + '  ivolve-overview.json: |\n' + textwrap.indent(d.rstrip(), '    ') + '\n')"
	@echo "$(GREEN)Regenerated $(MON_DIR)/manifests/02-grafana-dashboard.yaml$(RESET)"

# ==============================================================================
# Quality
# ==============================================================================
lint: ## Run every available linter
	@echo "$(BLUE)── Terraform ──$(RESET)"
	@cd $(TF_DIR) && terraform fmt -recursive -check && echo "  fmt OK"
	@cd $(TF_DIR) && terraform validate
	@echo "$(BLUE)── Docker Compose ──$(RESET)"
	@cd 01-Docker && docker compose config --quiet && echo "  compose OK"
	@echo "$(BLUE)── Ansible ──$(RESET)"
	@command -v ansible-lint >/dev/null 2>&1 \
	  && (cd $(ANSIBLE_DIR) && ansible-lint) \
	  || echo "  $(YELL)ansible-lint not installed — skipping$(RESET)"
	@echo "$(BLUE)── Kubernetes ──$(RESET)"
	@$(MAKE) --no-print-directory k8s-validate

validate-all: lint ## Alias for `lint`

clean: ## Remove generated and cached files
	find . -name '*.retry' -delete
	find . -name '__pycache__' -type d -prune -exec rm -rf {} +
	find . -name 'trivy-*.json' -delete
	find . -name 'trivy-*.txt' -delete
	rm -rf $(ANSIBLE_DIR)/.ansible_facts $(ANSIBLE_DIR)/.ansible_inventory_cache
	rm -f $(ANSIBLE_DIR)/ansible.log
	@echo "$(GREEN)Cleaned.$(RESET)"
