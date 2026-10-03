SHELL := /bin/bash
.DEFAULT_GOAL := help

DERIVED_DATA := $(CURDIR)/.build/DerivedData
BRANCH := $(shell git branch --show-current | tr / -)
TEST_ASSETS ?= $(HOME)/Developer/test-assets/$(if $(BRANCH),$(BRANCH),ure)
TEST_RESULT := $(TEST_ASSETS)/ure-$(shell date +%Y%m%d-%H%M%S).xcresult
XCODE_EXTRA_FLAGS ?=
LOCAL_XCODE_FLAGS := $(if $(wildcard Config/Local.xcconfig),-xcconfig "$(CURDIR)/Config/Local.xcconfig")
XCODE_FLAGS := -project Ure.xcodeproj -scheme Ure -destination 'platform=macOS,arch=arm64' -derivedDataPath "$(DERIVED_DATA)" $(LOCAL_XCODE_FLAGS) $(XCODE_EXTRA_FLAGS)

.PHONY: help build release run test test-ui test-all recovery format lint check

help:
	@printf '%s\n' 'make build     Unsigned Debug build' 'make release   Unsigned optimized Release build' 'make run       Build with local signing and open Ure' 'make test      Swift Testing unit tests' 'make test-ui   Native keyboard and window tests' 'make test-all  All tests' 'make format    Format Swift sources' 'make lint      Check formatting and unsafe Swift constructs' 'make check     Lint, build, and unit tests'
	@printf '%s\n' 'make recovery  Run isolated process interruption matrix without launching Ure'

build:
	xcodebuild $(XCODE_FLAGS) -configuration Debug CODE_SIGNING_ALLOWED=NO build

release:
	xcodebuild $(XCODE_FLAGS) -configuration Release CODE_SIGNING_ALLOWED=NO build

run:
	xcodebuild $(XCODE_FLAGS) -configuration Debug build
	open "$(DERIVED_DATA)/Build/Products/Debug/Ure.app"

test:
	@mkdir -p "$(TEST_ASSETS)"
	xcodebuild $(XCODE_FLAGS) -configuration Debug -only-testing:UreTests -resultBundlePath "$(TEST_RESULT)" test

test-ui:
	@mkdir -p "$(TEST_ASSETS)"
	xcodebuild $(XCODE_FLAGS) -configuration Debug -only-testing:UreUITests -resultBundlePath "$(TEST_RESULT)" test

test-all:
	@mkdir -p "$(TEST_ASSETS)"
	xcodebuild $(XCODE_FLAGS) -configuration Debug -resultBundlePath "$(TEST_RESULT)" test

recovery:
	xcodebuild -project Ure.xcodeproj -scheme UreRecoveryHarness -destination 'platform=macOS,arch=arm64' -derivedDataPath "$(DERIVED_DATA)" $(LOCAL_XCODE_FLAGS) $(XCODE_EXTRA_FLAGS) -configuration Debug CODE_SIGNING_ALLOWED=NO build
	python3 RecoveryHarness/run.py "$(DERIVED_DATA)/Build/Products/Debug/UreRecoveryHarness"

format:
	xcrun swift-format format --in-place --recursive Ure UreTests UreUITests RecoveryHarness

lint:
	xcrun swift-format lint --strict --recursive Ure UreTests UreUITests RecoveryHarness

check:
	$(MAKE) lint
	$(MAKE) build
	$(MAKE) test
