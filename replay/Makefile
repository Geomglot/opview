# OPRivView Replay: build the Mac app with its server and ffmpeg inside.
#   make app       build everything to dist/OPRivView Replay.app
#   make install   copy it to /Applications
#   make clean     remove build output and the installed app
APP_NAME   = OPRivView Replay.app
REPO       = $(abspath ..)
BUILT_APP  = $(REPO)/build/macos/Build/Products/Release/$(APP_NAME)
OUT_APP    = dist/$(APP_NAME)
PY         = .venv/bin/python
INSTALL_DIR = /Applications

.PHONY: app sidecar flutter install clean

app: sidecar flutter
	rm -rf "$(OUT_APP)"
	mkdir -p dist
	cp -R "$(BUILT_APP)" "$(OUT_APP)"
	cp -R dist/oprivview-replay-server "$(OUT_APP)/Contents/Resources/"
	$(PY) packaging/bundle_ffmpeg.py "$(OUT_APP)/Contents/Resources/ffmpeg"
	codesign --force --deep -s - "$(OUT_APP)"
	@echo "Built: $(CURDIR)/$(OUT_APP)"

sidecar:
	.venv/bin/pyinstaller packaging/server.spec --distpath dist --workpath build -y

flutter:
	cd "$(REPO)" && flutter build macos --release -t lib/main_replay.dart && git checkout analysis_options.yaml

install: app
	rm -rf "$(INSTALL_DIR)/$(APP_NAME)"
	cp -R "$(OUT_APP)" "$(INSTALL_DIR)/$(APP_NAME)"
	@echo "Installed: $(INSTALL_DIR)/$(APP_NAME)"

clean:
	rm -rf dist build "$(INSTALL_DIR)/$(APP_NAME)"
