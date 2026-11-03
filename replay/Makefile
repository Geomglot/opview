# OPRivView Replay: build the Mac app with its server and ffmpeg inside.
#   make app       build everything to dist/OPRivView Replay.app
#   make dmg       build the app and put it in one disk image for release, dist/OPRivView-Replay-<version>-macOS-<Intel|ARM>.dmg
#   make install   copy it to /Applications
#   make clean     remove build output and the installed app
# The Mac the release is for is ARCH, defaulting to the Mac doing the build, so building on
# Apple silicon just works. Pass ARCH=Intel to build for the other kind of Mac; each release
# folder is keyed on the arch, so a build for one Mac never reuses the other's ffmpeg.
APP_NAME   = OPRivView Replay.app
REPO       = $(abspath ..)
BUILT_APP  = $(REPO)/build/macos/Build/Products/Release/$(APP_NAME)
OUT_APP    = dist/$(APP_NAME)
PY         = .venv/bin/python
INSTALL_DIR = /Applications
VERSION    = $(shell grep '^version:' $(REPO)/pubspec.yaml | sed 's/version: *//; s/+.*//')
ARCH      ?= $(if $(filter x86_64,$(shell uname -m)),Intel,ARM)
SIDE_ARCH  = $(if $(filter Intel,$(ARCH)),x86_64,arm64)
FFMPEG     = build/ffmpeg-$(SIDE_ARCH)
DMG        = dist/OPRivView-Replay-$(VERSION)-macOS-$(ARCH).dmg
MIN_MACOS  = 14.0# the numpy the time zone lookup uses will not run on anything older
ARCH_NEEDED = $(if $(filter Intel,$(ARCH)),an Intel Mac,an Apple silicon Mac)

# The app target checks every bundled executable is the arch the DMG name says.
# PyInstaller builds the server for whatever arch the .venv Python runs as, so on Apple
# silicon the server would be arm64 even in an ARCH=Intel release; and a leftover ffmpeg
# from the other kind of build could slip in. This stops a mislabelled DMG at build time.

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
	@for b in "$(OUT_APP)/Contents/Resources/ffmpeg/ffmpeg" \
	          "$(OUT_APP)/Contents/Resources/ffmpeg/ffprobe" \
	          "$(OUT_APP)/Contents/Resources/oprivview-replay-server/oprivview-replay-server"; do \
	  if ! lipo "$$b" -verify_arch $(SIDE_ARCH) >/dev/null 2>&1; then \
	    echo "$$b is not $(SIDE_ARCH); this $(ARCH) DMG would not run on the Mac it names."; \
	    echo "Rebuild it from a $(ARCH) venv/machine (rm -rf $(FFMPEG) dist) and try again."; exit 1; \
	  fi; \
	done
	codesign --force --deep -s - "$(OUT_APP)"
	codesign --verify --deep --strict "$(OUT_APP)"
	@echo "Built: $(CURDIR)/$(OUT_APP)"

dmg: app
	rm -rf build/dmg "$(DMG)"
	mkdir build/dmg
	cp -R "$(OUT_APP)" build/dmg/
	ln -s /Applications build/dmg/Applications
	sed "s/{{ARCH_NEEDED}}/$(ARCH_NEEDED)/" packaging/dmg-read-me.txt > "build/dmg/Read Me First.txt"
	hdiutil create -volname "OPRivView Replay" -srcfolder build/dmg -format UDZO -fs HFS+ -ov "$(DMG)"
	hdiutil verify "$(DMG)"
	rm -rf build/dmg
	@shasum -a 256 "$(DMG)"
	@echo "Built: $(CURDIR)/$(DMG)"

$(FFMPEG)/ffmpeg: packaging/build_ffmpeg.sh
	packaging/build_ffmpeg.sh $(FFMPEG) $(SIDE_ARCH)

sidecar: .venv
	$(PY) -m PyInstaller packaging/server.spec --distpath dist --workpath build -y

.venv:
	@echo "No .venv: run  python3.12 -m venv .venv && .venv/bin/pip install -r requirements.txt  first"
	exit 1

flutter:
	cd "$(REPO)" && flutter build macos --release -t lib/main_replay.dart

install: app
	rm -rf "$(INSTALL_DIR)/$(APP_NAME)"
	cp -R "$(OUT_APP)" "$(INSTALL_DIR)/$(APP_NAME)"
	@echo "Installed: $(INSTALL_DIR)/$(APP_NAME)"

clean:
	rm -rf dist build "$(INSTALL_DIR)/$(APP_NAME)"