APP_NAME := Vaulty
VERSION  ?= 1.0.0
APP_DIR  := build/$(APP_NAME).app
BIN_DIR  := $(APP_DIR)/Contents/MacOS
RES_DIR  := $(APP_DIR)/Contents/Resources
SRC      := Sources/main.swift
INSTALL  := $(HOME)/Applications/$(APP_NAME).app
DIST     := dist
ZIP      := $(DIST)/$(APP_NAME)-$(VERSION)-macos.zip

.PHONY: all clean install run package

all: $(APP_DIR)/Contents/MacOS/$(APP_NAME)

$(APP_DIR)/Contents/MacOS/$(APP_NAME): $(SRC) Info.plist
	mkdir -p "$(BIN_DIR)" "$(RES_DIR)"
	swiftc -O -framework AppKit -framework Carbon -framework ApplicationServices \
		-o "$(BIN_DIR)/$(APP_NAME)" $(SRC)
	cp Info.plist "$(APP_DIR)/Contents/Info.plist"
	@echo "Built $(APP_DIR)"

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
