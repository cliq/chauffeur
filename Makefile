SHELL := /bin/bash
.DEFAULT_GOAL := build

CONFIGURATION ?= Debug
BUILD_ACTION ?= build
DERIVED_DATA_PATH ?= build
XCODEBUILD_ARGS ?=
CODESIGN_FLAGS ?=
INSTALL_DIR ?= /Applications
NODE ?= node

PRODUCTS_DIR = $(DERIVED_DATA_PATH)/Build/Products/$(CONFIGURATION)
APP_NAME = $(if $(filter Debug,$(CONFIGURATION)),Chauffeur Debug,Chauffeur)
APP = $(PRODUCTS_DIR)/$(APP_NAME).app
RELEASE_APP = $(DERIVED_DATA_PATH)/Build/Products/Release/Chauffeur.app
INSTALLED_APP = $(INSTALL_DIR)/Chauffeur.app
XCODEBUILD = xcodebuild -project Chauffeur.xcodeproj -scheme Chauffeur \
	-configuration "$(CONFIGURATION)" -derivedDataPath "$(DERIVED_DATA_PATH)" \
	-destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation \
	$(XCODEBUILD_ARGS)

.PHONY: gen build debug release install open test test-plugin test-ui verify clean

gen:
	xcodegen generate

build: gen
	$(XCODEBUILD) $(BUILD_ACTION)
	# Xcode can skip CodeSign when only an embedded Swift-package helper changes.
	# Reseal the completed bundle using the identity resolved by Xcode.
	@set -euo pipefail; \
	  task_identity="$$(cat "$(PRODUCTS_DIR)/Chauffeur.signing-identity")"; \
	  /usr/bin/codesign --force $(CODESIGN_FLAGS) --sign "$$task_identity" \
	    --preserve-metadata=identifier,entitlements,flags,runtime "$(APP)"
	$(MAKE) verify CONFIGURATION="$(CONFIGURATION)"
	@printf '\nApp: %s\n' "$(abspath $(PRODUCTS_DIR))/$(APP_NAME).app"

debug:
	$(MAKE) build CONFIGURATION=Debug

release:
	$(MAKE) build CONFIGURATION=Release

# Build a signed Release with the identity from Configuration/LocalSigning.xcconfig,
# quit any copy running from $(INSTALL_DIR), replace it, and relaunch. The app
# refreshes its background runtime registration on launch when the embedded
# helper changed. Verify the running helper before reporting installation complete.
install: release
	@set -euo pipefail; \
	  running="$$(pgrep -f '^$(INSTALLED_APP)/Contents/MacOS/Chauffeur$$' || true)"; \
	  if [ -n "$$running" ]; then \
	    echo "Quitting $(INSTALLED_APP)…"; \
	    osascript -e 'tell application id "dev.cliq.chauffeur" to quit' >/dev/null 2>&1 || true; \
	    for _ in $$(seq 1 50); do \
	      pgrep -f '^$(INSTALLED_APP)/Contents/MacOS/Chauffeur$$' >/dev/null || break; sleep 0.2; \
	    done; \
	    pkill -f '^$(INSTALLED_APP)/Contents/MacOS/Chauffeur$$' 2>/dev/null || true; \
	  fi; \
	  rm -rf "$(INSTALLED_APP)"; \
	  ditto "$(RELEASE_APP)" "$(INSTALLED_APP)"; \
	  /usr/bin/codesign --verify --deep --strict "$(INSTALLED_APP)"; \
	  env -u CHAUFFEUR_SOCKET -u CHAUFFEUR_SESSION_TOKEN -u CHAUFFEUR_SERVICE_PROBE_SOCKET open "$(INSTALLED_APP)"; \
	  python3 Scripts/verify-installed-runtime.py "$(INSTALLED_APP)"; \
	  printf '\nInstalled: %s\n' "$(INSTALLED_APP)"

open: gen
	open Chauffeur.xcodeproj

test: test-plugin
	swift test

# The bundled OpenCode plugin is plain JavaScript, tested with node's built-in runner.
test-plugin:
	$(NODE) --test Tests/OpenCodePlugin/*.test.mjs

test-ui:
	$(MAKE) build BUILD_ACTION=build-for-testing
	$(XCODEBUILD) test-without-building

verify:
	/usr/bin/codesign --verify --deep --strict "$(APP)"

clean: gen
	xcodebuild -project Chauffeur.xcodeproj -scheme Chauffeur \
	  -derivedDataPath "$(DERIVED_DATA_PATH)" clean
	swift package clean
