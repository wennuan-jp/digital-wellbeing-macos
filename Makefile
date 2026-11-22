TARGET = build/lol-guard
APP_BUNDLE = build/LoLGuard.app
APP_BIN = $(APP_BUNDLE)/Contents/MacOS/LoLGuardApp
APP_PLIST = $(APP_BUNDLE)/Contents/Info.plist

.PHONY: all app cli clean test

all: cli app

cli:
	@mkdir -p build
	swift build -c release --product lol-guard
	cp .build/release/lol-guard $(TARGET)
	strip $(TARGET)

app:
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS $(APP_BUNDLE)/Contents/Resources
	swift build -c release --product LolGuardApp
	cp .build/release/LolGuardApp $(APP_BIN)
	strip $(APP_BIN)
	@printf '%s\n' \
	'<?xml version="1.0" encoding="UTF-8"?>' \
	'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	'<plist version="1.0">' \
	'<dict>' \
	'  <key>CFBundleExecutable</key><string>LoLGuardApp</string>' \
	'  <key>CFBundleIdentifier</key><string>com.lolguard.app</string>' \
	'  <key>CFBundleName</key><string>LoL Guard</string>' \
	'  <key>CFBundlePackageType</key><string>APPL</string>' \
	'  <key>CFBundleShortVersionString</key><string>1.0.0</string>' \
	'  <key>CFBundleVersion</key><string>1</string>' \
	'  <key>LSMinimumSystemVersion</key><string>13.0</string>' \
	'  <key>NSHighResolutionCapable</key><true/>' \
	'</dict>' \
	'</plist>' > $(APP_PLIST)
	codesign --force --sign - $(APP_BUNDLE) 2>/dev/null || true

clean:
	rm -rf build .build

test: cli
	./$(TARGET) --status --dry-run
