APP_NAME := Zangband
ROOT_DIR := ..
BUILD_DIR := build
APP := $(BUILD_DIR)/$(APP_NAME).app
CONTENTS := $(APP)/Contents
MACOS := $(CONTENTS)/MacOS
RESOURCES := $(CONTENTS)/Resources
GAME := $(ROOT_DIR)/zangband

.PHONY: all app clean run game

all: app

game:
	$(MAKE) -C $(ROOT_DIR) zangband

$(GAME):
	$(MAKE) -C $(ROOT_DIR) zangband

app: $(GAME) main.m Info.plist
	rm -rf "$(APP)"
	mkdir -p "$(MACOS)" "$(RESOURCES)"
	clang -fobjc-arc -O2 -mmacosx-version-min=11.0 -framework Cocoa main.m -o "$(MACOS)/$(APP_NAME)"
	cp Info.plist "$(CONTENTS)/Info.plist"
	cp "$(GAME)" "$(RESOURCES)/zangband"
	chmod +x "$(RESOURCES)/zangband"
	ditto "$(ROOT_DIR)/lib" "$(RESOURCES)/lib"

run: app
	open "$(APP)"

clean:
	rm -rf "$(BUILD_DIR)"
