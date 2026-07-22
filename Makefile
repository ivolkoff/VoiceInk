# Define a directory for dependencies in the user's home folder
DEPS_DIR := $(HOME)/VoiceInk-Dependencies
WHISPER_CPP_DIR := $(DEPS_DIR)/whisper.cpp
FRAMEWORK_PATH := $(WHISPER_CPP_DIR)/build-apple/whisper.xcframework
LOCAL_DERIVED_DATA := $(CURDIR)/.local-build

# Signing identity for `make local`. Default `-` = ad-hoc (new identity each
# build, so Accessibility/TCC resets every rebuild). Override with a stable
# self-signed code-signing identity to keep permissions across rebuilds, e.g.
#   make local LOCAL_SIGN_IDENTITY="VoiceInk Local"
# or use the `local-signed` target below.
LOCAL_SIGN_IDENTITY ?= -
# Identity used by the `local-signed` convenience target.
SIGN_IDENTITY ?= VoiceInk Local
# Install destination for `local-signed`. Defaults to /Applications because
# ~/Downloads is often under a backup/sync tool (e.g. Backblaze) that injects
# placeholder files which break the code signature seal.
LOCAL_INSTALL_DIR ?= /Applications

.PHONY: all clean whisper setup build local local-signed check healthcheck help dev run run-direct reopen

# Default target
all: check build

# Development workflow
dev: build run

# Prerequisites
check:
	@echo "Checking prerequisites..."
	@command -v git >/dev/null 2>&1 || { echo "git is not installed"; exit 1; }
	@command -v xcodebuild >/dev/null 2>&1 || { echo "xcodebuild is not installed (need Xcode)"; exit 1; }
	@command -v swift >/dev/null 2>&1 || { echo "swift is not installed"; exit 1; }
	@echo "Prerequisites OK"

healthcheck: check

# Build process
whisper:
	@mkdir -p $(DEPS_DIR)
	@if [ ! -d "$(FRAMEWORK_PATH)" ]; then \
		echo "Building whisper.xcframework in $(DEPS_DIR)..."; \
		if [ ! -d "$(WHISPER_CPP_DIR)" ]; then \
			git clone https://github.com/ggerganov/whisper.cpp.git $(WHISPER_CPP_DIR); \
		else \
			(cd $(WHISPER_CPP_DIR) && git pull); \
		fi; \
		cd $(WHISPER_CPP_DIR) && ./build-xcframework.sh; \
	else \
		echo "whisper.xcframework already built in $(DEPS_DIR), skipping build"; \
	fi

setup: whisper
	@echo "Whisper framework is ready at $(FRAMEWORK_PATH)"
	@echo "Please ensure your Xcode project references the framework from this new location."

build: setup
	xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug CODE_SIGN_IDENTITY="" build

# Build for local use without Apple Developer certificate
local: check setup
	@echo "Building VoiceInk for local use (no Apple Developer certificate required)..."
	@rm -rf "$(LOCAL_DERIVED_DATA)"
	xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug \
		-derivedDataPath "$(LOCAL_DERIVED_DATA)" \
		-xcconfig LocalBuild.xcconfig \
		CODE_SIGN_IDENTITY="$(LOCAL_SIGN_IDENTITY)" \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGNING_ALLOWED=YES \
		DEVELOPMENT_TEAM="" \
		CODE_SIGN_ENTITLEMENTS="$(CURDIR)/VoiceInk/VoiceInk.local.entitlements" \
		SWIFT_ACTIVE_COMPILATION_CONDITIONS='$$(inherited) LOCAL_BUILD' \
		build
	@APP_PATH="$(LOCAL_DERIVED_DATA)/Build/Products/Debug/VoiceInk.app" && \
	if [ -d "$$APP_PATH" ]; then \
		echo "Installing VoiceInk.app to $(LOCAL_INSTALL_DIR)..."; \
		rm -rf "$(LOCAL_INSTALL_DIR)/VoiceInk.app"; \
		ditto "$$APP_PATH" "$(LOCAL_INSTALL_DIR)/VoiceInk.app"; \
		xattr -cr "$(LOCAL_INSTALL_DIR)/VoiceInk.app"; \
		echo ""; \
		echo "Build complete! App saved to: $(LOCAL_INSTALL_DIR)/VoiceInk.app"; \
		echo "Run with: open $(LOCAL_INSTALL_DIR)/VoiceInk.app"; \
		echo ""; \
		echo "Limitations of local builds:"; \
		echo "  - No iCloud dictionary sync"; \
		echo "  - No automatic updates (pull new code and rebuild to update)"; \
	else \
		echo "Error: Could not find built VoiceInk.app at $$APP_PATH"; \
		exit 1; \
	fi

# Build for local use signed with a stable self-signed identity.
# Keeps Accessibility/Input Monitoring (TCC) granted across rebuilds because the
# code's Designated Requirement stays pinned to the same certificate.
# One-time setup: create a "Code Signing" self-signed cert named "$(SIGN_IDENTITY)"
# in Keychain Access (Certificate Assistant), or via the documented CLI.
local-signed:
	@if ! security find-identity -p codesigning | grep -q "$(SIGN_IDENTITY)"; then \
		echo "Code-signing identity '$(SIGN_IDENTITY)' not found in keychain."; \
		echo "Create it once (Keychain Access > Certificate Assistant > Create a Certificate,"; \
		echo "type 'Code Signing', self-signed) then re-run 'make local-signed'."; \
		exit 1; \
	fi
	@$(MAKE) local
	@echo ""
	@echo "Re-signing with stable identity '$(SIGN_IDENTITY)' (xcodebuild falls back to ad-hoc)..."
	@# Sign the build-products copy, NOT the ~/Downloads copy: ~/Downloads is a
	@# TCC-protected location and ditto stamps com.apple.provenance on the copy,
	@# both of which make `codesign --force` fail there ("Operation not permitted").
	@# Signature survives the subsequent ditto, so we copy the signed app over.
	@scripts/resign-local.sh \
		"$(LOCAL_DERIVED_DATA)/Build/Products/Debug/VoiceInk.app" \
		"$(CURDIR)/VoiceInk/VoiceInk.local.entitlements" "$(SIGN_IDENTITY)"
	@# The build-products copy is the source of truth: it is signed and lives
	@# outside any backup/sync path. Its verification gates success.
	@codesign --verify --deep --strict \
		"$(LOCAL_DERIVED_DATA)/Build/Products/Debug/VoiceInk.app"
	@echo "Build-products app signed OK (Authority: $(SIGN_IDENTITY))."
	@# Install to $(LOCAL_INSTALL_DIR) — NOT ~/Downloads. Backup/sync tools like
	@# Backblaze continuously inject .BC.D_* placeholder symlinks into bundles
	@# under ~/Downloads, which break the embedded-framework code seal
	@# ("unsealed contents...") and can stop the app from launching. Override the
	@# destination with `make local-signed LOCAL_INSTALL_DIR=/some/other/dir`.
	@echo "Installing signed app to $(LOCAL_INSTALL_DIR)..."
	@rm -rf "$(LOCAL_INSTALL_DIR)/VoiceInk.app"
	@ditto "$(LOCAL_DERIVED_DATA)/Build/Products/Debug/VoiceInk.app" "$(LOCAL_INSTALL_DIR)/VoiceInk.app"
	@if codesign --verify --deep --strict "$(LOCAL_INSTALL_DIR)/VoiceInk.app" 2>/dev/null; then \
		echo "$(LOCAL_INSTALL_DIR)/VoiceInk.app signed OK (Authority: $(SIGN_IDENTITY))."; \
	else \
		echo "NOTE: installed copy failed strict verify. If $(LOCAL_INSTALL_DIR)"; \
		echo "      is under a backup/sync tool, point LOCAL_INSTALL_DIR elsewhere."; \
	fi
	@echo ""
	@echo "Launch: open $(LOCAL_INSTALL_DIR)/VoiceInk.app"
	@echo "Grant Accessibility once; it then persists across rebuilds (DR pinned to the cert)."

# Run application
run:
	@if [ -d "$(LOCAL_INSTALL_DIR)/VoiceInk.app" ]; then \
		echo "Opening $(LOCAL_INSTALL_DIR)/VoiceInk.app..."; \
		open "$(LOCAL_INSTALL_DIR)/VoiceInk.app"; \
	else \
		echo "Looking for VoiceInk.app in DerivedData..."; \
		APP_PATH=$$(find "$$HOME/Library/Developer/Xcode/DerivedData" -name "VoiceInk.app" -type d | head -1) && \
		if [ -n "$$APP_PATH" ]; then \
			echo "Found app at: $$APP_PATH"; \
			open "$$APP_PATH"; \
		else \
			echo "VoiceInk.app not found. Please run 'make build' or 'make local' first."; \
			exit 1; \
		fi; \
	fi

# Run a local/self-signed build by executing the Mach-O directly.
#
# Diagnostic fallback. Debug/LOCAL_BUILD registers supported global shortcuts through
# Carbon, so normal `open` / Finder launches should work. Modifier-only shortcuts
# still keep a CGEventTap fallback, so this target remains useful when diagnosing
# TCC/Input Monitoring behavior.
run-direct:
	@APP="$(LOCAL_INSTALL_DIR)/VoiceInk.app"; \
	BIN="$$APP/Contents/MacOS/VoiceInk"; \
	if [ ! -x "$$BIN" ]; then \
		echo "Not found: $$BIN"; \
		echo "Build first: make local-signed"; \
		exit 1; \
	fi; \
	echo "Quitting any running VoiceInk..."; \
	killall VoiceInk 2>/dev/null || true; \
	sleep 1; \
	echo "Launching directly (bypassing Launch Services): $$BIN"; \
	nohup "$$BIN" >> "$$HOME/Library/Logs/VoiceInk-direct.log" 2>&1 & \
	echo "Launched. Logs: ~/Library/Logs/VoiceInk-direct.log"

# Quit running app and reopen the installed copy
reopen:
	@killall VoiceInk 2>/dev/null || true
	@open "$(LOCAL_INSTALL_DIR)/VoiceInk.app"

# Cleanup
clean:
	@echo "Cleaning build artifacts..."
	@rm -rf $(DEPS_DIR)
	@echo "Clean complete"

# Help
help:
	@echo "Available targets:"
	@echo "  check/healthcheck  Check if required CLI tools are installed"
	@echo "  whisper            Clone and build whisper.cpp XCFramework"
	@echo "  setup              Copy whisper XCFramework to VoiceInk project"
	@echo "  build              Build the VoiceInk Xcode project"
	@echo "  local              Build for local use (no Apple Developer certificate needed)"
	@echo "  run                Launch the built VoiceInk app"
	@echo "  reopen             Quit running app and reopen the installed copy"
	@echo "  dev                Build and run the app (for development)"
	@echo "  all                Run full build process (default)"
	@echo "  clean              Remove build artifacts"
	@echo "  help               Show this help message"
