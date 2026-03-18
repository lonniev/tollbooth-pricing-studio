SCHEME       := PricingStudio
WORKSPACE    := PricingStudio.xcodeproj
ARCHIVE_PATH := build/PricingStudio.xcarchive
EXPORT_DIR   := build/export
EXPORT_OPTS  := ExportOptions.plist
DESTINATION  := generic/platform=iOS
DEVICE_ID    := DA64BB63-AA0D-578F-A394-033A5E719864
DEV_BUILD    := build/Build/Products/Debug-iphoneos/PricingStudio.app

.PHONY: archive export ipa install clean dev dev-install dev-wifi help

# ============================================================
# FAST DEVELOPMENT BUILDS (debug, incremental, ~30s after first)
# ============================================================

## dev: Debug build for device (incremental, no archive overhead)
dev:
	xcodebuild build \
		-project $(WORKSPACE) \
		-scheme $(SCHEME) \
		-destination '$(DESTINATION)' \
		-configuration Debug \
		-derivedDataPath build \
		-allowProvisioningUpdates \
		CODE_SIGN_STYLE=Automatic

## dev-install: Dev build + install to connected device
dev-install: dev
	@if command -v devicectl >/dev/null 2>&1; then \
		echo "Installing dev build via devicectl..."; \
		xcrun devicectl device install app --device $(DEVICE_ID) $(DEV_BUILD); \
	elif command -v ios-deploy >/dev/null 2>&1; then \
		echo "Installing dev build via ios-deploy..."; \
		ios-deploy --bundle $(DEV_BUILD); \
	else \
		echo "No install tool found. App is at: $(DEV_BUILD)"; \
	fi

## dev-wifi: Dev build + WiFi install (fast iteration)
dev-wifi: dev
	@echo "Installing dev build over WiFi..."
	xcrun devicectl device install app --device $(DEVICE_ID) $(DEV_BUILD)

# ============================================================
# PRODUCTION BUILDS (release archive, optimized, signed IPA)
# ============================================================

## archive: Build a release .xcarchive
archive:
	xcodebuild archive \
		-project $(WORKSPACE) \
		-scheme $(SCHEME) \
		-destination '$(DESTINATION)' \
		-archivePath $(ARCHIVE_PATH) \
		-allowProvisioningUpdates \
		CODE_SIGN_STYLE=Automatic

## export: Export the archive to a signed IPA
export: archive
	xcodebuild -exportArchive \
		-archivePath $(ARCHIVE_PATH) \
		-exportOptionsPlist $(EXPORT_OPTS) \
		-exportPath $(EXPORT_DIR) \
		-allowProvisioningUpdates

## ipa: Alias for export
ipa: export

## install: Install to a connected device via ios-deploy or devicectl
install: export
	@if command -v devicectl >/dev/null 2>&1; then \
		echo "Installing via devicectl..."; \
		xcrun devicectl device install app --device $(DEVICE_ID) $(EXPORT_DIR)/$(SCHEME).ipa; \
	elif command -v ios-deploy >/dev/null 2>&1; then \
		echo "Installing via ios-deploy..."; \
		ios-deploy --bundle $(EXPORT_DIR)/$(SCHEME).ipa; \
	else \
		echo "No install tool found. Install via:"; \
		echo "  1. Apple Configurator 2 (drag IPA to device)"; \
		echo "  2. brew install ios-deploy"; \
		echo "  3. Xcode > Devices and Simulators > Install App"; \
		echo "IPA is at: $(EXPORT_DIR)/$(SCHEME).ipa"; \
	fi

## wifi-install: Production build + WiFi install (full release)
wifi-install: export
	@echo "Ensure iPad is WiFi-paired: Xcode > Window > Devices > Connect via network"
	xcrun devicectl device install app --device $(DEVICE_ID) $(EXPORT_DIR)/$(SCHEME).ipa

# ============================================================
# UTILITIES
# ============================================================

## clean: Remove build artifacts
clean:
	rm -rf build/
	xcodebuild clean -project $(WORKSPACE) -scheme $(SCHEME)

## help: Show available targets
help:
	@echo "Development (fast, incremental):"
	@echo "  make dev          — Debug build for device"
	@echo "  make dev-install  — Dev build + install (USB)"
	@echo "  make dev-wifi     — Dev build + install (WiFi)"
	@echo ""
	@echo "Production (optimized, signed IPA):"
	@echo "  make archive      — Release .xcarchive"
	@echo "  make export       — Archive + signed IPA"
	@echo "  make install      — Full release + install (USB)"
	@echo "  make wifi-install — Full release + install (WiFi)"
	@echo ""
	@echo "Utilities:"
	@echo "  make clean        — Remove build artifacts"
	@echo "  make help         — This message"
