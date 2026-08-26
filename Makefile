APP_NAME := Vaulty
VERSION  ?= 1.0.0
APP_DIR  := build/$(APP_NAME).app
BIN_DIR  := $(APP_DIR)/Contents/MacOS
RES_DIR  := $(APP_DIR)/Contents/Resources
SRC      := Sources/main.swift
INSTALL  := $(HOME)/Applications/$(APP_NAME).app
DIST     := dist
ZIP      := $(DIST)/$(APP_NAME)-$(VERSION)-macos.zip

# Code signing. Without a Developer ID we still ad-hoc sign ("-"), because an unsigned
# or merely linker-signed .app bundle has no sealed _CodeSignature, which is what makes
# macOS report a downloaded app as "damaged" rather than merely unverified.
# Export APPLE_SIGNING_IDENTITY to sign with a real Developer ID instead.
APPLE_SIGNING_IDENTITY ?= -
ifeq ($(APPLE_SIGNING_IDENTITY),-)
  # A secure timestamp needs a real certificate; ad-hoc signing must opt out of it.
  CODESIGN_TS := --timestamp=none
else
  CODESIGN_TS := --timestamp
endif

.PHONY: all clean install run package sign notarize

all: sign

$(APP_DIR)/Contents/MacOS/$(APP_NAME): $(SRC) Info.plist
	mkdir -p "$(BIN_DIR)" "$(RES_DIR)"
	swiftc -O -framework AppKit -framework Carbon -framework ApplicationServices \
		-o "$(BIN_DIR)/$(APP_NAME)" $(SRC)
	cp Info.plist "$(APP_DIR)/Contents/Info.plist"
	@echo "Built $(APP_DIR)"

# Seal the bundle. --options runtime (hardened runtime) is a hard requirement for
# notarization, and is harmless for ad-hoc builds.
sign: $(APP_DIR)/Contents/MacOS/$(APP_NAME)
	codesign --force --options runtime $(CODESIGN_TS) \
		--sign "$(APPLE_SIGNING_IDENTITY)" "$(APP_DIR)"
	@codesign --verify --strict --verbose=1 "$(APP_DIR)"
	@echo "Signed $(APP_DIR) with identity: $(APPLE_SIGNING_IDENTITY)"

# Submit to Apple and staple the ticket, so Gatekeeper clears the app offline.
# Needs APPLE_ID, APPLE_PASSWORD (an app-specific password) and APPLE_TEAM_ID.
notarize: package
ifeq ($(APPLE_SIGNING_IDENTITY),-)
	@echo "notarize: skipped, ad-hoc signed builds cannot be notarized." >&2
	@exit 1
else
	xcrun notarytool submit "$(ZIP)" --apple-id "$(APPLE_ID)" \
		--password "$(APPLE_PASSWORD)" --team-id "$(APPLE_TEAM_ID)" --wait
	xcrun stapler staple "$(APP_DIR)"
	@echo "Notarized and stapled. Repackaging so the zip carries the ticket…"
	@rm -f "$(ZIP)"
	cd build && zip -r -y "../$(ZIP)" "$(APP_NAME).app"
	@shasum -a 256 "$(ZIP)"
endif

clean:
	rm -rf build dist

install: all
	mkdir -p "$(HOME)/Applications"
	pkill -x Veil 2>/dev/null || true
	pkill -x Vaulty 2>/dev/null || true
	sleep 0.3
	rm -rf "$(INSTALL)"
	rm -rf "$(HOME)/Applications/Veil.app"
	cp -R "$(APP_DIR)" "$(INSTALL)"
	xattr -cr "$(INSTALL)" 2>/dev/null || true
	@echo "Installed → $(INSTALL)"

run: install
	open "$(INSTALL)"
	@echo "Vaulty running. ⌘⇧L to lock · menu bar ◐ → Control Panel"

package: all
	mkdir -p "$(DIST)"
	rm -f "$(ZIP)"
	cd build && zip -r -y "../$(ZIP)" "$(APP_NAME).app"
	@echo "Packaged → $(ZIP)"
	@shasum -a 256 "$(ZIP)"
