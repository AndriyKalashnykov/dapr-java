.DEFAULT_GOAL := help

SHELL := /bin/bash
SDKMAN := $(HOME)/.sdkman/bin/sdkman-init.sh
CURRENT_USER_NAME := $(shell whoami)

JAVA_VER :=  21-tem
MAVEN_VER := 3.9.1

SDKMAN_EXISTS := $(if $(SDKMAN_DIR),@printf "sdkman",@echo "SDKMAN_DIR is undefined" && exit 1)

IS_DARWIN := 0
IS_LINUX := 0
IS_FREEBSD := 0
IS_WINDOWS := 0
IS_AMD64 := 0
IS_AARCH64 := 0
IS_RISCV64 := 0

# Platform and architecture detection
ifeq ($(OS), Windows_NT)
	IS_WINDOWS := 1
	# Windows architecture detection using PROCESSOR_ARCHITECTURE
	ifeq ($(PROCESSOR_ARCHITECTURE), AMD64)
		IS_AMD64 := 1
	else ifeq ($(PROCESSOR_ARCHITECTURE), x86)
		# 32-bit x86 - you might want to add IS_X86 := 1 if needed
		IS_AMD64 := 0
	else ifeq ($(PROCESSOR_ARCHITECTURE), ARM64)
		IS_AARCH64 := 1
	else
		# Fallback: check PROCESSOR_ARCHITEW6432 for 32-bit processes on 64-bit systems
		ifeq ($(PROCESSOR_ARCHITEW6432), AMD64)
			IS_AMD64 := 1
		else ifeq ($(PROCESSOR_ARCHITEW6432), ARM64)
			IS_AARCH64 := 1
		else
			# Default to AMD64 if unable to determine
			IS_AMD64 := 1
		endif
	endif
else
	# Unix-like systems - detect platform and architecture
	UNAME_S := $(shell uname -s)
	UNAME_M := $(shell uname -m)

	# Platform detection
	ifeq ($(UNAME_S), Darwin)
		IS_DARWIN := 1
	else ifeq ($(UNAME_S), Linux)
		IS_LINUX := 1
	else ifeq ($(UNAME_S), FreeBSD)
		IS_FREEBSD := 1
	else
		$(error Unsupported platform: $(UNAME_S). Supported platforms: Darwin, Linux, FreeBSD, Windows_NT)
	endif

	# Architecture detection
	ifneq (, $(filter $(UNAME_M), x86_64 amd64))
		IS_AMD64 := 1
	else ifneq (, $(filter $(UNAME_M), aarch64 arm64))
		IS_AARCH64 := 1
	else ifneq (, $(filter $(UNAME_M), riscv64))
		IS_RISCV64 := 1
	else
		$(error Unsupported architecture: $(UNAME_M). Supported architectures: x86_64/amd64, aarch64/arm64, riscv64)
	endif
endif

.PHONY: help deps deps-check env-check clean test build lint run ci cve-check coverage-generate coverage-check coverage-open print-deps-updates update-deps release

#help: @ List available tasks on this project
help:
	@clear
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
	@echo "All build dependencies are available."

#env-check: @ Check installed tools
env-check: deps-check
	@printf "\xE2\x9C\x94 "
	@$(SDKMAN_EXISTS)
	@printf "\n"

#clean: @ Cleanup
clean:
	@mvn clean

#test: @ Run project tests
test: build
	@mvn test -Ddependency-check.skip=true

#build: @ Build project
build:
	@mvn package install -Dmaven.test.skip=true -Ddependency-check.skip=true

#lint: @ Run static analysis checks
lint:
	@mvn checkstyle:check -Ddependency-check.skip=true

#run: @ Run the application
run: build
	@mvn spring-boot:run -Ddependency-check.skip=true

#ci: @ Run full CI pipeline (clean, build, test)
ci: clean build test

# mvn org.owasp:dependency-check-maven:12.1.3:check -DnvdApiKey=${NVD_API_KEY}
#cve-check: @ Run dependencies check for publicly disclosed vulnerabilities in application dependencies
cve-check:
	@mvn dependency-check:check $(if $(NVD_API_KEY),-DnvdApiKey=$(NVD_API_KEY))

#coverage-generate: @ Generate code coverage report
coverage-generate:
	@mvn test -Ddependency-check.skip=true jacoco:report

#coverage-check: @ Verify code coverage meets minimum threshold ( > 70%)
coverage-check:
	@mvn jacoco:check

#coverage-open: @ Open code coverage report
coverage-open:
	@for dir in pizza-store pizza-kitchen pizza-delivery; do \
		if [ -f "./$$dir/target/site/jacoco/index.html" ]; then \
			$(if $(filter 1,$(IS_DARWIN)),open,xdg-open) "./$$dir/target/site/jacoco/index.html"; \
		fi; \
	done

#print-deps-updates: @ Print project dependencies updates
print-deps-updates:
	@mvn versions:display-dependency-updates

#update-deps: @ Update project dependencies to latest releases
update-deps: print-deps-updates
	@mvn versions:use-latest-releases
	@mvn versions:commit

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
	@echo "Creating release tag v$(VERSION)..."
	@git tag -a "v$(VERSION)" -m "Release v$(VERSION)"
	@echo "Release tag v$(VERSION) created. Push with: git push origin v$(VERSION)"
