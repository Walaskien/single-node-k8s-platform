CLUSTER      := platform
NAMESPACE    := apps
CERT_MANAGER := v1.16.2
DOMAIN       := example.internal
HOSTS        := app.$(DOMAIN) api.$(DOMAIN) s3.$(DOMAIN) grafana.$(DOMAIN)

.DEFAULT_GOAL := help
.PHONY: help up down status hosts trust-ca cluster platform apps wait-certs logs

help: ## Show available targets
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk -F':.*?## ' '{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

up: cluster platform apps wait-certs ## Create the cluster and deploy everything
	@echo
	@echo "Platform is up. Add hostnames to /etc/hosts if you have not:  make hosts"
	@echo "Trust the internal CA so browsers stop complaining:           make trust-ca"
	@$(MAKE) --no-print-directory status

cluster: ## Create the k3d cluster
	@k3d cluster list $(CLUSTER) >/dev/null 2>&1 && echo "cluster $(CLUSTER) already exists" \
		|| k3d cluster create --config cluster/k3d.yaml

platform: ## Install cert-manager, PKI, storage, database and observability
	kubectl apply -f platform/namespace.yaml
	helm repo add jetstack https://charts.jetstack.io --force-update
	helm upgrade --install cert-manager jetstack/cert-manager \
		--namespace cert-manager --create-namespace \
		--version $(CERT_MANAGER) --set crds.enabled=true --wait
	kubectl apply -f platform/cert-manager/
	@echo "waiting for the root CA to be issued..."
	kubectl -n cert-manager wait --for=condition=Ready certificate/internal-root-ca --timeout=120s
	kubectl apply -f platform/minio/
	kubectl apply -f platform/postgres/
	helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ --force-update
	helm upgrade --install metrics-server metrics-server/metrics-server \
		--namespace kube-system --version 3.12.2 \
		--set args="{--kubelet-insecure-tls}" --wait
	kubectl apply -f platform/observability/

wait-traefik: ## Block until k3s has finished installing Traefik
	@echo "waiting for Traefik — k3s installs it asynchronously after the API is up,"
	@echo "so applying an Ingress or Middleware too early fails on a missing CRD"
	@for i in $$(seq 1 90); do \
		if kubectl get crd middlewares.traefik.io >/dev/null 2>&1 \
		&& kubectl get ingressclass traefik >/dev/null 2>&1; then \
			echo "Traefik ready"; exit 0; \
		fi; \
		sleep 5; \
	done; \
	echo "Traefik did not become ready in time"; exit 1

apps: wait-traefik ## Deploy the demo application
	kubectl apply -f apps/demo/

wait-certs: ## Block until every certificate has been issued
	kubectl -n $(NAMESPACE) wait --for=condition=Ready certificate --all --timeout=180s

status: ## Show workloads, ingress hostnames and certificate expiry
	@echo "── workloads ─────────────────────────────────────────"
	@kubectl get pods -A --no-headers | awk '{printf "  %-16s %-46s %s\n", $$1, $$2, $$4}'
	@echo
	@echo "── ingress ───────────────────────────────────────────"
	@kubectl get ingress -A --no-headers 2>/dev/null | awk '{printf "  %-40s -> %s\n", $$4, $$1"/"$$2}' || echo "  none"
	@echo
	@echo "── certificates ──────────────────────────────────────"
	@for ns in cert-manager $(NAMESPACE); do \
		kubectl -n $$ns get certificate --no-headers 2>/dev/null | awk -v n=$$ns '{printf "  %-14s %-22s ready=%s\n", n, $$1, $$2}'; \
	done

hosts: ## Print the /etc/hosts line needed to reach the platform
	@echo "Add this line to /etc/hosts:"
	@echo
	@echo "  127.0.0.1 $(HOSTS)"
	@echo
	@echo "Then browse to https://app.$(DOMAIN):8443"

trust-ca: ## Export the root CA and show how to trust it
	@kubectl -n cert-manager get secret internal-root-ca-tls \
		-o jsonpath='{.data.tls\.crt}' | base64 -d > internal-root-ca.pem
	@echo "Root CA written to internal-root-ca.pem"
	@echo
	@echo "macOS:"
	@echo "  sudo security add-trusted-cert -d -r trustRoot -p ssl -p basic \\"
	@echo "    -k /Library/Keychains/System.keychain internal-root-ca.pem"
	@echo
	@echo "Linux (Debian/Ubuntu):"
	@echo "  sudo cp internal-root-ca.pem /usr/local/share/ca-certificates/internal-root-ca.crt"
	@echo "  sudo update-ca-certificates"

logs: ## Tail logs from the demo API
	kubectl -n $(NAMESPACE) logs -l app=demo-api -f --tail=50

down: ## Destroy the cluster
	k3d cluster delete $(CLUSTER)
	@rm -f internal-root-ca.pem
