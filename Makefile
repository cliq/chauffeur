SHELL := /bin/bash
.DEFAULT_GOAL := build

CONFIGURATION ?= Debug
BUILD_ACTION ?= build
DERIVED_DATA_PATH ?= build
XCODEBUILD_ARGS ?=

PRODUCTS_DIR = $(DERIVED_DATA_PATH)/Build/Products/$(CONFIGURATION)
APP_NAME = $(if $(filter Debug,$(CONFIGURATION)),Chauffeur Debug,Chauffeur)
APP = $(PRODUCTS_DIR)/$(APP_NAME).app
XCODEBUILD = xcodebuild -project Chauffeur.xcodeproj -scheme Chauffeur \
	-configuration "$(CONFIGURATION)" -derivedDataPath "$(DERIVED_DATA_PATH)" \
	-destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation \
	$(XCODEBUILD_ARGS)

.PHONY: gen build debug release open test test-ui verify clean

gen:
	xcodegen generate

build: gen
	$(XCODEBUILD) $(BUILD_ACTION)
	# Xcode can skip CodeSign when only an embedded Swift-package helper changes.
	# Reseal the completed bundle using the identity resolved by Xcode.
	@set -euo pipefail; \
	  task_identity="$$(cat "$(PRODUCTS_DIR)/Chauffeur.signing-identity")"; \
	  /usr/bin/codesign --force --sign "$$task_identity" \
	    --preserve-metadata=identifier,entitlements,flags,runtime "$(APP)"
	$(MAKE) verify CONFIGURATION="$(CONFIGURATION)"
	@printf '\nApp: %s\n' "$(abspath $(PRODUCTS_DIR))/$(APP_NAME).app"

debug:
	$(MAKE) build CONFIGURATION=Debug

release:
	$(MAKE) build CONFIGURATION=Release

open: gen
	open Chauffeur.xcodeproj

test:
	swift test

test-ui:
	$(MAKE) build BUILD_ACTION=build-for-testing
	$(XCODEBUILD) test-without-building

verify:
	/usr/bin/codesign --verify --deep --strict "$(APP)"

clean: gen
	xcodebuild -project Chauffeur.xcodeproj -scheme Chauffeur \
	  -derivedDataPath "$(DERIVED_DATA_PATH)" clean
	swift package clean
