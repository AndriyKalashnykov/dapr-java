.DEFAULT_GOAL := help

SHELL := /bin/bash

# Ensure tools installed to ~/.local/bin (mise, act, trivy, gitleaks, etc.) AND
# mise shims (java, mvn, node installed by `mise install`) are on PATH for
# every recipe. The shims path lets us run `java` / `mvn` directly even when
# the user's shell hasn't sourced `eval "$(mise activate ...)"`. Also needed
# inside the act runner container where these paths are not preconfigured.
# Exported so every sub-shell the recipes spawn inherits it.
export PATH := $(HOME)/.local/share/mise/shims:$(HOME)/.local/bin:$(PATH)

# === Configuration ===
APP_NAME   ?= $(notdir $(CURDIR))
CURRENTTAG := $(shell git describe --tags --abbrev=0 2>/dev/null || echo "dev")

# === Tool Versions (pinned) ===
# Java and Maven pins live in .mise.toml; MAVEN_VERSION here only backs the
# deps-maven fallback used inside act/CI containers that lack mise.
# renovate: datasource=maven depName=org.apache.maven:apache-maven
MAVEN_VERSION := 3.9.14
# renovate: datasource=github-releases depName=nektos/act
ACT_VERSION := 0.2.87
# renovate: datasource=github-releases depName=aquasecurity/trivy
TRIVY_VERSION := 0.69.3
# renovate: datasource=github-releases depName=gitleaks/gitleaks
GITLEAKS_VERSION := 8.30.1
# renovate: datasource=github-releases depName=google/google-java-format extractVersion=^v(?<version>.*)$
GJF_VERSION := 1.35.0
# renovate: datasource=github-releases depName=kubernetes-sigs/kind
KIND_VERSION := 0.31.0
# renovate: datasource=github-releases depName=kubernetes-sigs/cloud-provider-kind
CLOUD_PROVIDER_KIND_VERSION := 0.10.0
# renovate: datasource=docker depName=kindest/node
KIND_NODE_IMAGE := kindest/node:v1.35.0@sha256:452d707d4862f52530247495d180205e029056831160e22870e37e3f6c1ac31f
# renovate: datasource=helm depName=dapr registryUrl=https://dapr.github.io/helm-charts/
DAPR_HELM_VERSION := 1.17.4
# renovate: datasource=github-releases depName=kubernetes/kubernetes
KUBECTL_VERSION := 1.35.3
# renovate: datasource=github-releases depName=helm/helm
HELM_VERSION := 3.20.1
# renovate: datasource=docker depName=plantuml/plantuml
PLANTUML_VERSION := 1.2026.2
# renovate: datasource=docker depName=minlag/mermaid-cli
MERMAID_CLI_VERSION := 11.12.0

# === Diagrams ===
DIAGRAM_DIR := docs/diagrams
DIAGRAM_SRC := $(wildcard $(DIAGRAM_DIR)/*.puml)
DIAGRAM_OUT := $(patsubst $(DIAGRAM_DIR)/%.puml,$(DIAGRAM_DIR)/out/%.png,$(DIAGRAM_SRC))

# === KinD cluster ===
KIND_CLUSTER_NAME := $(APP_NAME)
KIND_CONTEXT := kind-$(KIND_CLUSTER_NAME)
KUBECTL_BIN := $(HOME)/.local/bin/kubectl
HELM_BIN := $(HOME)/.local/bin/helm
KUBECTL := $(KUBECTL_BIN) --context $(KIND_CONTEXT)
HELM := $(HELM_BIN) --kube-context $(KIND_CONTEXT)
# Space-separated list of services (matches Maven module dirs and k8s/ filenames)
SERVICES := pizza-store pizza-kitchen pizza-delivery
# Local image tag used by kind-deploy (overrides the public salaboy/pizza-* images
# referenced in k8s/pizza-*.yaml). Images are built via spring-boot:build-image
# and loaded into the KinD cluster with `kind load docker-image`.
E2E_IMAGE_TAG := e2e

GJF_JAR := $(HOME)/.cache/google-java-format/google-java-format-$(GJF_VERSION)-all-deps.jar
GJF_URL := https://github.com/google/google-java-format/releases/download/v$(GJF_VERSION)/google-java-format-$(GJF_VERSION)-all-deps.jar

# === Prerequisites ===
OPEN_CMD := $(if $(filter Darwin,$(shell uname -s)),open,xdg-open)

#help: @ List available tasks on this project
help:
	@echo "Usage: make COMMAND"
	@echo
	@echo "Commands :"
	@echo
	@grep -E '[a-zA-Z\.\-]+:.*?@ .*$$' $(MAKEFILE_LIST)| tr -d '#' | awk 'BEGIN {FS = ":.*?@ "}; {printf "\033[32m%-22s\033[0m - %s\n", $$1, $$2}'

#deps: @ Install build dependencies via mise (reads .mise.toml)
deps:
	@command -v curl >/dev/null 2>&1 || { echo "Error: curl is required but not installed."; exit 1; }
	@if ! command -v mise >/dev/null 2>&1; then \
		echo "Error: mise is not installed."; \
		echo "Install it with:  curl https://mise.run | sh"; \
		echo "Then activate it: echo 'eval \"\$$(~/.local/bin/mise activate bash)\"' >> ~/.bashrc"; \
		echo "                  echo 'eval \"\$$(~/.local/bin/mise activate zsh)\"'  >> ~/.zshrc"; \
		exit 1; \
	fi
	@mise install
	@mise exec -- java -version >/dev/null 2>&1 || { echo "Error: java not available after 'mise install'."; exit 1; }
	@mise exec -- mvn --version  >/dev/null 2>&1 || { echo "Error: mvn not available after 'mise install'."; exit 1; }
	@echo "Tools installed via mise. If this is a fresh install, activate mise in your shell:"
	@echo "  bash: echo 'eval \"\$$(~/.local/bin/mise activate bash)\"' >> ~/.bashrc"
	@echo "  zsh:  echo 'eval \"\$$(~/.local/bin/mise activate zsh)\"'  >> ~/.zshrc"

#deps-check: @ Verify build dependencies are installed
deps-check:
	@command -v java >/dev/null 2>&1 || { echo "Error: java is required but not installed. Run: make deps"; exit 1; }
	@command -v mvn  >/dev/null 2>&1 || { echo "Error: mvn is required but not installed. Run: make deps";  exit 1; }

#deps-maven: @ Install Maven from Apache archives (for CI containers without mise)
deps-maven:
	@command -v mvn >/dev/null 2>&1 || { \
		echo "Installing Maven $(MAVEN_VERSION) from Apache archives..."; \
		mkdir -p $(HOME)/.local; \
		curl -fsSL "https://archive.apache.org/dist/maven/maven-3/$(MAVEN_VERSION)/binaries/apache-maven-$(MAVEN_VERSION)-bin.tar.gz" | tar xz -C $(HOME)/.local; \
		mkdir -p $(HOME)/.local/bin; \
		ln -sf "$(HOME)/.local/apache-maven-$(MAVEN_VERSION)/bin/mvn" "$(HOME)/.local/bin/mvn"; \
	}

#deps-act: @ Install act for local CI testing
deps-act:
	@command -v act >/dev/null 2>&1 || { echo "Installing act $(ACT_VERSION)..."; \
		mkdir -p $(HOME)/.local/bin; \
		curl -sSfL https://raw.githubusercontent.com/nektos/act/master/install.sh | bash -s -- -b $(HOME)/.local/bin v$(ACT_VERSION); \
	}

#deps-trivy: @ Install Trivy for security scanning
deps-trivy:
	@test -x $(HOME)/.local/bin/trivy || { echo "Installing trivy $(TRIVY_VERSION)..."; \
		mkdir -p $(HOME)/.local/bin; \
		curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b $(HOME)/.local/bin v$(TRIVY_VERSION); \
	}

#deps-gitleaks: @ Install gitleaks for secret scanning
deps-gitleaks:
	@test -x $(HOME)/.local/bin/gitleaks || { echo "Installing gitleaks $(GITLEAKS_VERSION)..."; \
		mkdir -p $(HOME)/.local/bin; \
		TMPDIR=$$(mktemp -d); \
		OS=$$(uname -s | tr '[:upper:]' '[:lower:]'); \
		ARCH=$$(uname -m); \
		case "$$ARCH" in x86_64) ARCH=x64;; aarch64|arm64) ARCH=arm64;; esac; \
		curl -sSfL -o $$TMPDIR/gitleaks.tar.gz "https://github.com/gitleaks/gitleaks/releases/download/v$(GITLEAKS_VERSION)/gitleaks_$(GITLEAKS_VERSION)_$${OS}_$${ARCH}.tar.gz"; \
		tar -xzf $$TMPDIR/gitleaks.tar.gz -C $$TMPDIR gitleaks; \
		mv $$TMPDIR/gitleaks $(HOME)/.local/bin/gitleaks; \
		chmod +x $(HOME)/.local/bin/gitleaks; \
		rm -rf $$TMPDIR; \
	}

#deps-kind: @ Install KinD binary to ~/.local/bin (pinned to $(KIND_VERSION))
deps-kind:
	@mkdir -p $(HOME)/.local/bin
	@if ! test -x $(HOME)/.local/bin/kind || ! $(HOME)/.local/bin/kind version 2>/dev/null | grep -q "v$(KIND_VERSION)"; then \
		echo "Installing kind v$(KIND_VERSION)..."; \
		OS=$$(uname -s | tr '[:upper:]' '[:lower:]'); \
		ARCH=$$(uname -m); \
		case "$$ARCH" in x86_64) ARCH=amd64;; aarch64|arm64) ARCH=arm64;; esac; \
		curl -sSfL -o $(HOME)/.local/bin/kind \
			"https://kind.sigs.k8s.io/dl/v$(KIND_VERSION)/kind-$${OS}-$${ARCH}"; \
		chmod +x $(HOME)/.local/bin/kind; \
	fi
	@$(HOME)/.local/bin/kind version

#deps-kubectl: @ Install kubectl to ~/.local/bin (pinned to $(KUBECTL_VERSION))
deps-kubectl:
	@mkdir -p $(HOME)/.local/bin
	@if ! test -x $(KUBECTL_BIN) || ! $(KUBECTL_BIN) version --client 2>/dev/null | grep -q "v$(KUBECTL_VERSION)"; then \
		echo "Installing kubectl v$(KUBECTL_VERSION)..."; \
		OS=$$(uname -s | tr '[:upper:]' '[:lower:]'); \
		ARCH=$$(uname -m); \
		case "$$ARCH" in x86_64) ARCH=amd64;; aarch64|arm64) ARCH=arm64;; esac; \
		curl -sSfL -o $(KUBECTL_BIN) \
			"https://dl.k8s.io/release/v$(KUBECTL_VERSION)/bin/$${OS}/$${ARCH}/kubectl"; \
		chmod +x $(KUBECTL_BIN); \
	fi
	@$(KUBECTL_BIN) version --client | head -1

#deps-helm: @ Install helm to ~/.local/bin (pinned to $(HELM_VERSION))
deps-helm:
	@mkdir -p $(HOME)/.local/bin
	@if ! test -x $(HELM_BIN) || ! $(HELM_BIN) version --short 2>/dev/null | grep -q "v$(HELM_VERSION)"; then \
		echo "Installing helm v$(HELM_VERSION)..."; \
		OS=$$(uname -s | tr '[:upper:]' '[:lower:]'); \
		ARCH=$$(uname -m); \
		case "$$ARCH" in x86_64) ARCH=amd64;; aarch64|arm64) ARCH=arm64;; esac; \
		TMPDIR=$$(mktemp -d); \
		curl -sSfL -o $$TMPDIR/helm.tgz \
			"https://get.helm.sh/helm-v$(HELM_VERSION)-$${OS}-$${ARCH}.tar.gz"; \
		tar -xzf $$TMPDIR/helm.tgz -C $$TMPDIR; \
		mv $$TMPDIR/$${OS}-$${ARCH}/helm $(HELM_BIN); \
		rm -rf $$TMPDIR; \
		chmod +x $(HELM_BIN); \
	fi
	@$(HELM_BIN) version --short

#deps-gjf: @ Download google-java-format jar
deps-gjf: $(GJF_JAR)

$(GJF_JAR):
	@mkdir -p $(dir $(GJF_JAR))
	@echo "Downloading google-java-format $(GJF_VERSION)..."
	@curl -sSfL -o $(GJF_JAR) $(GJF_URL)

#env-check: @ Check installed tools and versions
env-check: deps-check
	@echo "java: $$(java -version 2>&1 | head -1)"
	@echo "mvn:  $$(mvn -version 2>&1 | head -1)"
	@if command -v mise >/dev/null 2>&1; then \
		echo "mise: $$(mise --version)"; \
		echo "--- mise tools ---"; \
		mise list || true; \
	else \
		echo "mise: not installed"; \
	fi
	@echo "tag:  $(CURRENTTAG)"

#clean: @ Remove build artifacts
clean: deps-check
	@mvn -B clean

#build: @ Build project
build: deps-check
	@mvn -B install -Dmaven.test.skip=true -Ddependency-check.skip=true

#test: @ Run project tests
test: deps-check
	@mvn -B test -Ddependency-check.skip=true

#integration-test: @ Run integration tests (real deps via Testcontainers, **/*IT.java via Failsafe)
integration-test: deps-check
	@mvn -B verify -P integration-test -Ddependency-check.skip=true -Dsurefire.skip=true

#lint: @ Run Checkstyle static analysis
lint: deps-check
	@mvn -B checkstyle:check -Ddependency-check.skip=true

#format: @ Auto-format Java source code (Google style)
format: deps-check $(GJF_JAR)
	@find . -path '*/src/main/java/*.java' -o -path '*/src/test/java/*.java' | \
		xargs java --add-exports=jdk.compiler/com.sun.tools.javac.api=ALL-UNNAMED \
			--add-exports=jdk.compiler/com.sun.tools.javac.file=ALL-UNNAMED \
			--add-exports=jdk.compiler/com.sun.tools.javac.parser=ALL-UNNAMED \
			--add-exports=jdk.compiler/com.sun.tools.javac.tree=ALL-UNNAMED \
			--add-exports=jdk.compiler/com.sun.tools.javac.util=ALL-UNNAMED \
			-jar $(GJF_JAR) --replace

#format-check: @ Verify code formatting (CI gate)
format-check: deps-check $(GJF_JAR)
	@find . -path '*/src/main/java/*.java' -o -path '*/src/test/java/*.java' | \
		xargs java --add-exports=jdk.compiler/com.sun.tools.javac.api=ALL-UNNAMED \
			--add-exports=jdk.compiler/com.sun.tools.javac.file=ALL-UNNAMED \
			--add-exports=jdk.compiler/com.sun.tools.javac.parser=ALL-UNNAMED \
			--add-exports=jdk.compiler/com.sun.tools.javac.tree=ALL-UNNAMED \
			--add-exports=jdk.compiler/com.sun.tools.javac.util=ALL-UNNAMED \
			-jar $(GJF_JAR) --set-exit-if-changed --dry-run > /dev/null

#trivy-fs: @ Scan filesystem for HIGH/CRITICAL vulnerabilities, secrets, and misconfigurations
trivy-fs: deps-trivy
	@$(HOME)/.local/bin/trivy fs --severity HIGH,CRITICAL --exit-code 1 .

#trivy-config: @ Scan K8s manifests for security misconfigurations (KSV-*)
trivy-config: deps-trivy
	@$(HOME)/.local/bin/trivy config --severity HIGH,CRITICAL --exit-code 1 k8s/
	@$(HOME)/.local/bin/trivy config --severity HIGH,CRITICAL --exit-code 1 k8s-dapr-shared/

#secrets: @ Scan for leaked secrets with gitleaks
secrets: deps-gitleaks
	@$(HOME)/.local/bin/gitleaks detect --source . --verbose --redact

#deps-prune: @ Analyze Maven dependencies (advisory)
deps-prune: deps-check
	@echo "--- Maven: analyzing dependencies ---"
	@mvn -B dependency:analyze

#deps-prune-check: @ Fail if unused declared Maven dependencies exist (CI gate)
deps-prune-check: deps-check
	@if mvn -B dependency:analyze 2>&1 | grep -qE '^\[WARNING\] Unused declared'; then \
		echo "ERROR: unused declared Maven dependencies found. Run 'make deps-prune' to see details."; \
		exit 1; \
	fi
	@echo "No unused declared Maven dependencies."

#diagrams: @ Render PlantUML architecture diagrams to PNG under docs/diagrams/out/
diagrams: $(DIAGRAM_OUT)

$(DIAGRAM_DIR)/out/%.png: $(DIAGRAM_DIR)/%.puml $(DIAGRAM_DIR)/_skinparam.iuml
	@mkdir -p $(DIAGRAM_DIR)/out
	@docker run --rm -u $$(id -u):$$(id -g) \
		-v "$(CURDIR)/$(DIAGRAM_DIR):/work" -w /work \
		-e HOME=/tmp -e _JAVA_OPTIONS=-Duser.home=/tmp \
		plantuml/plantuml:$(PLANTUML_VERSION) \
		-tpng -o out $(notdir $<)

#diagrams-clean: @ Remove rendered diagram artefacts
diagrams-clean:
	@rm -rf $(DIAGRAM_DIR)/out

#diagrams-check: @ Verify committed diagrams match current source (CI drift check)
diagrams-check: diagrams
	@git diff --exit-code -- $(DIAGRAM_DIR)/out || { \
		echo "ERROR: Diagram source changed but rendered output not updated. Run 'make diagrams' and commit."; \
		exit 1; \
	}

#mermaid-lint: @ Lint Mermaid code blocks embedded in markdown files
mermaid-lint:
	@files=$$(grep -rl --include='*.md' --exclude-dir=target --exclude-dir=node_modules '```mermaid' . 2>/dev/null || true); \
	if [ -z "$$files" ]; then \
		echo "No Mermaid blocks found — skipping."; \
		exit 0; \
	fi; \
	for f in $$files; do \
		echo "--- Linting Mermaid blocks in $$f ---"; \
		docker run --rm -u $$(id -u):$$(id -g) -v "$(CURDIR):/data" \
			minlag/mermaid-cli:$(MERMAID_CLI_VERSION) \
			-i "/data/$$f" -o "/data/$(DIAGRAM_DIR)/out/.mermaid-lint.png" \
			> /dev/null || { echo "FAIL: Mermaid lint failed in $$f"; exit 1; }; \
	done; \
	rm -f $(DIAGRAM_DIR)/out/.mermaid-lint*.png

#static-check: @ Composite quality gate (format-check + lint + trivy-fs + trivy-config + secrets + diagrams-check + mermaid-lint)
static-check: format-check lint trivy-fs trivy-config secrets diagrams-check mermaid-lint
	@echo "All static checks passed"

#run: @ Run the application
run: build
	@mvn -B spring-boot:run -Ddependency-check.skip=true

#ci: @ Run full CI pipeline (clean, static-check, test, integration-test, build, cve-check, coverage-check)
ci: clean deps static-check test integration-test build cve-check coverage-check

#ci-run: @ Run GitHub Actions workflow locally using act
ci-run: deps-act
	@# Prune stale containers first — Docker's overlayfs can hit a race
	@# (moby/moby#49228) where a leftover container's RWLayer is nil,
	@# producing exit 137 that looks like OOM but is a daemon bug.
	@docker container prune -f 2>/dev/null || true
	@# Random port + per-run tmpdir so concurrent `make ci-run` invocations
	@# across different repos don't race on act's default 34567.
	@ACT_PORT=$$(shuf -i 40000-59999 -n 1); \
	act push --container-architecture linux/amd64 \
		--artifact-server-port "$$ACT_PORT" \
		--artifact-server-path "$$(mktemp -d -t act-artifacts.XXXXXX)"

#cve-check: @ OWASP dependency vulnerability scan
cve-check: deps-check
	@mvn -B dependency-check:check $(if $(NVD_API_KEY),-DnvdApiKey=$(NVD_API_KEY))

#coverage-generate: @ Generate merged unit + integration coverage report
coverage-generate: deps-check
	@# Runs surefire (unit), failsafe (integration), merges exec files in
	@# the verify phase via the jacoco:merge execution, then writes the
	@# HTML report from the merged data. -Dsurefire.skip=false is explicit
	@# in case a profile disables it elsewhere.
	@mvn -B verify -P integration-test -Ddependency-check.skip=true jacoco:report

#coverage-check: @ Verify merged coverage meets minimum threshold (>=80%)
coverage-check: deps-check
	@mvn -B jacoco:check

#coverage-open: @ Open code coverage report
coverage-open: deps-check
	@for dir in pizza-store pizza-kitchen pizza-delivery; do \
		if [ -f "./$$dir/target/site/jacoco/index.html" ]; then \
			$(OPEN_CMD) "./$$dir/target/site/jacoco/index.html"; \
		fi; \
	done

#print-deps-updates: @ Print project dependencies updates
print-deps-updates: deps-check
	@mvn -B versions:display-dependency-updates

#update-deps: @ Update project dependencies to latest releases
update-deps: print-deps-updates
	@mvn -B versions:use-latest-releases versions:commit

#renovate-validate: @ Validate Renovate configuration
renovate-validate:
	@if ! command -v node >/dev/null 2>&1; then \
		if command -v mise >/dev/null 2>&1; then \
			mise exec -- npx --yes renovate --platform=local; \
		else \
			echo "Error: node is required. Run 'make deps' to install via mise."; \
			exit 1; \
		fi; \
	else \
		npx --yes renovate --platform=local; \
	fi

#image-build: @ Build OCI images for all services via spring-boot:build-image (tag $(E2E_IMAGE_TAG))
image-build: deps-check
	@for svc in $(SERVICES); do \
		echo "--- Building image for $$svc ---"; \
		mvn -B -pl $$svc -am spring-boot:build-image \
			-Dmaven.test.skip=true \
			-Ddependency-check.skip=true \
			-Dspring-boot.build-image.imageName=$$svc:$(E2E_IMAGE_TAG) \
			|| { echo "FAIL: spring-boot:build-image failed for $$svc"; exit 1; }; \
	done

#kind-create: @ Create KinD cluster, start cloud-provider-kind LB controller, install Dapr via Helm
kind-create: deps-kind deps-kubectl deps-helm
	@if $(HOME)/.local/bin/kind get clusters 2>/dev/null | grep -q "^$(KIND_CLUSTER_NAME)$$"; then \
		echo "KinD cluster $(KIND_CLUSTER_NAME) already exists; reusing."; \
	else \
		echo "Creating KinD cluster $(KIND_CLUSTER_NAME) with image $(KIND_NODE_IMAGE)..."; \
		$(HOME)/.local/bin/kind create cluster \
			--name $(KIND_CLUSTER_NAME) \
			--image $(KIND_NODE_IMAGE) \
			--config k8s/kind-config.yaml \
			--wait 120s; \
	fi
	@# cloud-provider-kind replaces MetalLB for LoadBalancer IP provisioning.
	@# It runs on the host (not in the cluster) and watches Services of type
	@# LoadBalancer to hand out IPs on the 'kind' Docker network. Kind-team
	@# maintained; works natively on kindest/node v1.35.x (MetalLB 0.15.3 hit
	@# an nftables regression there).
	@echo "--- Starting cloud-provider-kind v$(CLOUD_PROVIDER_KIND_VERSION) ---"
	@docker rm -f cloud-provider-kind >/dev/null 2>&1 || true
	@docker run --rm -d \
		--name cloud-provider-kind \
		--network kind \
		-v /var/run/docker.sock:/var/run/docker.sock \
		registry.k8s.io/cloud-provider-kind/cloud-controller-manager:v$(CLOUD_PROVIDER_KIND_VERSION) >/dev/null
	@echo "--- Installing Dapr $(DAPR_HELM_VERSION) via Helm ---"
	@$(HELM) repo add dapr https://dapr.github.io/helm-charts/ 2>/dev/null || true
	@$(HELM) repo update dapr
	@$(HELM) upgrade --install dapr dapr/dapr \
		--version $(DAPR_HELM_VERSION) \
		--namespace dapr-system --create-namespace \
		--wait --timeout 5m
	@echo "KinD cluster ready."

#kind-deploy: @ Build app images, load into KinD, apply manifests, wait for rollout
kind-deploy: kind-create image-build
	@echo "--- Loading images into KinD cluster ---"
	@for svc in $(SERVICES); do \
		$(HOME)/.local/bin/kind load docker-image $$svc:$(E2E_IMAGE_TAG) \
			--name $(KIND_CLUSTER_NAME); \
	done
	@echo "--- Deploying Redis (backs Dapr pubsub + state store for e2e) ---"
	@$(KUBECTL) apply -f k8s/redis-e2e.yaml
	@$(KUBECTL) rollout status deployment/redis --timeout=120s
	@echo "--- Applying Dapr components (redis-backed for e2e) + subscriptions ---"
	@# NOTE: k8s/pubsub.yaml (Kafka) and k8s/statestore.yaml (Postgres) are
	@# replaced with k8s/components-e2e.yaml (redis) to keep e2e hermetic.
	@# pubsub.in-memory can't be used: it's scoped per-sidecar on K8s, so
	@# cross-service event flow never happens.
	@$(KUBECTL) apply -f k8s/components-e2e.yaml
	@$(KUBECTL) apply -f k8s/subscription.yaml
	@echo "--- Applying app manifests (with local image overrides) ---"
	@for svc in $(SERVICES); do \
		sed -E "s|image: salaboy/$$svc:[^[:space:]]+|image: $$svc:$(E2E_IMAGE_TAG)|; \
			s|imagePullPolicy: Always|imagePullPolicy: IfNotPresent|" \
			k8s/$$svc.yaml | $(KUBECTL) apply -f -; \
	done
	@echo "--- Patching pizza-store Service to LoadBalancer ---"
	@$(KUBECTL) patch svc pizza-store -p '{"spec":{"type":"LoadBalancer"}}'
	@echo "--- Waiting for rollouts ---"
	@for svc in pizza-store-deployment pizza-kitchen-deployment pizza-delivery-deployment; do \
		$(KUBECTL) rollout status deployment/$$svc --timeout=300s; \
	done
	@echo "--- Waiting for LoadBalancer IP ---"
	@for i in $$(seq 1 60); do \
		ip=$$($(KUBECTL) get svc pizza-store -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null); \
		if [ -n "$$ip" ]; then echo "pizza-store LoadBalancer IP: $$ip"; exit 0; fi; \
		sleep 2; \
	done; \
	echo "FAIL: pizza-store did not get a LoadBalancer IP"; exit 1

#kind-undeploy: @ Remove app and Dapr components from KinD cluster
kind-undeploy: deps-kubectl
	@for svc in $(SERVICES); do \
		$(KUBECTL) delete -f k8s/$$svc.yaml --ignore-not-found 2>/dev/null || true; \
	done
	@$(KUBECTL) delete -f k8s/subscription.yaml --ignore-not-found 2>/dev/null || true
	@$(KUBECTL) delete -f k8s/components-e2e.yaml --ignore-not-found 2>/dev/null || true
	@$(KUBECTL) delete -f k8s/redis-e2e.yaml --ignore-not-found 2>/dev/null || true

#kind-destroy: @ Delete the KinD cluster and stop cloud-provider-kind
kind-destroy: deps-kind
	@docker rm -f cloud-provider-kind 2>/dev/null || true
	@$(HOME)/.local/bin/kind delete cluster --name $(KIND_CLUSTER_NAME) 2>/dev/null || true

#kind-up: @ Alias for kind-create + kind-deploy (full stack up)
kind-up: kind-deploy

#kind-down: @ Alias for kind-undeploy + kind-destroy (full teardown)
kind-down: kind-undeploy kind-destroy

#e2e: @ Run end-to-end tests against the deployed KinD cluster
e2e: kind-up
	@GATEWAY_IP="$$($(KUBECTL) get svc pizza-store -o jsonpath='{.status.loadBalancer.ingress[0].ip}')" \
		KUBECTL="$(KUBECTL)" \
		e2e/e2e-test.sh
	@# Tear-down is manual by default to allow post-mortem on failure.
	@# Uncomment the next line to auto-teardown on success:
	@# $(MAKE) kind-down

#release: @ Create a release tag with semver validation (usage: make release VERSION=x.y.z)
release:
	@if [ -z "$(VERSION)" ]; then \
		echo "Error: VERSION is required. Usage: make release VERSION=x.y.z"; \
		exit 1; \
	fi
	@if ! echo "$(VERSION)" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$$'; then \
		echo "Error: VERSION must follow semver format (x.y.z). Got: $(VERSION)"; \
		exit 1; \
	fi
	@echo -n "Create tag v$(VERSION)? [y/N] " && read ans && [ "$${ans:-N}" = y ] || { echo "Aborted."; exit 1; }
	@git tag -a "v$(VERSION)" -m "Release v$(VERSION)"
	@echo "Release tag v$(VERSION) created. Push with: git push origin v$(VERSION)"

.PHONY: help deps deps-check deps-maven deps-act deps-trivy deps-gitleaks deps-gjf \
	deps-kind deps-kubectl deps-helm \
	env-check clean build test integration-test lint format format-check \
	trivy-fs trivy-config secrets deps-prune deps-prune-check static-check run \
	ci ci-run cve-check coverage-generate coverage-check coverage-open \
	print-deps-updates update-deps renovate-validate \
	image-build kind-create kind-deploy kind-undeploy kind-destroy \
	kind-up kind-down e2e release \
	diagrams diagrams-clean diagrams-check mermaid-lint
