ENV ?= ../cluster.yaml

# Goals that work without cluster.yaml (CI uses these for static validation).
NO_ENV_GOALS := cilium-bootstrap cilium-bootstrap-check schematics validate-schematics validate-secrets-cleanup clean
NEEDS_ENV    := $(strip $(filter-out $(NO_ENV_GOALS),$(if $(MAKECMDGOALS),$(MAKECMDGOALS),all)))

ifneq ($(NEEDS_ENV),)
ifeq ($(wildcard $(ENV)),)
$(error Cluster config not found: $(ENV). Run 'make migrate-cluster-yaml' from repo root, or copy ../cluster.yaml.example to ../cluster.yaml.)
endif

CLUSTER_NAME := $(strip $(shell yq -e '.cluster.name' $(ENV) 2>/dev/null))
ifeq ($(strip $(CLUSTER_NAME)),)
$(error cluster.yaml is missing required key '.cluster.name')
endif

API_VIP    := $(strip $(shell yq -e '.cluster.api_vip' $(ENV) 2>/dev/null))
ENDPOINT   := https://$(API_VIP):6443
NTP_SERVER := $(strip $(shell yq -e '.cluster.ntp_server' $(ENV) 2>/dev/null))
ifeq ($(strip $(NTP_SERVER)),)
$(error cluster.yaml is missing required key '.cluster.ntp_server')
endif

CP_NODES     := $(shell yq -e '.nodes.control_plane[].name' $(ENV) 2>/dev/null | tr '\n' ' ')
WORKER_NODES := $(shell yq -e '.nodes.workers[].name' $(ENV) 2>/dev/null | tr '\n' ' ')
GPU_NODES    := $(shell yq '.nodes.gpu_workers // [] | .[].name' $(ENV) 2>/dev/null | tr '\n' ' ')
PI_NODES     := $(shell yq '.nodes.pi_nodes // [] | .[].name' $(ENV) 2>/dev/null | tr '\n' ' ')
ALL_NODES    := $(CP_NODES) $(WORKER_NODES) $(GPU_NODES) $(PI_NODES)

# Per-node IP map: $(IP_<node-name>) := <ip>
$(foreach n,$(shell yq -r '(.nodes.control_plane + .nodes.workers + (.nodes.gpu_workers // []) + (.nodes.pi_nodes // []))[] | "\(.name)=\(.ip)"' $(ENV) 2>/dev/null),\
  $(eval IP_$(word 1,$(subst =, ,$(n))) := $(word 2,$(subst =, ,$(n)))))

OUTPUT_ROOT := _out/$(CLUSTER_NAME)
$(shell mkdir -p $(OUTPUT_ROOT)/controlplane $(OUTPUT_ROOT)/worker)
# Eagerly render the per-cluster NTP patch so it is present before Make
# evaluates pattern-rule prerequisites.  Re-rendering on every parse is
# cheap (pure envsubst, no secrets) and avoids a GNU Make 3.81 pattern-rule
# bootstrap issue where the cluster.yaml target is built during the first
# pass but cannot yet satisfy the pattern-rule prerequisite in the same run.
$(shell NTP_SERVER='$(NTP_SERVER)' envsubst '$$NTP_SERVER' < patches/cluster.yaml.tmpl > $(OUTPUT_ROOT)/cluster.yaml)
endif
include versions.mk

-include .schematic-ids.mk

# SOPS-decrypted secrets (intermediate file)
SECRETS_DEC := .secrets.dec.yaml

# Track version variable changes — forces config regeneration when versions change
VERSION_VARS := $(TALOS_VERSION) $(KUBERNETES_VERSION) $(CILIUM_VERSION)
VERSION_STAMP := .versions.stamp
$(shell echo '$(VERSION_VARS)' | cmp -s - $(VERSION_STAMP) || echo '$(VERSION_VARS)' > $(VERSION_STAMP))

# Install images (constructed from schematic IDs + version)
INSTALL_IMAGE := factory.talos.dev/metal-installer/$(SCHEMATIC_ID):$(TALOS_VERSION)
GPU_INSTALL_IMAGE := factory.talos.dev/metal-installer/$(GPU_SCHEMATIC_ID):$(TALOS_VERSION)
PI_INSTALL_IMAGE := factory.talos.dev/metal-installer/$(PI_SCHEMATIC_ID):$(TALOS_VERSION)

# Per-node image mapping
$(foreach node,$(CP_NODES) $(WORKER_NODES),$(eval IMAGE_$(node) = $$(INSTALL_IMAGE)))
$(foreach node,$(GPU_NODES),$(eval IMAGE_$(node) = $$(GPU_INSTALL_IMAGE)))
$(foreach node,$(PI_NODES),$(eval IMAGE_$(node) = $$(PI_INSTALL_IMAGE)))

# Ephemeral SOPS decryption
# Decrypts SOPS file to temporary file with automatic cleanup on exit
# Usage: $(call decrypt_ephemeral,input_file)
# Creates tmp_secrets variable with path to decrypted file
define decrypt_ephemeral
tmp_secrets=$$(mktemp) && \
trap 'rm -f "$$tmp_secrets"' EXIT HUP INT TERM && \
sops -d $(1) > "$$tmp_secrets"
endef

.PHONY: all gen-secrets gen-configs _gen-configs-phase1 _gen-configs-phase2 \
	schematics talosconfig clean \
	$(addprefix install-,$(ALL_NODES)) bootstrap \
	$(addprefix apply-,$(ALL_NODES)) apply-all \
	$(addprefix dry-run-,$(ALL_NODES)) dry-run-all \
	$(addprefix upgrade-,$(ALL_NODES)) upgrade-k8s validate-generated \
	cilium-bootstrap cilium-bootstrap-check validate-schematics validate-secrets-cleanup

../kubernetes/bootstrap/cilium/cilium.yaml: ../scripts/render-cilium-bootstrap.sh versions.mk ../kubernetes/bootstrap/cilium/values.yaml ../kubernetes/bootstrap/cilium/extras.yaml
	CILIUM_CHART_VERSION=$(CILIUM_VERSION) ../scripts/render-cilium-bootstrap.sh

cilium-bootstrap: ../kubernetes/bootstrap/cilium/cilium.yaml

cilium-bootstrap-check: cilium-bootstrap
	@if yq -r 'select(.kind == "Secret" and (.metadata.name == "hubble-relay-client-certs" or .metadata.name == "hubble-server-certs")) | .metadata.name' \
		../kubernetes/bootstrap/cilium/cilium.yaml | grep -n '.'; then \
		echo "error: static hubble tls secrets detected in kubernetes/bootstrap/cilium/cilium.yaml"; \
		exit 1; \
	else \
		echo "ok: no static hubble tls secrets in bootstrap cilium manifest"; \
	fi

all: gen-configs

gen-secrets:
	talosctl gen secrets -o secrets.yaml

# Per-cluster NTP patch rendered from template
$(OUTPUT_ROOT)/cluster.yaml: patches/cluster.yaml.tmpl $(ENV) | $(OUTPUT_ROOT)
	NTP_SERVER='$(NTP_SERVER)' envsubst '$$NTP_SERVER' < $< > $@

$(OUTPUT_ROOT):
	mkdir -p $(OUTPUT_ROOT)/controlplane $(OUTPUT_ROOT)/worker

# gen-configs uses a two-phase recursive-make to work around a GNU Make 3.81
# limitation where pattern-rule matching fails for targets inside directories
# that do not yet exist at Makefile parse time.  Phase 1 creates the output
# directory tree and renders the per-cluster NTP patch; phase 2 builds all
# node configs (by then the directories and cluster.yaml are guaranteed to
# exist before Make starts pattern-rule analysis).
gen-configs:
	$(MAKE) _gen-configs-phase1
	$(MAKE) _gen-configs-phase2

_gen-configs-phase1: $(OUTPUT_ROOT)/cluster.yaml

_gen-configs-phase2: \
	$(addprefix $(OUTPUT_ROOT)/controlplane/,$(addsuffix .yaml,$(CP_NODES))) \
	$(addprefix $(OUTPUT_ROOT)/worker/,$(addsuffix .yaml,$(WORKER_NODES))) \
	$(addprefix $(OUTPUT_ROOT)/worker/,$(addsuffix .yaml,$(GPU_NODES))) \
	$(addprefix $(OUTPUT_ROOT)/worker/,$(addsuffix .yaml,$(PI_NODES)))

$(OUTPUT_ROOT)/controlplane/%.yaml: patches/common.yaml $(OUTPUT_ROOT)/cluster.yaml patches/drbd.yaml patches/controlplane.yaml nodes/%.yaml secrets.yaml .schematic-ids.mk $(VERSION_STAMP) | $(OUTPUT_ROOT)
	@tmp_secrets=$$(mktemp) && \
	trap 'rm -f "$$tmp_secrets"' EXIT HUP INT TERM && \
	sops -d secrets.yaml > "$$tmp_secrets" && \
	talosctl gen config $(CLUSTER_NAME) $(ENDPOINT) \
		--with-secrets "$$tmp_secrets" \
		--config-patch @patches/common.yaml \
		--config-patch @$(OUTPUT_ROOT)/cluster.yaml \
		--config-patch @patches/drbd.yaml \
		--config-patch @patches/controlplane.yaml \
		--config-patch @nodes/$*.yaml \
		--config-patch '{"machine":{"install":{"image":"$(INSTALL_IMAGE)"}}}' \
		--output $@ \
		--output-types controlplane \
		--talos-version $(TALOS_VERSION) \
		--kubernetes-version $(KUBERNETES_VERSION) \
		--force && \
	yq eval-all 'del(select(.kind == "HostnameConfig").auto)' -i $@

$(OUTPUT_ROOT)/worker/node-gpu-%.yaml: patches/common.yaml $(OUTPUT_ROOT)/cluster.yaml patches/worker-gvisor.yaml patches/worker-gpu.yaml nodes/node-gpu-%.yaml secrets.yaml .schematic-ids.mk $(VERSION_STAMP) | $(OUTPUT_ROOT)
	@tmp_secrets=$$(mktemp) && \
	trap 'rm -f "$$tmp_secrets"' EXIT HUP INT TERM && \
	sops -d secrets.yaml > "$$tmp_secrets" && \
	talosctl gen config $(CLUSTER_NAME) $(ENDPOINT) \
		--with-secrets "$$tmp_secrets" \
		--config-patch @patches/common.yaml \
		--config-patch @$(OUTPUT_ROOT)/cluster.yaml \
		--config-patch @patches/worker-gvisor.yaml \
		--config-patch @patches/worker-gpu.yaml \
		--config-patch @nodes/node-gpu-$*.yaml \
		--config-patch '{"machine":{"install":{"image":"$(GPU_INSTALL_IMAGE)"}}}' \
		--output $@ \
		--output-types worker \
		--talos-version $(TALOS_VERSION) \
		--kubernetes-version $(KUBERNETES_VERSION) \
		--force && \
	yq eval-all 'del(select(.kind == "HostnameConfig").auto)' -i $@

$(OUTPUT_ROOT)/worker/node-pi-%.yaml: patches/common.yaml $(OUTPUT_ROOT)/cluster.yaml patches/worker-pi.yaml patches/pi-firewall.yaml nodes/node-pi-%.yaml secrets.yaml .schematic-ids.mk $(VERSION_STAMP) | $(OUTPUT_ROOT)
	@tmp_secrets=$$(mktemp) && \
	trap 'rm -f "$$tmp_secrets"' EXIT HUP INT TERM && \
	sops -d secrets.yaml > "$$tmp_secrets" && \
	talosctl gen config $(CLUSTER_NAME) $(ENDPOINT) \
		--with-secrets "$$tmp_secrets" \
		--config-patch @patches/common.yaml \
		--config-patch @$(OUTPUT_ROOT)/cluster.yaml \
		--config-patch @patches/worker-pi.yaml \
		--config-patch @patches/pi-firewall.yaml \
		--config-patch @nodes/node-pi-$*.yaml \
		--config-patch '{"machine":{"install":{"image":"$(PI_INSTALL_IMAGE)"}}}' \
		--output $@ \
		--output-types worker \
		--talos-version $(TALOS_VERSION) \
		--kubernetes-version $(KUBERNETES_VERSION) \
		--force && \
	yq eval-all 'del(select(.kind == "HostnameConfig").auto)' -i $@

$(OUTPUT_ROOT)/worker/%.yaml: patches/common.yaml $(OUTPUT_ROOT)/cluster.yaml patches/worker-gvisor.yaml patches/drbd.yaml patches/worker-kubevirt.yaml nodes/%.yaml secrets.yaml .schematic-ids.mk $(VERSION_STAMP) | $(OUTPUT_ROOT)
	@tmp_secrets=$$(mktemp) && \
	trap 'rm -f "$$tmp_secrets"' EXIT HUP INT TERM && \
	sops -d secrets.yaml > "$$tmp_secrets" && \
	talosctl gen config $(CLUSTER_NAME) $(ENDPOINT) \
		--with-secrets "$$tmp_secrets" \
		--config-patch @patches/common.yaml \
		--config-patch @$(OUTPUT_ROOT)/cluster.yaml \
		--config-patch @patches/worker-gvisor.yaml \
		--config-patch @patches/drbd.yaml \
		--config-patch @patches/worker-kubevirt.yaml \
		--config-patch @nodes/$*.yaml \
		--config-patch '{"machine":{"install":{"image":"$(INSTALL_IMAGE)"}}}' \
		--output $@ \
		--output-types worker \
		--talos-version $(TALOS_VERSION) \
		--kubernetes-version $(KUBERNETES_VERSION) \
		--force && \
	yq eval-all 'del(select(.kind == "HostnameConfig").auto)' -i $@

talosconfig: secrets.yaml
	talosctl gen config $(CLUSTER_NAME) $(ENDPOINT) \
		--with-secrets secrets.yaml \
		--output talosconfig \
		--output-types talosconfig \
		--talos-version $(TALOS_VERSION)

# Create schematics via Image Factory API and write IDs to .schematic-ids.mk
.schematic-ids.mk: talos-factory-schematic.yaml talos-factory-schematic-gpu.yaml talos-factory-schematic-pi.yaml
	@echo "Creating standard schematic..."
	@STD_ID=$$(curl -sS -X POST -H 'Content-Type: application/yaml' \
		--data-binary @talos-factory-schematic.yaml \
		https://factory.talos.dev/schematics | jq -r '.id') && \
	echo "Standard schematic ID: $$STD_ID" && \
	echo "Creating GPU schematic..." && \
	GPU_ID=$$(curl -sS -X POST -H 'Content-Type: application/yaml' \
		--data-binary @talos-factory-schematic-gpu.yaml \
		https://factory.talos.dev/schematics | jq -r '.id') && \
	echo "GPU schematic ID: $$GPU_ID" && \
	echo "Creating Pi schematic..." && \
	PI_ID=$$(curl -sS -X POST -H 'Content-Type: application/yaml' \
		--data-binary @talos-factory-schematic-pi.yaml \
		https://factory.talos.dev/schematics | jq -r '.id') && \
	echo "Pi schematic ID: $$PI_ID" && \
	printf '# Auto-generated by: make schematics\nSCHEMATIC_ID := %s\nGPU_SCHEMATIC_ID := %s\nPI_SCHEMATIC_ID := %s\n' \
		"$$STD_ID" "$$GPU_ID" "$$PI_ID" > $@ && \
	echo "Done. Written IDs to $@"

schematics: .schematic-ids.mk

# Validate that .schematic-ids.mk matches current schematic YAML content.
# Does NOT depend on .schematic-ids.mk as a Make prerequisite — that would
# trigger regeneration first, defeating the staleness check.
validate-schematics:
	@set -eu; \
	if [ ! -f .schematic-ids.mk ]; then \
		echo "error: .schematic-ids.mk not found — run 'make schematics' first"; exit 1; \
	fi; \
	echo "Validating schematic IDs against Factory API..."; \
	MISMATCH=0; \
	STD_ID=$$(curl -sSf -X POST -H 'Content-Type: application/yaml' \
		--data-binary @talos-factory-schematic.yaml \
		https://factory.talos.dev/schematics | jq -r '.id') && \
	GPU_ID=$$(curl -sSf -X POST -H 'Content-Type: application/yaml' \
		--data-binary @talos-factory-schematic-gpu.yaml \
		https://factory.talos.dev/schematics | jq -r '.id') && \
	PI_ID=$$(curl -sSf -X POST -H 'Content-Type: application/yaml' \
		--data-binary @talos-factory-schematic-pi.yaml \
		https://factory.talos.dev/schematics | jq -r '.id') && \
	for ID in "$$STD_ID" "$$GPU_ID" "$$PI_ID"; do \
		if ! echo "$$ID" | grep -qE '^[0-9a-f]{64}$$'; then \
			echo "error: Factory API returned unexpected value: $$ID"; exit 1; \
		fi; \
	done && \
	CURRENT_STD=$$(grep '^SCHEMATIC_ID :=' .schematic-ids.mk | awk '{print $$3}') && \
	CURRENT_GPU=$$(grep '^GPU_SCHEMATIC_ID :=' .schematic-ids.mk | awk '{print $$3}') && \
	CURRENT_PI=$$(grep '^PI_SCHEMATIC_ID :=' .schematic-ids.mk | awk '{print $$3}') && \
	if [ "$$STD_ID" != "$$CURRENT_STD" ]; then echo "MISMATCH: standard $$CURRENT_STD -> $$STD_ID"; MISMATCH=1; fi; \
	if [ "$$GPU_ID" != "$$CURRENT_GPU" ]; then echo "MISMATCH: GPU $$CURRENT_GPU -> $$GPU_ID"; MISMATCH=1; fi; \
	if [ "$$PI_ID" != "$$CURRENT_PI" ]; then echo "MISMATCH: Pi $$CURRENT_PI -> $$PI_ID"; MISMATCH=1; fi; \
	if [ "$$MISMATCH" -eq 1 ]; then \
		echo "error: stale schematic IDs — run 'make schematics' to update"; exit 1; \
	else \
		echo "ok: all schematic IDs match current YAML"; \
	fi

validate-secrets-cleanup:
	@if [ -f $(SECRETS_DEC) ]; then \
		echo "error: decrypted secrets file $(SECRETS_DEC) found — must be cleaned up"; \
		exit 1; \
	else \
		echo "ok: no decrypted secrets files found"; \
	fi

# Helper to resolve config path for a node
config-path = $(OUTPUT_ROOT)/$(if $(filter $(1),$(CP_NODES)),controlplane,worker)/$(1).yaml

# Install targets — initial config apply to fresh nodes (--insecure, no TLS yet)
define INSTALL_TEMPLATE
install-$(1): $$(call config-path,$(1))
	talosctl apply-config --insecure --nodes $$(IP_$(1)) --file $$(call config-path,$(1))
endef

$(foreach node,$(ALL_NODES),$(eval $(call INSTALL_TEMPLATE,$(node))))

# Bootstrap etcd on first control plane node
bootstrap:
	talosctl bootstrap --nodes $(IP_node-01) --endpoints $(IP_node-01)

# Apply targets
define APPLY_TEMPLATE
apply-$(1): dry-run-$(1)
	talosctl apply-config --nodes $$(IP_$(1)) --endpoints $$(IP_$(1)) --file $$(call config-path,$(1))
endef

$(foreach node,$(ALL_NODES),$(eval $(call APPLY_TEMPLATE,$(node))))

apply-all: $(addprefix apply-,$(ALL_NODES))

# Dry-run targets
define DRY_RUN_TEMPLATE
dry-run-$(1): gen-configs
	talosctl apply-config --nodes $$(IP_$(1)) --endpoints $$(IP_$(1)) --file $$(call config-path,$(1)) --dry-run
endef

$(foreach node,$(ALL_NODES),$(eval $(call DRY_RUN_TEMPLATE,$(node))))

dry-run-all: $(addprefix dry-run-,$(ALL_NODES))

validate-generated: gen-configs
	@set -eu; \
	files=$$(find $(OUTPUT_ROOT) -type f -name '*.yaml' | sort); \
	if [ -z "$$files" ]; then \
		echo "No generated machine configs found under talos/$(OUTPUT_ROOT)"; \
		exit 1; \
	fi; \
	for f in $$files; do \
		echo "Validating $$f"; \
		talosctl validate --config "$$f" --mode metal --strict; \
	done

# Upgrade targets — apply config then upgrade to new install image
define UPGRADE_TEMPLATE
upgrade-$(1): validate-schematics $$(call config-path,$(1))
	talosctl apply-config --nodes $$(IP_$(1)) --endpoints $$(IP_$(1)) --file $$(call config-path,$(1))
	talosctl upgrade --nodes $$(IP_$(1)) \
		--endpoints $$(IP_$(1)) \
		--image $$(IMAGE_$(1)) \
		--preserve \
		--wait --timeout 10m
endef

$(foreach node,$(ALL_NODES),$(eval $(call UPGRADE_TEMPLATE,$(node))))

# Upgrade Kubernetes and re-apply extraManifests (e.g. Cilium)
upgrade-k8s: cilium-bootstrap-check
	talosctl upgrade-k8s --to $(KUBERNETES_VERSION) -n $(IP_node-01) -e $(IP_node-01)

clean:
	rm -rf _out/
	rm -f $(SECRETS_DEC) $(VERSION_STAMP)
