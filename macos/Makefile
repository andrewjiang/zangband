APP_NAME := Zangband
ROOT_DIR := ..
BUILD_DIR := build
APP := $(BUILD_DIR)/$(APP_NAME).app
CONTENTS := $(APP)/Contents
MACOS := $(CONTENTS)/MacOS
RESOURCES := $(CONTENTS)/Resources
GAME := $(ROOT_DIR)/zangband

NATIVE_APP_NAME := ZangbandNative
NATIVE_APP := $(BUILD_DIR)/$(NATIVE_APP_NAME).app
NATIVE_CONTENTS := $(NATIVE_APP)/Contents
NATIVE_MACOS := $(NATIVE_CONTENTS)/MacOS
NATIVE_RESOURCES := $(NATIVE_CONTENTS)/Resources
NATIVE_OBJ_DIR := $(BUILD_DIR)/native-obj
NATIVE_EXECUTABLE := $(NATIVE_MACOS)/$(NATIVE_APP_NAME)
NATIVE_STAMP := $(BUILD_DIR)/$(NATIVE_APP_NAME).built
NATIVE_CFLAGS := -DHAVE_CONFIG_H -DUSE_COCOA -DCOCOA_ONLY -DDEFAULT_PATH=\"./lib/\" -I$(ROOT_DIR)/src -I$(ROOT_DIR)/src/lua -O2 -mmacosx-version-min=11.0 -Wno-deprecated-non-prototype -Wno-implicit-function-declaration
NATIVE_LIBS := -framework Cocoa -lz -lrpcsvc

NATIVE_ENGINE_SRCS := $(addprefix $(ROOT_DIR)/src/,\
	variable.c tables.c util.c cave.c \
	object1.c object2.c monster1.c monster2.c \
	xtra1.c xtra2.c spells1.c spells2.c \
	melee1.c melee2.c save.c files.c fields.c \
	cmd1.c cmd2.c cmd3.c cmd4.c cmd5.c cmd6.c \
	store.c birth.c load.c ui.c \
	wizard1.c wizard2.c grid.c streams.c rooms.c \
	generate.c dungeon.c init1.c init2.c \
	effects.c quest.c racial.c run.c script.c \
	artifact.c mutation.c flavor.c spells3.c \
	mspells1.c mspells2.c scores.c mind.c \
	bldg.c obj_kind.c wild1.c wild2.c wild3.c avatar.c notes.c \
	l-monst.c l-object.c l-player.c l-random.c l-ui.c \
	l-misc.c l-spell.c l-field.c \
	z-util.c z-virt.c z-form.c z-rand.c z-term.c \
	maid-grf.c \
	zborg1.c zborg2.c zborg3.c zborg4.c zborg5.c \
	zborg6.c zborg7.c zborg8.c zborg9.c \
	zbmagic1.c zbmagic2.c zbmagic3.c)

NATIVE_LUA_SRCS := $(addprefix $(ROOT_DIR)/src/lua/,\
	lapi.c ldebug.c lmem.c lstrlib.c lvm.c \
	tolua_lb.c lauxlib.c ldo.c lobject.c ltable.c \
	lzio.c tolua_rg.c lbaselib.c lfunc.c lparser.c \
	ltests.c tolua_bd.c tolua_tm.c lcode.c lgc.c \
	lstate.c ltm.c tolua_eh.c tolua_tt.c ldblib.c \
	llex.c lstring.c lundump.c tolua_gp.c)

NATIVE_ENGINE_OBJS := $(patsubst $(ROOT_DIR)/src/%.c,$(NATIVE_OBJ_DIR)/src/%.o,$(NATIVE_ENGINE_SRCS))
NATIVE_LUA_OBJS := $(patsubst $(ROOT_DIR)/src/lua/%.c,$(NATIVE_OBJ_DIR)/src/lua/%.o,$(NATIVE_LUA_SRCS))
NATIVE_GAME_MAIN_OBJ := $(NATIVE_OBJ_DIR)/src/main-game.o
NATIVE_COCOA_OBJ := $(NATIVE_OBJ_DIR)/src/main-cocoa.o

.PHONY: all app clean run game release release-wrapper native run-native

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

release:
	"$(ROOT_DIR)/scripts/build-native-macos-release.sh"

release-wrapper:
	"$(ROOT_DIR)/scripts/build-macos-release.sh"

$(NATIVE_OBJ_DIR)/src/%.o: $(ROOT_DIR)/src/%.c $(GAME)
	mkdir -p "$(dir $@)"
	clang $(NATIVE_CFLAGS) -c "$<" -o "$@"

$(NATIVE_OBJ_DIR)/src/lua/%.o: $(ROOT_DIR)/src/lua/%.c $(GAME)
	mkdir -p "$(dir $@)"
	clang $(NATIVE_CFLAGS) -c "$<" -o "$@"

$(NATIVE_GAME_MAIN_OBJ): $(ROOT_DIR)/src/main.c $(GAME)
	mkdir -p "$(dir $@)"
	clang $(NATIVE_CFLAGS) -Dmain=zangband_game_main -c "$<" -o "$@"

$(NATIVE_COCOA_OBJ): $(ROOT_DIR)/src/main-cocoa.m $(GAME)
	mkdir -p "$(dir $@)"
	clang $(NATIVE_CFLAGS) -fobjc-arc -c "$<" -o "$@"

native: $(NATIVE_STAMP)

$(NATIVE_STAMP): $(NATIVE_ENGINE_OBJS) $(NATIVE_LUA_OBJS) $(NATIVE_GAME_MAIN_OBJ) $(NATIVE_COCOA_OBJ) Info.plist
	rm -rf "$(NATIVE_APP)"
	mkdir -p "$(NATIVE_MACOS)" "$(NATIVE_RESOURCES)"
	clang -fobjc-arc -mmacosx-version-min=11.0 -o "$(NATIVE_EXECUTABLE)" $(NATIVE_ENGINE_OBJS) $(NATIVE_LUA_OBJS) $(NATIVE_GAME_MAIN_OBJ) $(NATIVE_COCOA_OBJ) $(NATIVE_LIBS)
	cp Info.plist "$(NATIVE_CONTENTS)/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $(NATIVE_APP_NAME)" "$(NATIVE_CONTENTS)/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleName $(NATIVE_APP_NAME)" "$(NATIVE_CONTENTS)/Info.plist"
	/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $(NATIVE_APP_NAME)" "$(NATIVE_CONTENTS)/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $(NATIVE_APP_NAME)" "$(NATIVE_CONTENTS)/Info.plist"
	ditto "$(ROOT_DIR)/lib" "$(NATIVE_RESOURCES)/lib"
	touch "$@"

run: app
	open "$(APP)"

run-native: native
	open "$(NATIVE_APP)"

clean:
	rm -rf "$(BUILD_DIR)"
