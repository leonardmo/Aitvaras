# Canonical entry points for humans, agents and CI (see AGENTS.md).
SHELL := /bin/bash
.DEFAULT_GOAL := help

XCODE_FLAGS := -project Aitvaras.xcodeproj -scheme Aitvaras \
	-skipMacroValidation -skipPackagePluginValidation
NODE_TESTS := scripts/test-claude-interactive.mjs scripts/check-codex-interactive.mjs \
	scripts/check-codex-native.mjs scripts/check-codex-shared-runtime.mjs

.PHONY: help setup test node-test project app e2e ui live release privacy commits check smoke install clean

help: ## List targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-10s %s\n", $$1, $$2}'

setup: ## Install the git hooks and the private denylist template (once per clone)
	scripts/install-hooks.sh
	@echo "Hooks enabled. Commit author: $$(git config user.email)"

test: ## Package tests, serial like CI (the suite has timing tests that fail in parallel)
	swift test --no-parallel

node-test: ## Offline contract tests for the Node sidecar helpers
	@set -e; for t in $(NODE_TESTS); do echo "── $$t"; node $$t; done

project: ## Generate Aitvaras.xcodeproj from project.yml
	xcodegen generate --quiet

# Full logs go to <derived data>/build.log; failures print the errors.
define xcodebuild_logged
	@mkdir -p $(2); xcodebuild $(XCODE_FLAGS) -configuration $(1) -derivedDataPath $(2) build \
		> $(2)/build.log 2>&1 \
		&& tail -1 $(2)/build.log \
		|| { grep -E ' error: |error: |BUILD FAILED' $(2)/build.log | sort -u | head -40; \
		     echo "Full log: $(2)/build.log"; exit 1; }
endef

app: project ## Debug app build into .build-xcode
	$(call xcodebuild_logged,Debug,.build-xcode)

# Real clicks and real window screenshots. A separate bundle id keeps XCUITest
# away from a running installed app. Screenshots land in .build-e2e/screenshots.
e2e: project ## Real-app UI tests with an isolated profile and bundle id
	scripts/run-e2e.sh $(E2E_FILTER)

# The same real app and real CLIs, driven from inside its own process: no permission,
# no password, and the mouse and keyboard stay yours.
ui: ## Real-app chat scenario with no system permission
	scripts/run-self-drive.sh $(UI_SCENARIO)

# Real CLIs on the real login. Runs from a launchd-style environment on purpose,
# because a GUI app gets none of the shell's variables. Spends a little usage.
live: ## Live provider checks against the installed CLIs
	swift build --build-tests -q
	env -i HOME="$$HOME" USER="$$USER" LOGNAME="$$USER" SHELL="$$SHELL" TMPDIR="$$TMPDIR" LANG=en_US.UTF-8 \
		PATH=/usr/bin:/bin:/usr/sbin:/sbin AITVARAS_LIVE_AGENTS=1 \
		"$$(xcrun -f swift)" test --skip-build --no-parallel --filter AgentLiveTests

release: project ## Release app build into .build/DerivedData
	$(call xcodebuild_logged,Release,.build/DerivedData)

privacy: ## Privacy and secret sweep over tracked files
	scripts/check-privacy.sh

commits: ## Check commit metadata on this branch against origin/main
	scripts/check-commits.sh origin/main..HEAD

check: privacy node-test test ## Everything except the app build (before every commit)

smoke: check app ## check + app build (before PRs touching App/ or project.yml)

install: ## Release build installed to /Applications
	scripts/build-release.sh

clean: ## Remove build products
	rm -rf .build .build-xcode
