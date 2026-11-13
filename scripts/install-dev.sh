#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$project_dir/.build/xcode"
app_name="Wi-Fi Hook.app"
source_app="$build_dir/Build/Products/Debug/$app_name"
applications_dir="${WIFI_HOOK_APPLICATIONS_DIR:-$HOME/Applications}"
destination="$applications_dir/$app_name"
legacy_destination="$applications_dir/WiFiHook.app"

# Build before touching an existing installation.
xcodebuild -project "$project_dir/WiFiHook.xcodeproj" -scheme WiFiHook \
    -configuration Debug -derivedDataPath "$build_dir" build
codesign --verify --deep --strict "$source_app"

for executable in "$destination/Contents/MacOS/Wi-Fi Hook" "$legacy_destination/Contents/MacOS/WiFiHook"; do
    if pgrep -f "^$executable$" >/dev/null; then
        echo "Wi-Fi Hook is running. Quit it before installing an update." >&2
        exit 1
    fi
done

previous_path=""
for candidate in "$destination" "$legacy_destination"; do
    if [ -e "$candidate" ] || [ -L "$candidate" ]; then
        if [ -n "$previous_path" ]; then
            echo "Both the old and new app paths exist; resolve them before installing." >&2
            exit 1
        fi
        existing_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$candidate/Contents/Info.plist" 2>/dev/null || true)"
        if [ "$existing_id" != "com.omochimetaru.WiFiHook" ] && [ "$existing_id" != "jp.omochi.WiFiHook" ]; then
            echo "Refusing to replace an unrelated item: $candidate" >&2
            exit 1
        fi
        previous_path="$candidate"
    fi
done

mkdir -p "$applications_dir"
staging="$(mktemp -d "$applications_dir/.wifihook-install.XXXXXXXX")"
cleanup() {
    if [ -e "$staging/previous.app" ] && [ ! -e "$destination" ]; then
        if ! mv "$staging/previous.app" "$previous_path"; then
            echo "Restore failed; previous app is at $staging/previous.app" >&2
            return
        fi
    fi
    rm -rf "$staging"
}
trap cleanup EXIT
ditto "$source_app" "$staging/$app_name"
codesign --verify --deep --strict "$staging/$app_name"
if [ -n "$previous_path" ]; then
    mv "$previous_path" "$staging/previous.app"
fi
mv "$staging/$app_name" "$destination"
echo "Installed: $destination"
