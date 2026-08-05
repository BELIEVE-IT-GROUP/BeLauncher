.PHONY: run app test build clean uninstall

# One command, first run: builds Beacon.app and launches it.
run: app
	@pkill -x Beacon >/dev/null 2>&1 || true
	@open build/Beacon.app
	@echo "Beacon is running in the menu bar. Press ⌥Space to open it."

app:
	@bash Scripts/bundle.sh release

build:
	swift build

test:
	swift test

clean:
	swift package clean
	rm -rf build

# Removes the app and every trace of local data. Keychain secrets are listed, not deleted,
# so you can review them in Keychain Access first.
uninstall:
	@pkill -x Beacon >/dev/null 2>&1 || true
	rm -rf build/Beacon.app
	rm -rf "$$HOME/Library/Application Support/Beacon"
	@echo "Removed the app bundle and ~/Library/Application Support/Beacon."
	@echo "Secrets, if any, remain in Keychain Access under service com.beacon.launcher.secrets."
