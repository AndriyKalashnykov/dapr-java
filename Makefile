.DEFAULT_GOAL := help

SHELL := /bin/bash

# Ensure tools installed to ~/.local/bin (mise, act, etc.) AND mise shims
# (java, mvn, node installed by `mise install`) are on PATH for every recipe.
# The shims path lets us run `java` / `mvn` directly even when the user's
# shell hasn't sourced `eval "$(mise activate ...)"`. Also needed inside the
# act runner container where these paths are not preconfigured. Exported so
# every sub-shell the recipes spawn inherits it.
export PATH := $(HOME)/.local/share/mise/shims:$(HOME)/.local/bin:$(PATH)

# === Configuration ===
APP_NAME   := dapr-java
CURRENTTAG := $(shell git describe --tags --abbrev=0 2>/dev/null || echo "dev")

# === Tool Versions (pinned) ===
# Java and Maven pins live in .mise.toml; MAVEN_VER here only backs the
# deps-maven fallback used inside act/CI containers that lack mise.
# renovate: datasource=maven depName=org.apache.maven:apache-maven
MAVEN_VER   := 3.9.14
# renovate: datasource=github-releases depName=nektos/act
ACT_VERSION := 0.2.87

# === Prerequisites ===
OPEN_CMD := $(if $(filter Darwin,$(shell uname -s)),open,xdg-open)

#help: @ List available tasks on this project
help:
	@echo "Usage: make COMMAND"
	@echo
	@echo "Commands :"
	@echo
	@grep -E '[a-zA-Z\.\-]+:.*?@ .*$$' $(MAKEFILE_LIST)| tr -d '#' | awk 'BEGIN {FS = ":.*?@ "}; {printf "\033[32m%-18s\033[0m - %s\n", $$1, $$2}'

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
		echo "Installing Maven $(MAVEN_VER) from Apache archives..."; \
		mkdir -p $(HOME)/.local; \
		curl -fsSL "https://archive.apache.org/dist/maven/maven-3/$(MAVEN_VER)/binaries/apache-maven-$(MAVEN_VER)-bin.tar.gz" | tar xz -C $(HOME)/.local; \
		mkdir -p $(HOME)/.local/bin; \
		ln -sf "$(HOME)/.local/apache-maven-$(MAVEN_VER)/bin/mvn" "$(HOME)/.local/bin/mvn"; \
	}

#deps-act: @ Install act for local CI testing
deps-act:
	@command -v act >/dev/null 2>&1 || { echo "Installing act $(ACT_VERSION)..."; \
		mkdir -p $(HOME)/.local/bin; \
		curl -sSfL https://raw.githubusercontent.com/nektos/act/master/install.sh | bash -s -- -b $(HOME)/.local/bin v$(ACT_VERSION); \
	}

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

#lint: @ Run static analysis checks
lint: deps-check
	@mvn -B checkstyle:check -Ddependency-check.skip=true

#run: @ Run the application
run: build
	@mvn -B spring-boot:run -Ddependency-check.skip=true

#ci: @ Run full CI pipeline (clean, lint, build, test, coverage)
ci: clean lint build test coverage-check

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

#coverage-check: @ Verify code coverage meets minimum threshold (>70%)
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

.PHONY: help deps deps-check deps-maven deps-act env-check clean build test lint run \
	ci ci-run cve-check coverage-generate coverage-check coverage-open \
	print-deps-updates update-deps renovate-validate release
