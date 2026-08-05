.PHONY: run app test build clean uninstall

# One command, first run: builds BeLauncher.app and launches it.
run: app
	@pkill -x BeLauncher >/dev/null 2>&1 || true
	@open build/BeLauncher.app
	@echo "BeLauncher is running in the menu bar. Press ⌥Space to open it."

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
	@pkill -x BeLauncher >/dev/null 2>&1 || true
	rm -rf build/BeLauncher.app
	rm -rf "$$HOME/Library/Application Support/BeLauncher"
	@echo "Removed the app bundle and ~/Library/Application Support/BeLauncher."
	@echo "Secrets, if any, remain in Keychain Access under service com.believe.belauncher.secrets."
