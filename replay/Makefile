# OPRivView Replay: build the Mac app with its server and ffmpeg inside.
#   make app       build everything to dist/OPRivView Replay.app
#   make dmg       build the app and put it in one disk image for release, dist/OPRivView-Replay-<version>-macOS-Intel.dmg
#   make install   copy it to /Applications
#   make clean     remove build output and the installed app
APP_NAME   = OPRivView Replay.app
REPO       = $(abspath ..)
BUILT_APP  = $(REPO)/build/macos/Build/Products/Release/$(APP_NAME)
OUT_APP    = dist/$(APP_NAME)
PY         = .venv/bin/python
INSTALL_DIR = /Applications
FFMPEG     = build/ffmpeg-src
VERSION    = $(shell grep '^version:' $(REPO)/pubspec.yaml | sed 's/version: *//; s/+.*//')
DMG        = dist/OPRivView-Replay-$(VERSION)-macOS-Intel.dmg
MIN_MACOS  = 14.0# the numpy the time zone lookup uses will not run on anything older

.PHONY: app dmg sidecar flutter install clean

app: sidecar flutter $(FFMPEG)/ffmpeg
	rm -rf "$(OUT_APP)"
	mkdir -p dist
	cp -R "$(BUILT_APP)" "$(OUT_APP)"
	cp -R dist/oprivview-replay-server "$(OUT_APP)/Contents/Resources/"
	mkdir "$(OUT_APP)/Contents/Resources/ffmpeg"
	cp $(FFMPEG)/ffmpeg $(FFMPEG)/ffprobe "$(OUT_APP)/Contents/Resources/ffmpeg/"
	$(PY) packaging/write_notices.py "$(OUT_APP)/Contents/Resources/licenses" $(FFMPEG)
	/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $(MIN_MACOS)" "$(OUT_APP)/Contents/Info.plist"
	codesign --force --deep -s - "$(OUT_APP)"
	codesign --verify --deep --strict "$(OUT_APP)"
	@echo "Built: $(CURDIR)/$(OUT_APP)"

dmg: app
	rm -rf build/dmg "$(DMG)"
	mkdir build/dmg
	cp -R "$(OUT_APP)" build/dmg/
	ln -s /Applications build/dmg/Applications
	cp packaging/dmg-read-me.txt "build/dmg/Read Me First.txt"
	hdiutil create -volname "OPRivView Replay" -srcfolder build/dmg -format UDZO -fs HFS+ -ov "$(DMG)"
	hdiutil verify "$(DMG)"
	rm -rf build/dmg
	@shasum -a 256 "$(DMG)"
	@echo "Built: $(CURDIR)/$(DMG)"

$(FFMPEG)/ffmpeg: packaging/build_ffmpeg.sh
	packaging/build_ffmpeg.sh $(FFMPEG)

sidecar:
	.venv/bin/pyinstaller packaging/server.spec --distpath dist --workpath build -y

flutter:
	cd "$(REPO)" && flutter build macos --release -t lib/main_replay.dart

install: app
	rm -rf "$(INSTALL_DIR)/$(APP_NAME)"
	cp -R "$(OUT_APP)" "$(INSTALL_DIR)/$(APP_NAME)"
	@echo "Installed: $(INSTALL_DIR)/$(APP_NAME)"

clean:
	rm -rf dist build "$(INSTALL_DIR)/$(APP_NAME)"
