.PHONY: argocd-install argocd-bootstrap argocd-password argocd-oidc grafana-dashboards-check validate-gitops validate-kyverno-policies install-pre-commit mcp-install mcp-verify mcp-uninstall migrate-cluster-yaml verify-tools pull-base-oci render-consumer render-consumer-all verify-consumer-rendered harness-check .argocd-bootstrap-render

ENV ?= cluster.yaml

# MCP server versions — pinned to verified official sources (homebrew/core, containers/k8s, npm/talos-mcp).
MCP_GITHUB_VERSION  := 0.33.0
MCP_K8S_VERSION     := 0.0.60
MCP_TALOS_VERSION   := 1.1.0

MCP_WRAPPER_BIN    := $(HOME)/.local/bin/mcp-github-wrapper
MCP_WRAPPER_SOURCE := $(CURDIR)/scripts/mcp-github-wrapper.sh

UNAME_S := $(shell uname -s)

argocd-install:
	kubectl apply -f kubernetes/bootstrap/argocd/namespace.yaml
	helm upgrade --install argocd argo/argo-cd \
		--version '9.4.5' \
		--namespace argocd \
		-f kubernetes/base/infrastructure/argocd/values.yaml
	@kubectl create secret generic sops-age-key \
		--namespace argocd \
		--from-file=keys.txt=$${SOPS_AGE_KEY_FILE:-$$HOME/.config/sops/age/keys.txt} \
		--dry-run=client -o yaml | kubectl apply -f -
	kubectl wait --for=condition=available -n argocd deployment/argocd-server --timeout=300s

migrate-cluster-yaml: cluster.yaml.example
	@if [ -e .claude/environment.yaml ] && [ ! -e cluster.yaml ]; then \
	  git mv .claude/environment.yaml cluster.yaml 2>/dev/null || mv .claude/environment.yaml cluster.yaml; \
	  echo "Migrated .claude/environment.yaml -> cluster.yaml"; \
	fi; \
	if [ ! -e cluster.yaml ]; then \
	  cp cluster.yaml.example cluster.yaml && \
	  echo "Created cluster.yaml from cluster.yaml.example -- fill in your cluster values"; \
	fi; \
	if ! yq -e '.cluster.ntp_server' cluster.yaml >/dev/null 2>&1; then \
	  echo "ERROR: cluster.yaml missing .cluster.ntp_server -- add it (e.g. yq -i '.cluster.ntp_server = \"<ntp-ip>\"' cluster.yaml)"; \
	  exit 1; \
	fi

.argocd-bootstrap-render:
	@CLUSTER_NAME=$$(yq -e '.cluster.name' $(ENV)); \
	 REPO_URL=$$(yq -e '.repo.url' $(ENV)); \
	 OVERLAY=$$(yq -e '.cluster.overlay' $(ENV)); \
	 TARGET_REVISION=$$(yq -e '.cluster.target_revision // "main"' $(ENV)); \
	 for v in "$$CLUSTER_NAME" "$$REPO_URL" "$$OVERLAY" "$$TARGET_REVISION"; do \
	   case "$$v" in *\$$*) echo "ERROR: cluster.yaml value contains '$$' which is unsafe for envsubst: $$v"; exit 1;; esac; \
	 done; \
	 mkdir -p kubernetes/bootstrap/argocd/_out; \
	 export CLUSTER_NAME REPO_URL OVERLAY TARGET_REVISION; \
	 envsubst '$$CLUSTER_NAME $$REPO_URL $$OVERLAY $$TARGET_REVISION' \
	   < kubernetes/bootstrap/argocd/root-application.yaml.tmpl \
	   > kubernetes/bootstrap/argocd/_out/root-application.yaml; \
	 envsubst '$$CLUSTER_NAME $$REPO_URL' \
	   < kubernetes/bootstrap/argocd/root-project.yaml.tmpl \
	   > kubernetes/bootstrap/argocd/_out/root-project.yaml

argocd-bootstrap: argocd-install .argocd-bootstrap-render
	kubectl apply -f kubernetes/bootstrap/argocd/_out/root-project.yaml
	kubectl apply -f kubernetes/bootstrap/argocd/_out/root-application.yaml

argocd-password:
	@kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo

verify-tools: ## Confirm installed binaries match .tool-versions pins
	@./scripts/verify-tools.sh

argocd-oidc:
	@OIDC_SECRET=$$(sops -d --extract '["stringData"]["argocd-oidc-client-secret"]' \
		kubernetes/overlays/homelab/infrastructure/dex/resources/secret.sops.yaml) && \
	kubectl -n argocd patch secret argocd-secret --type merge \
		-p "{\"stringData\":{\"oidc.argocd.clientSecret\":\"$$OIDC_SECRET\"}}"

grafana-dashboards-check:
	@if rg -n '\$\{DS_[A-Z0-9_]+\}|\"__inputs\"' kubernetes/overlays/homelab/infrastructure/*/resources/dashboards/*.json; then \
		echo "error: dashboard contains import-only datasource placeholders or __inputs; use fixed datasource uid (prometheus)"; \
		exit 1; \
	else \
		echo "ok: dashboards contain no DS_* placeholders or __inputs"; \
	fi

validate-gitops:
	./scripts/discover_kustomize_targets.sh
	./scripts/render_kustomize_safe.sh
	./scripts/discover_argocd_apps.sh
	./scripts/verify_sops_files.sh
	./scripts/run_conftest.sh
	@for f in $$(cat .work/kustomize-rendered-files.txt 2>/dev/null); do \
		echo "kubeconform: $$f"; \
		kubeconform -strict -ignore-missing-schemas "$$f"; \
	done
	./scripts/run_trivy.sh

harness-check: ## Verify .claude/harness.yaml stays in sync with cluster.yaml
	@# kube-agent-harness plugins read .claude/harness.yaml. The only field this repo
	@# duplicates from cluster.yaml is the overlay path — kubeconfig falls back to
	@# the $$KUBECONFIG env var so it is not duplicated.
	@expected="kubernetes/overlays/$$(yq '.cluster.overlay' $(ENV))"; \
	actual="$$(yq '.cluster.overlayPath' .claude/harness.yaml)"; \
	if [ "$$expected" != "$$actual" ]; then \
		echo "ERROR: overlay path drift between $(ENV) and .claude/harness.yaml"; \
		echo "  $(ENV) → cluster.overlay: $$expected"; \
		echo "  .claude/harness.yaml → cluster.overlayPath: $$actual"; \
		exit 1; \
	fi
	@echo "harness.yaml ↔ $(ENV): in sync"

# Consumer Render Pipeline (Phase C of OCI base migration).
# Pulls the talos-platform-base OCI artifact into vendor/base/, then
# kustomize-builds each consumer overlay against it. The final
# _rendered/manifests.yaml is what ArgoCD's directory-source consumes.

pull-base-oci: ## Verify+pull the talos-platform-base OCI artifact into vendor/base/
	@./scripts/pull-base-oci.sh

render-consumer: ## Stage-3 render of one overlay. Usage: make render-consumer COMPONENT=<name>
	@if [ -z "$(COMPONENT)" ]; then echo "usage: make render-consumer COMPONENT=<name>"; exit 1; fi
	@./scripts/render-consumer-component.sh "$(COMPONENT)"

render-consumer-all: ## Render every consumer overlay that already has a _rendered/ dir
	@components="$$(find kubernetes/overlays/homelab/infrastructure -mindepth 2 -maxdepth 2 -name '_rendered' -type d | while IFS= read -r d; do basename "$$(dirname "$$d")"; done | sort -u)"; \
	if [ -z "$$components" ]; then echo "no consumer overlays with _rendered/ — run \`make render-consumer COMPONENT=<name>\` first to bootstrap one"; exit 0; fi; \
	for c in $$components; do ./scripts/render-consumer-component.sh "$$c"; done

verify-consumer-rendered: ## Re-render every consumer overlay and fail if committed _rendered/ drifts
	@./scripts/verify-consumer-rendered.sh

install-pre-commit:
	uvx pre-commit install
	uvx pre-commit run --all-files || true
	@echo "pre-commit hooks installed. Run 'uvx pre-commit run --all-files' to validate the full repo."

validate-kyverno-policies:
	@echo "Server-validating Kyverno ClusterPolicies..."
	@kubectl apply --dry-run=server \
		-f kubernetes/base/infrastructure/platform-network-interface/resources/kyverno-clusterpolicy-pni-contract-enforce.yaml \
		-f kubernetes/base/infrastructure/platform-network-interface/resources/kyverno-clusterpolicy-pni-reserved-labels-enforce.yaml \
		-f kubernetes/base/infrastructure/platform-network-interface/resources/kyverno-clusterpolicy-vault-ca-distribution.yaml \
		-f kubernetes/base/infrastructure/platform-network-interface/resources/kyverno-clusterpolicy-pni-capability-validation-enforce.yaml
	@echo "ok: Kyverno ClusterPolicies passed server-side validation"

mcp-install: ## Install MCP server binaries (per-OS) and register wrapper symlink in ~/.local/bin
	@command -v gh >/dev/null 2>&1 || { echo "ERROR: 'gh' (GitHub CLI) required — https://cli.github.com"; exit 1; }
ifeq ($(UNAME_S),Darwin)
	@command -v brew >/dev/null 2>&1 || { echo "ERROR: 'brew' required on macOS — https://brew.sh"; exit 1; }
	brew install github-mcp-server@$(MCP_GITHUB_VERSION) 2>/dev/null || brew install github-mcp-server
	brew install kubernetes-mcp-server@$(MCP_K8S_VERSION) 2>/dev/null || brew install kubernetes-mcp-server
	@command -v npm >/dev/null 2>&1 || { echo "ERROR: 'npm' required for talos-mcp — https://nodejs.org"; exit 1; }
	npm install -g talos-mcp@$(MCP_TALOS_VERSION)
else
	@command -v go >/dev/null 2>&1 || { echo "ERROR: 'go' required on Linux for github-mcp-server — https://go.dev/dl"; exit 1; }
	go install github.com/github/github-mcp-server/cmd/github-mcp-server@v$(MCP_GITHUB_VERSION)
	@command -v npm >/dev/null 2>&1 || { echo "ERROR: 'npm' required — https://nodejs.org"; exit 1; }
	npm install -g kubernetes-mcp-server@$(MCP_K8S_VERSION)
	npm install -g talos-mcp@$(MCP_TALOS_VERSION)
endif
	@mkdir -p "$(HOME)/.local/bin"
	@ln -sf "$(MCP_WRAPPER_SOURCE)" "$(MCP_WRAPPER_BIN)"
	@chmod +x "$(MCP_WRAPPER_SOURCE)"
	@echo ""
	@echo "Installed: $(MCP_WRAPPER_BIN) -> $(MCP_WRAPPER_SOURCE)"
	@echo ""
	@echo "Next steps:"
	@echo "  1. Ensure \$$HOME/.local/bin is in your PATH"
	@echo "     Check: echo \$$PATH | grep -q \$$HOME/.local/bin && echo ok || echo 'ADD to PATH'"
	@echo "  2. Run: gh auth login  (if not already authenticated)"
	@echo "  3. Run: make mcp-verify"
	@echo "  4. Restart Claude Code / Codex CLI"

mcp-verify: ## Verify MCP binaries, wrapper symlink, and gh auth state
	@set -e; fail=0; \
	for bin in gh github-mcp-server kubernetes-mcp-server talos-mcp mcp-github-wrapper; do \
	  if command -v "$$bin" >/dev/null 2>&1; then \
	    echo "OK:      $$bin -> $$(command -v $$bin)"; \
	  else \
	    echo "MISSING: $$bin — run 'make mcp-install'"; fail=1; \
	  fi; \
	done; \
	if ! gh auth token >/dev/null 2>&1; then \
	  echo "FAIL:    gh auth token — run 'gh auth login'"; fail=1; \
	else \
	  echo "OK:      gh auth token (keychain accessible)"; \
	fi; \
	if [ "$$fail" -eq 0 ]; then \
	  echo ""; echo "All checks passed. MCP servers ready."; \
	else \
	  echo ""; echo "One or more checks failed — fix above before starting Claude/Codex."; exit 1; \
	fi

mcp-uninstall: ## Remove MCP wrapper symlink from ~/.local/bin (leaves binaries in place)
	@rm -f "$(MCP_WRAPPER_BIN)" && echo "Removed $(MCP_WRAPPER_BIN)" || echo "$(MCP_WRAPPER_BIN) was not present"
