SHELL := /bin/bash
VERSION := 0.1.2
CORE := Sources/TunaCore
CORE_MANIFEST := $(CORE)/Cargo.toml
EDITOR := Sources/Tuna/Editor

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
	cargo build --manifest-path "$(CORE_MANIFEST)" --release --locked --target "$(RUST_TARGET)"

build: dsp
	@mkdir -p build
	@if [[ ! -d "$(SDK)/.git" ]]; then \
		git -c advice.detachedHead=false clone --quiet --depth 1 --branch AudioUnitSDK-1.4.0 \
			https://github.com/apple/AudioUnitSDK.git "$(SDK)"; \
	fi
	@test "$$(git -C "$(SDK)" rev-parse HEAD)" = "$(SDK_REVISION)" || \
		{ echo "Unexpected AudioUnitSDK revision in $(SDK)" >&2; exit 1; }
	xcrun swiftc -swift-version 5 -target "$(BUILD_ARCH)-apple-macosx$(MACOSX_DEPLOYMENT_TARGET)" -O \
		-module-name TunaUI -parse-as-library -import-objc-header $(EDITOR)/EditorBridge.h \
		-I Sources/Tuna -I $(CORE)/include -whole-module-optimization -emit-object $(EDITOR)/*.swift -o build/Editor.o
	mkdir -p "$(COMPONENT)/Contents/MacOS" "$(COMPONENT)/Contents/Resources"
	@set -eu; \
	version="$(VERSION)"; \
	[[ "$$version" =~ ^(0|[1-9][0-9]{0,4})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$$ ]] && \
		(( BASH_REMATCH[1] <= 65535 && BASH_REMATCH[2] <= 255 && BASH_REMATCH[3] <= 255 )) || \
		{ echo "Unsupported Audio Unit version: $$version" >&2; exit 1; }; \
	packed=$$(( (BASH_REMATCH[1] << 16) | (BASH_REMATCH[2] << 8) | BASH_REMATCH[3] )); \
	cp Assets/Info.plist "$(COMPONENT)/Contents/Info.plist"; \
	/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $$version" \
		-c "Add :CFBundleVersion string $$packed" -c "Add :AudioComponents:0:version integer $$packed" \
		"$(COMPONENT)/Contents/Info.plist"
	cp "$(SDK)/LICENSE.txt" "$(COMPONENT)/Contents/Resources/AudioUnitSDK-LICENSE.txt"
	@set -e; \
	swift_compiler="$$(xcrun --find swiftc)"; \
	swift_libraries="$$(dirname "$$swift_compiler")/../lib/swift/macosx"; \
	xcrun clang++ -bundle -std=c++23 -O3 -DNDEBUG -fobjc-arc -fvisibility=hidden -arch "$(BUILD_ARCH)" \
		-I "$(SDK)/include" -I $(CORE)/include Sources/Tuna/Calibration.mm "$(SDK)"/src/AudioUnitSDK/*.cpp build/Editor.o \
		"$(CORE)/target/$(RUST_TARGET)/release/libtuna.a" \
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
	if [[ -e "$$destination/Tuna.component" || -L "$$destination/Tuna.component" ]]; then \
		xcrun swift -e 'import Darwin; if renamex_np(CommandLine.arguments[1], CommandLine.arguments[2], UInt32(RENAME_SWAP)) != 0 { perror("swap Tuna.component"); exit(1) }' \
			"$$stage/Tuna.component" "$$destination/Tuna.component"; \
	else \
		mv "$$stage/Tuna.component" "$$destination/Tuna.component"; \
	fi; \
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
	cargo test --manifest-path "$(CORE_MANIFEST)" --locked

lint:
	cargo fmt --manifest-path "$(CORE_MANIFEST)" --all -- --check
	cargo clippy --manifest-path "$(CORE_MANIFEST)" --locked --all-targets -- -D warnings

PROFILE ?= Tests/Tuna/Fixtures/asymmetric.tmreq
test-au: build
	@test -f "$(PROFILE)" || { echo 'Usage: make test-au PROFILE=/path/to/asymmetric-stereo.tmreq' >&2; exit 1; }
	mkdir -p build
	xcrun clang++ -std=c++23 -O3 -arch "$(BUILD_ARCH)" -I Sources/Tuna -I $(CORE)/include Tests/Tuna/verify.cpp \
		"$(CORE)/target/$(RUST_TARGET)/release/libtuna.a" \
		-framework AudioToolbox -framework CoreFoundation -framework Accelerate -o build/verify
	build/verify "$(PROFILE)" "$(COMPONENT)/Contents/MacOS/Tuna"

publish:
	@sed -E 's/^version = "[^"]+"/version = "${VERSION}"/' $(CORE_MANIFEST) > $(CORE_MANIFEST).tmp
	@mv $(CORE_MANIFEST).tmp $(CORE_MANIFEST)
	@cargo update --manifest-path "$(CORE_MANIFEST)" -p tuna
ifeq ($(origin VERSION),command line)
	@sed -E 's/^VERSION := .*/VERSION := $(VERSION)/' Makefile > Makefile.tmp
	@mv Makefile.tmp Makefile
endif
	@git add Makefile $(CORE_MANIFEST) $(CORE)/Cargo.lock
	@git commit -m "chore: release ${VERSION} 🔥"
	@git tag "v${VERSION}"
	@git-cliff -o CHANGELOG.md
	@git tag -d "v${VERSION}"
	@git add CHANGELOG.md
	@git commit --amend --no-edit
	@git tag -a "v${VERSION}" -m "release v${VERSION}"
	@git push
	@git push --tags
