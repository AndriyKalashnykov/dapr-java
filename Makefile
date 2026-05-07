.DEFAULT_GOAL := help

SHELL := /bin/bash

# Ensure tools installed to ~/.local/bin (mise itself, plus jars/scripts that
# don't fit into mise) AND mise shims (java, mvn, node, kubectl, helm, kind,
# act, trivy, gitleaks installed by `mise install`) are on PATH for every
# recipe. The shims path lets us run those tools directly even when the
# user's shell hasn't sourced `eval "$(mise activate ...)"`. Also needed
# inside the act runner container where these paths are not preconfigured.
# Exported so every sub-shell the recipes spawn inherits it.
export PATH := $(HOME)/.local/share/mise/shims:$(HOME)/.local/bin:$(PATH)

# === Configuration ===
APP_NAME   ?= $(notdir $(CURDIR))
CURRENTTAG := $(shell git describe --tags --abbrev=0 2>/dev/null || echo "dev")

# === Tool Versions (pinned) ===
# Single source of truth: .mise.toml. Tools managed by mise (java, maven,
# node, act, trivy, gitleaks, kind, kubectl, helm) are NOT pinned again here
# — `mise install` is the install path; mise shims provide the binaries.
#
# Constants below are for tools that mise cannot manage:
#   - GJF_VERSION:                  jar download (no binary)
#   - KIND_NODE_IMAGE:              Docker image (not a host binary)
#   - DAPR_HELM_VERSION:            Helm chart version (not a binary)
#   - PLANTUML_VERSION:             Docker image
#   - MERMAID_CLI_VERSION:          Docker image
#   - CLOUD_PROVIDER_KIND_VERSION:  Docker image (controller runs as a
#                                   container on the host, not a binary)
#   - MAVEN_VERSION:                derived from .mise.toml so the
#                                   deps-maven Apache-archives fallback (used
#                                   only by CI containers without mise)
#                                   tracks the same version as mise.
MAVEN_VERSION := $(shell awk -F'"' '/^maven *= *"/ {print $$2; exit}' .mise.toml)
# renovate: datasource=github-releases depName=google/google-java-format extractVersion=^v(?<version>.*)$
GJF_VERSION := 1.35.0
# renovate: datasource=docker depName=registry.k8s.io/cloud-provider-kind/cloud-controller-manager
CLOUD_PROVIDER_KIND_VERSION := 0.10.0
# renovate: datasource=docker depName=kindest/node
KIND_NODE_IMAGE := kindest/node:v1.35.1@sha256:05d7bcdefbda08b4e038f644c4df690cdac3fba8b06f8289f30e10026720a1ab
# renovate: datasource=helm depName=dapr registryUrl=https://dapr.github.io/helm-charts/
DAPR_HELM_VERSION := 1.17.6
# renovate: datasource=docker depName=plantuml/plantuml
PLANTUML_VERSION := 1.2026.2
# renovate: datasource=docker depName=minlag/mermaid-cli
MERMAID_CLI_VERSION := 11.14.0

# === Diagrams ===
DIAGRAM_DIR := docs/diagrams
DIAGRAM_SRC := $(wildcard $(DIAGRAM_DIR)/*.puml)
DIAGRAM_OUT := $(patsubst $(DIAGRAM_DIR)/%.puml,$(DIAGRAM_DIR)/out/%.png,$(DIAGRAM_SRC))

# === KinD cluster ===
KIND_CLUSTER_NAME := $(APP_NAME)
KIND_CONTEXT := kind-$(KIND_CLUSTER_NAME)
KUBECTL := kubectl --context $(KIND_CONTEXT)
HELM := helm --kube-context $(KIND_CONTEXT)
# Space-separated list of services (matches Maven module dirs and k8s/ filenames)
SERVICES := pizza-store pizza-kitchen pizza-delivery
# Local image tag used by kind-deploy (overrides the ghcr.io/andriykalashnykov/
# pizza-* images referenced in k8s/pizza-*.yaml). Images are built via
# spring-boot:build-image and loaded into the KinD cluster with
# `kind load docker-image` so e2e runs the freshly-built bits rather than
# pulling from GHCR.
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
trivy-fs:
	@trivy fs --severity HIGH,CRITICAL --exit-code 1 .

#trivy-config: @ Scan K8s manifests for security misconfigurations (KSV-*)
trivy-config:
	@trivy config --severity HIGH,CRITICAL --exit-code 1 k8s/
	@trivy config --severity HIGH,CRITICAL --exit-code 1 k8s-dapr-shared/

#k8s-validate: @ Validate k8s/ and k8s-dapr-shared/ manifests against vendored OpenAPI (kubeconform)
# k8s-dapr-shared is an alternate "shared sidecar" topology that is NOT
# exercised by `make e2e`. Without this gate, drift between the two manifest
# trees ships silently and only surfaces on a manual `kubectl apply -f
# k8s-dapr-shared/`. kubeconform validates against vendored OpenAPI schemas,
# so no cluster is required — wires cleanly into static-check on every push.
# -ignore-missing-schemas tolerates Dapr CRDs (Component, Subscription)
# whose schemas aren't in the upstream master-standalone bundle.
k8s-validate:
	@command -v kubeconform >/dev/null 2>&1 || { echo "Error: kubeconform is required (run 'mise install')."; exit 1; }
	@kubeconform -strict -ignore-missing-schemas -summary k8s/
	@kubeconform -strict -ignore-missing-schemas -summary k8s-dapr-shared/

#secrets: @ Scan for leaked secrets with gitleaks
secrets:
	@gitleaks detect --source . --verbose --redact

#deps-prune: @ Analyze Maven dependencies (advisory)
deps-prune: deps-check
	@echo "--- Maven: analyzing dependencies ---"
	@mvn -B dependency:analyze

#deps-prune-check: @ Fail if unused declared Maven dependencies exist (CI gate)
deps-prune-check: deps-check
	@# pipefail required: without it, a `mvn` crash before the WARNING line
	@# returns grep's exit code only — a build-tool failure would silently
	@# pass this gate. SHELL := /bin/bash is set at top of Makefile.
	@set -o pipefail; \
	if mvn -B dependency:analyze 2>&1 | grep -qE '^\[WARNING\] Unused declared'; then \
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
# Renders each Mermaid block to SVG via the same engine GitHub uses;
# render success == lint pass. Source is mounted read-only (defense in
# depth — a buggy mmdc can't write into the repo) and output goes to
# /tmp INSIDE the container, which the `--rm` cleanup discards when the
# container exits. No host bind mount for output, no scratch PNGs in
# `docs/diagrams/out/` — committed-asset territory stays untouched.
mermaid-lint:
	@files=$$(grep -rl --include='*.md' --exclude-dir=.git --exclude-dir=target --exclude-dir=node_modules '```mermaid' . 2>/dev/null || true); \
	if [ -z "$$files" ]; then \
		echo "No Mermaid blocks found — skipping."; \
		exit 0; \
	fi; \
	for f in $$files; do \
		echo "--- Linting Mermaid blocks in $$f ---"; \
		docker run --rm -u $$(id -u):$$(id -g) \
			-v "$(CURDIR):/data:ro" \
			minlag/mermaid-cli:$(MERMAID_CLI_VERSION) \
			-i "/data/$$f" -o "/tmp/$$(basename $$f .md).svg" \
			> /dev/null || { echo "FAIL: Mermaid lint failed in $$f"; exit 1; }; \
	done

#static-check: @ Composite quality gate (format-check + lint + trivy-fs + trivy-config + secrets + diagrams-check + mermaid-lint + k8s-validate)
static-check: format-check lint trivy-fs trivy-config secrets diagrams-check mermaid-lint k8s-validate
	@echo "All static checks passed"

#run: @ Run the application
run: build
	@mvn -B spring-boot:run -Ddependency-check.skip=true

#ci: @ Run local CI pipeline (clean, static-check, coverage-generate, coverage-check, build). cve-check is separate — run `make cve-check` explicitly.
# coverage-generate runs `mvn verify -P integration-test` which executes BOTH
# Surefire (unit) and Failsafe (integration) tests once and merges their
# JaCoCo exec files. Listing `test` and `integration-test` separately would
# triple-run the suite (test runs surefire; integration-test runs failsafe;
# coverage-generate re-runs both via verify). The producer-once chain saves
# ~30-60s per `make ci` invocation.
ci: clean deps static-check coverage-generate coverage-check build

#ci-run: @ Run GitHub Actions workflow locally using act (jobs serialized)
ci-run: deps
	@# Prune stale containers first — Docker's overlayfs can hit a race
	@# (moby/moby#49228) where a leftover container's RWLayer is nil,
	@# producing exit 137 that looks like OOM but is a daemon bug.
	@docker container prune -f 2>/dev/null || true
	@# Jobs are invoked one at a time via `act --job`. On real GitHub runners
	@# `test` and `integration-test` run in parallel (each on its own VM with
	@# its own network), but under act both jobs share the host Docker daemon
	@# and would collide on Testcontainers-Dapr's `DEFINED_PORT` (8080).
	@# Serializing here keeps `ci-run` honest locally without slowing down
	@# GitHub CI.
	@#
	@# Skipped jobs:
	@#   - e2e:       requires Docker-in-Docker KinD + host-networked
	@#                cloud-provider-kind; step-level `if: !env.ACT` no-ops
	@#                the actual test run anyway. Verify via `make e2e`.
	@#   - cve-check: the actual OWASP scan is step-level `if: !env.ACT` so
	@#                the iteration would only spin up the runner container,
	@#                skip the scan, and tear down — pure overhead (+60-90s
	@#                and exposure to Docker Hub registry flakes). Verify
	@#                via `make cve-check`.
	@#   - ci-pass:   aggregator over e2e; only meaningful on real CI.
	@#
	@# Random artifact-server port + per-run tmpdir so concurrent
	@# `make ci-run` invocations across repos don't race on act's default.
	@#
	@# Synthetic event payload: act push events do NOT populate
	@# `repository.default_branch` or `event.before`, both of which
	@# `dorny/paths-filter` requires to compute the diff. Provide them so
	@# the `changes` job resolves and downstream gated jobs run as on real CI.
	@ACT_PORT=$$(shuf -i 40000-59999 -n 1); \
	ARTIFACT_PATH=$$(mktemp -d -t act-artifacts.XXXXXX); \
	EVENT_PATH=$$(mktemp -t act-event.XXXXXX.json); \
	BEFORE=$$(git rev-parse HEAD~1 2>/dev/null || git rev-parse HEAD); \
	HEAD=$$(git rev-parse HEAD); \
	printf '{"repository":{"default_branch":"main","name":"%s","owner":{"login":"%s"}},"before":"%s","after":"%s","ref":"refs/heads/main","pusher":{"name":"local"}}' \
		"$(APP_NAME)" "local" "$$BEFORE" "$$HEAD" > "$$EVENT_PATH"; \
	for j in changes static-check build test integration-test; do \
		echo ""; \
		echo "============================================================"; \
		echo "  act push --job $$j"; \
		echo "============================================================"; \
		act push --job $$j --container-architecture linux/amd64 \
			--eventpath "$$EVENT_PATH" \
			--artifact-server-port "$$ACT_PORT" \
			--artifact-server-path "$$ARTIFACT_PATH" || exit 1; \
	done; \
	rm -f "$$EVENT_PATH"

#cve-check: @ OWASP dependency vulnerability scan
cve-check: deps-check
	@# Route the NVD API key through ~/.m2/settings.xml + -DnvdApiServerId=nvd
	@# instead of -DnvdApiKey=$$VAR. The flag form would expand $$NVD_API_KEY
	@# into mvn's argv at exec time and leak the value via `ps -ef` /
	@# `/proc/<pid>/cmdline` for the entire ~30-min plugin lifetime
	@# (settings.xml stays on disk with mode 0600). printf is a bash builtin —
	@# the value never lands in argv.
	@if [ -n "$$NVD_API_KEY" ]; then \
		mkdir -p $$HOME/.m2; \
		( umask 077 && printf '<settings><servers><server><id>nvd</id><password>%s</password></server></servers></settings>\n' "$$NVD_API_KEY" > $$HOME/.m2/settings.xml ); \
		mvn -B dependency-check:check -DnvdApiServerId=nvd; \
	else \
		mvn -B dependency-check:check; \
	fi

#coverage-generate: @ Generate merged unit + integration coverage report
coverage-generate: deps-check
	@# Runs surefire (unit), failsafe (integration), merges exec files in
	@# the verify phase via the jacoco:merge execution, then writes the
	@# HTML report from the merged data. -Dsurefire.skip=false is explicit
	@# in case a profile disables it elsewhere.
	@mvn -B verify -P integration-test -Ddependency-check.skip=true jacoco:report

#coverage-check: @ Verify merged coverage meets minimum threshold (>=80%)
# Does NOT depend on coverage-generate so the `ci:` chain can run
# coverage-generate once and have coverage-check run guards-only against
# the existing merged exec files. Standalone usage: run `make
# coverage-generate` (or `make integration-test`) first.
coverage-check: deps-check
	@for d in $(SERVICES); do \
		if [ ! -f "$$d/target/jacoco-merged.exec" ]; then \
			echo "ERROR: $$d/target/jacoco-merged.exec missing — run 'make coverage-generate' first."; \
			exit 1; \
		fi; \
	done
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
renovate-validate: deps
	@npx --yes renovate --platform=local

#image-build: @ Build OCI images for all services via spring-boot:build-image (tag $(E2E_IMAGE_TAG))
# Note: no `build` prerequisite — spring-boot:build-image is self-contained
# (compiles + packages the jar in-process before assembling the OCI image),
# so a separate `build` step would only duplicate work.
image-build: deps-check
	@for svc in $(SERVICES); do \
		echo "--- Building image for $$svc ---"; \
		mvn -B -pl $$svc -am spring-boot:build-image \
			-Dmaven.test.skip=true \
			-Ddependency-check.skip=true \
			-Dspring-boot.build-image.imageName=$$svc:$(E2E_IMAGE_TAG) \
			|| { echo "FAIL: spring-boot:build-image failed for $$svc"; exit 1; }; \
	done

#image-scan: @ Scan built OCI images for HIGH/CRITICAL CVEs (covers Paketo base layers — Renovate blind spot)
image-scan: image-build
	@# spring-boot:build-image uses Paketo CNB builders; the resulting image
	@# layers (JRE + base OS) are NOT visible to `trivy-fs` (which scans the
	@# workspace) or `cve-check` (which scans Maven deps). Scanning the built
	@# OCI image closes that gap. --ignore-unfixed keeps the gate actionable
	@# (only advisories with an available patch fail the build).
	@for svc in $(SERVICES); do \
		echo "--- Scanning image $$svc:$(E2E_IMAGE_TAG) ---"; \
		trivy image \
			--severity HIGH,CRITICAL \
			--ignore-unfixed \
			--exit-code 1 \
			--no-progress \
			$$svc:$(E2E_IMAGE_TAG) \
			|| { echo "FAIL: trivy image scan found fixable HIGH/CRITICAL CVEs in $$svc:$(E2E_IMAGE_TAG)"; exit 1; }; \
	done

#kind-create: @ Create KinD cluster, start cloud-provider-kind LB controller, install Dapr via Helm
kind-create: deps-check
	@# Preflight: warn if sibling KinD clusters share the default `kind` Docker
	@# bridge network. Their kube-proxies both DNAT 10.96.0.1:443 (in-cluster
	@# API ClusterIP) → their own API server, and the rule sets collide on the
	@# shared bridge. Symptom: dapr-operator CrashLoopBackOff with
	@# `dial tcp 10.96.0.1:443: i/o timeout`. Reproduced identically under
	@# Helm 3.20.2 and Helm 4.1.4 — not a Helm bug. Tracked in CLAUDE.md backlog.
	@others=$$(docker network inspect kind --format '{{range .Containers}}{{.Name}}{{"\n"}}{{end}}' 2>/dev/null | grep -E 'control-plane$$' | grep -v "^$(KIND_CLUSTER_NAME)-control-plane$$" || true); \
	if [ -n "$$others" ]; then \
		echo ""; \
		echo "WARNING: sibling KinD cluster(s) on the 'kind' Docker network:"; \
		echo "$$others" | sed 's/^/    /'; \
		echo "    Multiple clusters share kube-proxy iptables/nftables rules. The"; \
		echo "    in-cluster API ClusterIP (10.96.0.1) routes can collide; pods like"; \
		echo "    dapr-operator may hit 'dial tcp 10.96.0.1:443: i/o timeout'."; \
		echo "    Stop the other cluster(s) before retrying e2e:"; \
		echo "      kind delete cluster --name <name>"; \
		echo ""; \
	fi
	@if kind get clusters 2>/dev/null | grep -q "^$(KIND_CLUSTER_NAME)$$"; then \
		echo "KinD cluster $(KIND_CLUSTER_NAME) already exists; reusing."; \
	else \
		echo "Creating KinD cluster $(KIND_CLUSTER_NAME) with image $(KIND_NODE_IMAGE)..."; \
		kind create cluster \
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

#kind-deploy: @ Build + scan app images, load into KinD, apply manifests, wait for rollout
kind-deploy: kind-create image-build image-scan
	@echo "--- Loading images into KinD cluster ---"
	@for svc in $(SERVICES); do \
		kind load docker-image $$svc:$(E2E_IMAGE_TAG) \
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
	@# Manifests ship ghcr.io/andriykalashnykov/* images for prod; swap to
	@# the locally-built $$svc:e2e images so KinD uses the freshly-loaded
	@# bits instead of pulling from GHCR.
	@for svc in $(SERVICES); do \
		sed -E "s|image: ghcr.io/andriykalashnykov/dapr-java/$$svc:[^[:space:]]+|image: $$svc:$(E2E_IMAGE_TAG)|; \
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

#k8s-shared-deploy: @ Deploy alternate "shared sidecar" topology (k8s-dapr-shared/) to running cluster
# Manual target — NOT wired into `make e2e` or CI. Use after `make kind-create`
# to validate the alternate topology end-to-end. The pizza-store LoadBalancer
# Service is the same shape as the default topology, so e2e/e2e-test.sh runs
# against it unchanged. See k8s-dapr-shared/README.md for the topology rationale.
k8s-shared-deploy: deps-check
	@echo "--- Loading images into KinD cluster (if not present) ---"
	@for svc in $(SERVICES); do \
		kind load docker-image $$svc:$(E2E_IMAGE_TAG) --name $(KIND_CLUSTER_NAME) 2>&1 | tail -1; \
	done
	@echo "--- Deploying Redis (backs Dapr pubsub + state store) ---"
	@$(KUBECTL) apply -f k8s/redis-e2e.yaml
	@$(KUBECTL) rollout status deployment/redis --timeout=120s
	@echo "--- Applying Dapr components (redis-backed) + subscriptions ---"
	@$(KUBECTL) apply -f k8s/components-e2e.yaml
	@$(KUBECTL) apply -f k8s/subscription.yaml
	@echo "--- Applying shared-sidecar app manifests (with local image overrides) ---"
	@sed -E "s|image: ghcr.io/andriykalashnykov/dapr-java/(pizza-(store|kitchen|delivery)):[^[:space:]]+|image: \\1:$(E2E_IMAGE_TAG)|g; \
		s|imagePullPolicy: Always|imagePullPolicy: IfNotPresent|" \
		k8s-dapr-shared/apps.yaml | $(KUBECTL) apply -f -
	@echo "--- Patching pizza-store Service to LoadBalancer ---"
	@$(KUBECTL) patch svc pizza-store -p '{"spec":{"type":"LoadBalancer"}}' 2>/dev/null || true
	@echo "Shared-sidecar topology deployed. Validate with e2e/e2e-test.sh against the LoadBalancer IP."

#k8s-shared-undeploy: @ Remove the alternate shared-sidecar topology from the cluster
k8s-shared-undeploy: deps-check
	@$(KUBECTL) delete -f k8s-dapr-shared/apps.yaml --ignore-not-found 2>/dev/null || true
	@$(KUBECTL) delete -f k8s/subscription.yaml --ignore-not-found 2>/dev/null || true
	@$(KUBECTL) delete -f k8s/components-e2e.yaml --ignore-not-found 2>/dev/null || true
	@$(KUBECTL) delete -f k8s/redis-e2e.yaml --ignore-not-found 2>/dev/null || true

#kind-undeploy: @ Remove app and Dapr components from KinD cluster
kind-undeploy: deps-check
	@for svc in $(SERVICES); do \
		$(KUBECTL) delete -f k8s/$$svc.yaml --ignore-not-found 2>/dev/null || true; \
	done
	@$(KUBECTL) delete -f k8s/subscription.yaml --ignore-not-found 2>/dev/null || true
	@$(KUBECTL) delete -f k8s/components-e2e.yaml --ignore-not-found 2>/dev/null || true
	@$(KUBECTL) delete -f k8s/redis-e2e.yaml --ignore-not-found 2>/dev/null || true

#kind-destroy: @ Delete the KinD cluster, stop cloud-provider-kind, prune kindccm-* orphans
kind-destroy: deps-check
	@docker rm -f cloud-provider-kind 2>/dev/null || true
	@# cloud-provider-kind launches per-Service `kindccm-<hash>` Envoy sidecar
	@# containers on the `kind` Docker network. They survive `kind delete
	@# cluster` and hold IPs in the kind subnet — a subsequent `kind-up` can
	@# land on an orphan's IP and inherit its stale Envoy config (pointed at
	@# dead pods from the previous run), producing "Connection reset by peer"
	@# on the first curl. Prune them before deleting the cluster.
	@orphans=$$(docker ps -aq --filter 'name=kindccm-' 2>/dev/null); \
	if [ -n "$$orphans" ]; then \
		echo "Removing kindccm-* orphan sidecar(s)..."; \
		echo "$$orphans" | xargs docker rm -f >/dev/null 2>&1 || true; \
	fi
	@kind delete cluster --name $(KIND_CLUSTER_NAME) 2>/dev/null || true

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

#pre-release: @ Run every slow gate that's NOT in `make ci` (cve-check + image-scan). Required before `make release`.
pre-release:
	@# cve-check + image-scan are both strict gates. dependency-check 12.2.2
	@# (2026-05-03) ships the open-vulnerability-clients fix for the NVD
	@# 9-digit nanosecond timestamp deserializer bug (PR #8427), so the
	@# previous `timeout 300` + soft-fail wrapper is no longer needed.
	@$(MAKE) cve-check
	@$(MAKE) image-scan
	@echo "Pre-release gates passed."

#release: @ Create a release tag with semver validation (usage: make release VERSION=x.y.z)
#          Runs `pre-release` first so a failing OWASP or image scan blocks the
#          tag before any ref is written. This is the only reliable local
#          checkpoint for Paketo-layer CVEs (they're not in `make ci`).
release: pre-release
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

.PHONY: help deps deps-check deps-maven deps-gjf \
	env-check clean build test integration-test lint format format-check \
	trivy-fs trivy-config secrets deps-prune deps-prune-check static-check run \
	ci ci-run cve-check coverage-generate coverage-check coverage-open \
	print-deps-updates update-deps renovate-validate \
	image-build image-scan kind-create kind-deploy kind-undeploy kind-destroy \
	kind-up kind-down e2e pre-release release \
	diagrams diagrams-clean diagrams-check mermaid-lint k8s-validate \
	k8s-shared-deploy k8s-shared-undeploy
