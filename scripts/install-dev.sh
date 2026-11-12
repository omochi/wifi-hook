#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$project_dir/.build/xcode"
app_name="WiFiHook.app"
source_app="$build_dir/Build/Products/Debug/$app_name"
applications_dir="$HOME/Applications"
destination="$applications_dir/$app_name"

# Build before touching an existing installation.
xcodebuild -project "$project_dir/WiFiHook.xcodeproj" -scheme WiFiHook \
    -configuration Debug -derivedDataPath "$build_dir" build
codesign --verify --deep --strict "$source_app"

if pgrep -f "^$destination/Contents/MacOS/WiFiHook$" >/dev/null; then
    echo "Wi-Fi Hook is running. Quit it before installing an update." >&2
    exit 1
fi

if [ -e "$destination" ]; then
    existing_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist" 2>/dev/null || true)"
    if [ "$existing_id" != "com.omochimetaru.WiFiHook" ] && [ "$existing_id" != "jp.omochi.WiFiHook" ]; then
        echo "Refusing to replace an unrelated item: $destination" >&2
        exit 1
    fi
fi

mkdir -p "$applications_dir"
staging="$(mktemp -d "$applications_dir/.wifihook-install.XXXXXXXX")"
cleanup() {
    if [ -e "$staging/previous.app" ] && [ ! -e "$destination" ]; then
        if ! mv "$staging/previous.app" "$destination"; then
            echo "Restore failed; previous app is at $staging/previous.app" >&2
            return
        fi
    fi
    rm -rf "$staging"
}
trap cleanup EXIT
ditto "$source_app" "$staging/$app_name"
codesign --verify --deep --strict "$staging/$app_name"
if [ -e "$destination" ]; then
    mv "$destination" "$staging/previous.app"
fi
if ! mv "$staging/$app_name" "$destination"; then
    exit 1
fi
echo "Installed: $destination"
