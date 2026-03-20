SCHEME       := PricingStudio
WORKSPACE    := PricingStudio.xcodeproj
ARCHIVE_PATH := build/PricingStudio.xcarchive
EXPORT_DIR   := build/export
EXPORT_OPTS  := ExportOptions.plist
DESTINATION  := generic/platform=iOS
SIM_ID       := 49BB7923-1618-4808-8A94-B056855778EA
SIM_DEST     := platform=iOS Simulator,id=$(SIM_ID)
DEVICE_ID    := DA64BB63-AA0D-578F-A394-033A5E719864
DEV_BUILD    := build/Build/Products/Debug-iphoneos/PricingStudio.app
FAST_FLAGS   := ONLY_ACTIVE_ARCH=YES SWIFT_OPTIMIZATION_LEVEL='-Onone' DEBUG_INFORMATION_FORMAT=dwarf GCC_OPTIMIZATION_LEVEL=0

.PHONY: archive export ipa install clean dev dev-install dev-wifi help test-ui test-bdd test-bdd-sim test-ui-sim stamp

TIMESTAMP_FILE := PricingStudio/BuildTimestamp.txt

# ============================================================
# BUILD STAMPING (auto-increment build number + timestamp)
# ============================================================

## stamp: Bump CURRENT_PROJECT_VERSION and write build timestamp
stamp:
	@NEW=$$(( $$(grep -m1 'CURRENT_PROJECT_VERSION' $(WORKSPACE)/project.pbxproj | sed 's/[^0-9]//g') + 1 )); \
	sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9]*/CURRENT_PROJECT_VERSION = $$NEW/g" $(WORKSPACE)/project.pbxproj; \
	echo "Build $$NEW — $$(date '+%Y-%m-%d %H:%M:%S %Z')" > $(TIMESTAMP_FILE); \
	echo "Stamped build $$NEW"

# ============================================================
# FAST DEVELOPMENT BUILDS (debug, incremental, ~30s after first)
# ============================================================

## dev: Debug build for device (incremental, no archive overhead)
dev: stamp
	xcodebuild build \
		-project $(WORKSPACE) \
		-scheme $(SCHEME) \
		-destination '$(DESTINATION)' \
		-configuration Debug \
		-derivedDataPath build \
		-allowProvisioningUpdates \
		CODE_SIGN_STYLE=Automatic \
		$(FAST_FLAGS)

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
# UI & BDD TESTS (real backend, real credentials)
# ============================================================

## test-ui: Run XCUITests against a connected device
test-ui: dev
	xcodebuild test \
		-project $(WORKSPACE) \
		-scheme $(SCHEME) \
		-destination '$(DESTINATION)' \
		-only-testing:PricingStudioUITests \
		-derivedDataPath build \
		-allowProvisioningUpdates \
		CODE_SIGN_STYLE=Automatic \
		$(FAST_FLAGS)

## test-bdd: Run BDD feature tests against a connected device
test-bdd: dev
	xcodebuild test \
		-project $(WORKSPACE) \
		-scheme $(SCHEME) \
		-destination '$(DESTINATION)' \
		-only-testing:PricingStudioBDDTests \
		-derivedDataPath build \
		-allowProvisioningUpdates \
		CODE_SIGN_STYLE=Automatic \
		$(FAST_FLAGS)

## test-ui-sim: Run XCUITests on iPad simulator (fast debug build)
test-ui-sim:
	xcodebuild test \
		-project $(WORKSPACE) \
		-scheme $(SCHEME) \
		-destination '$(SIM_DEST)' \
		-configuration Debug \
		-only-testing:PricingStudioUITests \
		-derivedDataPath build \
		$(FAST_FLAGS)

## test-bdd-sim: Run BDD feature tests on iPad simulator (fast debug build)
test-bdd-sim:
	xcodebuild test \
		-project $(WORKSPACE) \
		-scheme $(SCHEME) \
		-destination '$(SIM_DEST)' \
		-configuration Debug \
		-only-testing:PricingStudioBDDTests \
		-derivedDataPath build \
		$(FAST_FLAGS)

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
	@echo "Testing:"
	@echo "  make test-ui      — Run XCUITests on device (real backend)"
	@echo "  make test-bdd     — Run BDD feature tests on device"
	@echo "  make test-ui-sim  — Run XCUITests on iPad simulator (fast)"
	@echo "  make test-bdd-sim — Run BDD feature tests on simulator (fast)"
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
