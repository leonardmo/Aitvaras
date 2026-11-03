# Canonical entry points for humans, agents and CI (see AGENTS.md).
SHELL := /bin/bash
.DEFAULT_GOAL := help

XCODE_FLAGS := -project Aitvaras.xcodeproj -scheme Aitvaras \
	-skipMacroValidation -skipPackagePluginValidation
NODE_TESTS := scripts/test-claude-interactive.mjs scripts/check-codex-interactive.mjs \
	scripts/check-codex-native.mjs scripts/check-codex-shared-runtime.mjs

.PHONY: help setup test node-test project app release privacy commits check smoke install clean

help: ## List targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-10s %s\n", $$1, $$2}'

setup: ## Enable the repo git hooks (once per clone)
	git config core.hooksPath .githooks
	@echo "Hooks enabled. Commit author: $$(git config user.email)"

test: ## Package tests (swift test)
	swift test

node-test: ## Offline contract tests for the Node sidecar helpers
	@set -e; for t in $(NODE_TESTS); do echo "── $$t"; node $$t; done

project: ## Generate Aitvaras.xcodeproj from project.yml
	xcodegen generate --quiet

app: project ## Debug app build into .build-xcode
	set -o pipefail; xcodebuild $(XCODE_FLAGS) -configuration Debug \
		-derivedDataPath .build-xcode build | tail -5

release: project ## Release app build into .build/DerivedData
	set -o pipefail; xcodebuild $(XCODE_FLAGS) -configuration Release \
		-derivedDataPath .build/DerivedData build | tail -5

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
