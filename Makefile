ANSIBLE_PLAYBOOK := ansible-playbook
VARS_FILE        := group_vars/all/vars.yml
CORE_PASSWORD    ?= core

.PHONY: help plan provision bastion deploy-bastion deploy deploy-all \
        teardown teardown-ocp teardown-networks destroy core-password

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

plan: ## Show what will be provisioned (networks, VMs, DNS)
	@$(ANSIBLE_PLAYBOOK) plan.yml

provision: ## Provision infrastructure VMs (bastion)
	$(ANSIBLE_PLAYBOOK) provision.yml

bastion: ## Configure the bastion node (mirror registry, OCP tools, content mirror)
	$(ANSIBLE_PLAYBOOK) configure-bastion.yml

deploy-bastion: ## Run deploy-ocp.yml for bastion only (install-config, ignition, containers)
	$(ANSIBLE_PLAYBOOK) deploy-ocp.yml --limit bastion

deploy: ## Run deploy-ocp.yml (bastion prep + provision OCP nodes)
	$(ANSIBLE_PLAYBOOK) deploy-ocp.yml

deploy-all: provision bastion deploy ## Run full deployment: provision → configure bastion → deploy OCP

teardown-ocp: ## Destroy OCP nodes only (keeps bastion), cleans install dir
	$(ANSIBLE_PLAYBOOK) teardown-ocp.yml

teardown: ## Destroy all VMs (infra + OCP)
	$(ANSIBLE_PLAYBOOK) teardown.yml

teardown-networks: ## Destroy libvirt networks
	$(ANSIBLE_PLAYBOOK) teardown-networks.yml

destroy: teardown teardown-networks ## Destroy everything: VMs + networks

core-password: ## Generate a core user password hash and write it to vars
	@hash=$$(python3 -c "import crypt; print(crypt.crypt('$(CORE_PASSWORD)', crypt.mksalt(crypt.METHOD_SHA512)))"); \
	if grep -q '^core_password_hash:' $(VARS_FILE); then \
		sed -i "s|^core_password_hash:.*|core_password_hash: \"$$hash\"|" $(VARS_FILE); \
	else \
		echo "" >> $(VARS_FILE); \
		echo "# -- Core user password for RHCOS console access --" >> $(VARS_FILE); \
		echo "core_password_hash: \"$$hash\"" >> $(VARS_FILE); \
	fi; \
	echo "core_password_hash set in $(VARS_FILE)"
