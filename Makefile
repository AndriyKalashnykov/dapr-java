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
APP_NAME   := dapr-java
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
	@mvn -B verify -P integration-test -Ddependency-check.skip=true -DskipTests=true

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

#static-check: @ Composite quality gate (format-check + lint + trivy-fs + trivy-config + secrets)
static-check: format-check lint trivy-fs trivy-config secrets
	@echo "All static checks passed"

#run: @ Run the application
run: build
	@mvn -B spring-boot:run -Ddependency-check.skip=true

#ci: @ Run full CI pipeline (clean, static-check, test, integration-test, build, cve-check, coverage-check)
ci: clean deps static-check test integration-test build cve-check coverage-check

#ci-run: @ Run GitHub Actions workflow locally using act
ci-run: deps-act
	@act push --container-architecture linux/amd64 \
		--artifact-server-path /tmp/act-artifacts

#cve-check: @ OWASP dependency vulnerability scan
cve-check: deps-check
	@mvn -B dependency-check:check $(if $(NVD_API_KEY),-DnvdApiKey=$(NVD_API_KEY))

#coverage-generate: @ Generate code coverage report
coverage-generate: deps-check
	@mvn -B test -Ddependency-check.skip=true jacoco:report

#coverage-check: @ Verify code coverage meets minimum threshold (>80%)
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
	env-check clean build test integration-test lint format format-check \
	trivy-fs trivy-config secrets deps-prune deps-prune-check static-check run \
	ci ci-run cve-check coverage-generate coverage-check coverage-open \
	print-deps-updates update-deps renovate-validate release
