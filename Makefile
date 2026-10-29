# XaneWM — build helpers (macOS 13+, Xcode 15+ or the Swift 5.9+ toolchain)
#
#   make            release build + XaneWM.app bundle (ad-hoc signed)
#   make install    copy the app to ~/Applications and xanectl to ~/.local/bin
#   make run        build and launch
#   make test       core unit tests
#   make logs       stream the compositor's log

APP      := XaneWM.app
BUILD    := .build/release
PREFIX   ?= $(HOME)/.local
APPS_DIR ?= $(HOME)/Applications
# Signing identity. macOS ties the Accessibility permission to the signature: with ad-hoc ("-")
# every rebuild looks like a new app and the permission is lost. Use the first Apple Development
# certificate in the keychain when there is one; override with `make SIGN_ID=...`.
AUTO_ID  := $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $$2; exit}')
SIGN_ID  ?= $(if $(AUTO_ID),$(AUTO_ID),-)

.PHONY: all build app install run test logs clean uninstall autostart no-autostart

AGENT    := $(HOME)/Library/LaunchAgents/dev.xanewm.plist

all: app

build:
	swift build -c release --product XaneWM
	swift build -c release --product xanectl

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png $(APP)/Contents/Resources/
	cp $(BUILD)/XaneWM $(APP)/Contents/MacOS/XaneWM
	cp $(BUILD)/xanectl $(APP)/Contents/MacOS/xanectl
	codesign --force --sign "$(SIGN_ID)" --options runtime $(APP)/Contents/MacOS/xanectl
	codesign --force --sign "$(SIGN_ID)" --options runtime --identifier dev.xanewm.XaneWM $(APP)
	@echo "Built $(APP) (signed with: $(SIGN_ID))"

install: app
	mkdir -p $(APPS_DIR) $(PREFIX)/bin
	rm -rf $(APPS_DIR)/$(APP)
	cp -R $(APP) $(APPS_DIR)/
	ln -sf $(APPS_DIR)/$(APP)/Contents/MacOS/xanectl $(PREFIX)/bin/xanectl
	@echo "Installed $(APPS_DIR)/$(APP) and $(PREFIX)/bin/xanectl"

run: app
	-pkill -x XaneWM; sleep 0.5
	open $(APP)

test:
	swift test

logs:
	log stream --level debug --predicate 'subsystem == "dev.xanewm"'

# Start at login and restart automatically if it ever crashes (not when you quit it).
autostart: install
	mkdir -p $(HOME)/Library/LaunchAgents
	sed "s#@BIN@#$(APPS_DIR)/$(APP)/Contents/MacOS/XaneWM#" Resources/dev.xanewm.plist > $(AGENT)
	-launchctl bootout gui/$$(id -u) $(AGENT) 2>/dev/null
	launchctl bootstrap gui/$$(id -u) $(AGENT)
	@echo "XaneWM will start at login (LaunchAgent dev.xanewm)"

no-autostart:
	-launchctl bootout gui/$$(id -u) $(AGENT)
	rm -f $(AGENT)

uninstall: no-autostart
	rm -rf $(APPS_DIR)/$(APP) $(PREFIX)/bin/xanectl

clean:
	rm -rf .build $(APP)
