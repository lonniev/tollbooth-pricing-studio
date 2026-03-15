SCHEME       := PricingStudio
WORKSPACE    := PricingStudio.xcodeproj
ARCHIVE_PATH := build/PricingStudio.xcarchive
EXPORT_DIR   := build/export
EXPORT_OPTS  := ExportOptions.plist
DESTINATION  := generic/platform=iOS

.PHONY: archive export ipa install clean

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
		xcrun devicectl device install app --device "Lonnie's iPad" $(EXPORT_DIR)/$(SCHEME).ipa; \
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

## wifi-install: Install over WiFi using devicectl (iPad must be paired)
wifi-install: export
	@echo "Ensure iPad is WiFi-paired: Xcode > Window > Devices > Connect via network"
	xcrun devicectl device install app --device "Lonnie's iPad" $(EXPORT_DIR)/$(SCHEME).ipa

## clean: Remove build artifacts
clean:
	rm -rf build/
	xcodebuild clean -project $(WORKSPACE) -scheme $(SCHEME)

## help: Show available targets
help:
	@grep -E '^##' Makefile | sed 's/## //'
