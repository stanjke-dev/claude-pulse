EXT_UUID := claude-pulse@stanjke.dev
EXT_DIR  := ui/gnome/$(EXT_UUID)

.PHONY: install uninstall test lint pack reload

install:
	bash install.sh

uninstall:
	bash uninstall.sh

test:
	bash test/selftest.sh

lint:
	bash -n install.sh uninstall.sh bin/pulse lib/pulse-lib.sh reporters/claude-code/pulse-hook.sh reporters/claude-code/pulse-statusline.sh
	python3 -m py_compile reporters/claude-code/resolve-window.py
	node --check $(EXT_DIR)/extension.js
	python3 -m json.tool $(EXT_DIR)/metadata.json >/dev/null

pack:
	mkdir -p dist
	gnome-extensions pack --force --out-dir=dist $(EXT_DIR)

reload:
	@echo "X11: press Alt+F2, type r, Enter.  Wayland: log out and back in."
