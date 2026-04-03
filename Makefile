.DEFAULT_GOAL := help

SHELL := /bin/bash

# === Configuration ===
APP_NAME   := dapr-java
CURRENTTAG := $(shell git describe --tags --abbrev=0 2>/dev/null || echo "dev")

# === Tool Versions (pinned) ===
JAVA_VER    := 21-tem
MAVEN_VER   := 3.9.14
ACT_VERSION := 0.2.87
NVM_VERSION := 0.40.4
NODE_VER    := 22

# === Prerequisites ===
SDKMAN   := $${SDKMAN_DIR:-$$HOME/.sdkman}/bin/sdkman-init.sh
OPEN_CMD := $(if $(filter Darwin,$(shell uname -s)),open,xdg-open)

#help: @ List available tasks on this project
help:
	@echo "Usage: make COMMAND"
	@echo
	@echo "Commands :"
	@echo
	@grep -E '[a-zA-Z\.\-]+:.*?@ .*$$' $(MAKEFILE_LIST)| tr -d '#' | awk 'BEGIN {FS = ":.*?@ "}; {printf "\033[32m%-18s\033[0m - %s\n", $$1, $$2}'

#deps: @ Install build dependencies via SDKMAN
deps:
	@command -v curl >/dev/null 2>&1 || { echo "curl is required but not installed."; exit 1; }
	@command -v bash >/dev/null 2>&1 || { echo "bash is required but not installed."; exit 1; }
	@if [ ! -f "$(SDKMAN)" ]; then \
		echo "Installing SDKMAN..."; \
		curl -s "https://get.sdkman.io?rcupdate=false" | bash; \
	fi
	@. $(SDKMAN) && echo N | sdk install java $(JAVA_VER) && sdk use java $(JAVA_VER)
	@. $(SDKMAN) && echo N | sdk install maven $(MAVEN_VER) && sdk use maven $(MAVEN_VER)

#deps-check: @ Verify build dependencies are installed
deps-check:
	@command -v java >/dev/null 2>&1 || { echo "java is required but not installed."; exit 1; }
	@command -v mvn >/dev/null 2>&1 || { echo "mvn is required but not installed."; exit 1; }

#deps-act: @ Install act for local CI testing
deps-act: deps-check
	@command -v act >/dev/null 2>&1 || { echo "Installing act $(ACT_VERSION)..."; \
		curl -sSfL https://raw.githubusercontent.com/nektos/act/master/install.sh | sudo bash -s -- -b /usr/local/bin v$(ACT_VERSION); \
	}

#env-check: @ Check installed tools and versions
env-check: deps-check
	@echo "java: $$(java -version 2>&1 | head -1)"
	@echo "mvn:  $$(mvn -version 2>&1 | head -1)"
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

#renovate-bootstrap: @ Install nvm and npm for Renovate
renovate-bootstrap:
	@command -v node >/dev/null 2>&1 || { \
		echo "Installing nvm $(NVM_VERSION)..."; \
		curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v$(NVM_VERSION)/install.sh | bash; \
		export NVM_DIR="$$HOME/.nvm"; \
		[ -s "$$NVM_DIR/nvm.sh" ] && . "$$NVM_DIR/nvm.sh"; \
		nvm install $(NODE_VER); \
	}

#renovate-validate: @ Validate Renovate configuration
renovate-validate: renovate-bootstrap
	@npx --yes renovate --platform=local

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

.PHONY: help deps deps-check deps-act env-check clean build test lint run \
	ci ci-run cve-check coverage-generate coverage-check coverage-open \
	print-deps-updates update-deps renovate-bootstrap renovate-validate release
