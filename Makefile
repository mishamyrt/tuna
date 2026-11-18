SHELL := /bin/bash

SDK := build/AudioUnitSDK
SDK_REVISION := bd98b31feff57a15989fcfab4cd86dc63382b1ac
COMPONENT := build/Tuna.component
COMPONENTS_DIR ?= $(HOME)/Library/Audio/Plug-Ins/Components

BUILD_ARCH := $(shell uname -m)
ifeq ($(BUILD_ARCH),arm64)
RUST_ARCH := aarch64
else ifeq ($(BUILD_ARCH),x86_64)
RUST_ARCH := x86_64
else
$(error Unsupported Mac architecture: $(BUILD_ARCH))
endif
RUST_TARGET := $(RUST_ARCH)-apple-darwin
export MACOSX_DEPLOYMENT_TARGET := 14.0

.PHONY: all dsp build install test test-au lint
all: build

dsp:
	cargo build --release --locked --target "$(RUST_TARGET)"

build: dsp
	@mkdir -p build
	@if [[ ! -d "$(SDK)/.git" ]]; then \
		git -c advice.detachedHead=false clone --quiet --depth 1 --branch AudioUnitSDK-1.4.0 \
			https://github.com/apple/AudioUnitSDK.git "$(SDK)"; \
	fi
	@test "$$(git -C "$(SDK)" rev-parse HEAD)" = "$(SDK_REVISION)" || \
		{ echo "Unexpected AudioUnitSDK revision in $(SDK)" >&2; exit 1; }
	xcrun swiftc -swift-version 5 -target "$(BUILD_ARCH)-apple-macosx$(MACOSX_DEPLOYMENT_TARGET)" -O \
		-module-name TunaUI -parse-as-library -import-objc-header mac/EditorBridge.h \
		-emit-object mac/Editor.swift -o build/Editor.o
	mkdir -p "$(COMPONENT)/Contents/MacOS" "$(COMPONENT)/Contents/Resources"
	cp mac/Info.plist "$(COMPONENT)/Contents/Info.plist"
	cp "$(SDK)/LICENSE.txt" "$(COMPONENT)/Contents/Resources/AudioUnitSDK-LICENSE.txt"
	@set -e; \
	swift_compiler="$$(xcrun --find swiftc)"; \
	swift_libraries="$$(dirname "$$swift_compiler")/../lib/swift/macosx"; \
	xcrun clang++ -bundle -std=c++23 -O3 -DNDEBUG -fobjc-arc -fvisibility=hidden -arch "$(BUILD_ARCH)" \
		-I "$(SDK)/include" mac/Calibration.mm "$(SDK)"/src/AudioUnitSDK/*.cpp build/Editor.o \
		"target/$(RUST_TARGET)/release/libtuna.a" \
		-framework AudioToolbox -framework CoreAudio -framework CoreMIDI -framework CoreFoundation \
		-framework AppKit -framework SwiftUI -framework Accelerate -framework UniformTypeIdentifiers \
		-L "$$swift_libraries" -Wl,-rpath,/usr/lib/swift -lswiftCore \
		-o "$(COMPONENT)/Contents/MacOS/Tuna"
	codesign --force --sign - "$(COMPONENT)"

install: build
	@set -eu; \
	destination="$(COMPONENTS_DIR)"; \
	mkdir -p "$$destination"; \
	stage="$$(mktemp -d "$$destination/.tuna-install.XXXXXX")"; \
	trap 'rm -rf "$$stage"' EXIT; \
	ditto "$(COMPONENT)" "$$stage/Tuna.component"; \
	codesign --verify --strict "$$stage/Tuna.component"; \
	for name in "Tuna.component" "Audio Calibration.component"; do \
		existing="$$destination/$$name"; \
		if [[ -e "$$existing" || -L "$$existing" ]]; then \
			identifier="$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$$existing/Contents/Info.plist")"; \
			if [[ "$$identifier" != "com.myrt.audio-calibration" ]]; then \
				printf 'Another component already exists at %s\n' "$$existing" >&2; exit 1; \
			fi; \
		fi; \
	done; \
	rm -rf "$$destination/Tuna.component"; \
	mv "$$stage/Tuna.component" "$$destination/Tuna.component"; \
	rm -rf "$$destination/Audio Calibration.component"; \
	printf 'Installed: %s\n' "$$destination/Tuna.component"

test:
	cargo test --locked

lint:
	cargo fmt --all -- --check
	cargo clippy --locked --all-targets -- -D warnings

test-au: dsp
	@test -f "$(PROFILE)" || { echo 'Usage: make test-au PROFILE=/path/to/asymmetric-stereo.tmreq' >&2; exit 1; }
	mkdir -p build
	xcrun clang++ -std=c++23 -O3 -arch "$(BUILD_ARCH)" tests/verify.cpp \
		"target/$(RUST_TARGET)/release/libtuna.a" \
		-framework AudioToolbox -framework CoreFoundation -framework Accelerate -o build/verify
	build/verify "$(PROFILE)"
