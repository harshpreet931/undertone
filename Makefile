# Assembles the signed .app bundle that TCC permissions require
# (ARCHITECTURE.md §7-8). Run on macOS with Xcode command-line tools.

APP_NAME    := Undertone
BUNDLE_ID   := app.undertone
BUILD_DIR   := .build/release
APP_DIR     := dist/$(APP_NAME).app

.PHONY: build app run clean

build:
	swift build -c release

app: build
	rm -rf $(APP_DIR)
	mkdir -p $(APP_DIR)/Contents/MacOS $(APP_DIR)/Contents/Resources
	cp $(BUILD_DIR)/$(APP_NAME) $(APP_DIR)/Contents/MacOS/$(APP_NAME)
	cp Resources/Info.plist $(APP_DIR)/Contents/Info.plist
	cp Resources/AppIcon.icns $(APP_DIR)/Contents/Resources/AppIcon.icns
	# Bundle SwiftPM resource bundles (KeyboardShortcuts localizations, etc.)
	-cp -R $(BUILD_DIR)/*.bundle $(APP_DIR)/Contents/Resources/ 2>/dev/null || true
	# Ad-hoc signature: stable bundle ID + signature is what TCC keys grants on.
	codesign --force --deep --sign - $(APP_DIR)
	@echo "Built $(APP_DIR)"

run: app
	open $(APP_DIR)

clean:
	rm -rf .build dist
