SHELL := /bin/bash
VERSION := 0.1.1

SDK := build/AudioUnitSDK
SDK_REVISION := bd98b31feff57a15989fcfab4cd86dc63382b1ac
COMPONENT := build/Tuna.component
COMPONENTS_DIR ?= $(HOME)/Library/Audio/Plug-Ins/Components
COMPONENT_NAMES := "Tuna.component" "Audio Calibration.component"

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

.PHONY: all dsp build install uninstall test test-au lint publish
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

define check-installed-components
for name in $(COMPONENT_NAMES); do \
	component="$$destination/$$name"; \
	if [[ -e "$$component" || -L "$$component" ]]; then \
		identifier="$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$$component/Contents/Info.plist")"; \
		if [[ "$$identifier" != "co.myrt.audio-calibration" && "$$identifier" != "com.myrt.audio-calibration" ]]; then \
			printf 'Another component already exists at %s\n' "$$component" >&2; exit 1; \
		fi; \
	fi; \
done
endef

install: build
	@set -eu; \
	destination="$(COMPONENTS_DIR)"; \
	mkdir -p "$$destination"; \
	stage="$$(mktemp -d "$$destination/.tuna-install.XXXXXX")"; \
	trap 'rm -rf "$$stage"' EXIT; \
	ditto "$(COMPONENT)" "$$stage/Tuna.component"; \
	codesign --verify --strict "$$stage/Tuna.component"; \
	$(check-installed-components); \
	rm -rf "$$destination/Tuna.component"; \
	mv "$$stage/Tuna.component" "$$destination/Tuna.component"; \
	rm -rf "$$destination/Audio Calibration.component"; \
	printf 'Installed: %s\n' "$$destination/Tuna.component"

uninstall:
	@set -eu; \
	destination="$(COMPONENTS_DIR)"; \
	$(check-installed-components); \
	for name in $(COMPONENT_NAMES); do \
		component="$$destination/$$name"; \
		if [[ -e "$$component" || -L "$$component" ]]; then \
			rm -rf -- "$$component"; \
			printf 'Uninstalled: %s\n' "$$component"; \
		fi; \
	done

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

publish:
	@sed -E 's/^version = "[^"]+"/version = "${VERSION}"/' Cargo.toml > Cargo.toml.tmp
	@mv Cargo.toml.tmp Cargo.toml
	@cargo update -p tuna
	@git add Makefile Cargo.toml Cargo.lock
	@git commit -m "chore: release ${VERSION} 🔥"
	@git tag "v${VERSION}"
	@git-cliff -o CHANGELOG.md
	@git tag -d "v${VERSION}"
	@git add CHANGELOG.md
	@git commit --amend --no-edit
	@git tag -a "v${VERSION}" -m "release v${VERSION}"
	@git push
	@git push --tags
