#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")" && pwd)"
output_dir="${1:-$project_dir/outputs}"
build_dir="${2:-$project_dir/.build}"
app="$output_dir/Gopher Browser.app"
stage="$(mktemp -d)"
trap 'rm -rf -- "$stage"' EXIT
staged_app="$stage/Gopher Browser.app"

swift build --package-path "$project_dir" --scratch-path "$build_dir" -c release
bin_dir="$(swift build --package-path "$project_dir" --scratch-path "$build_dir" -c release --show-bin-path)"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
cp "$project_dir/Info.plist" "$staged_app/Contents/Info.plist"
cp "$project_dir/Sources/GopherBrowser/Resources/Reader.css" "$staged_app/Contents/Resources/Reader.css"
install -m 755 "$bin_dir/GopherBrowser" "$staged_app/Contents/MacOS/GopherBrowser"

minimum_macos="$(plutil -extract LSMinimumSystemVersion raw "$project_dir/Info.plist")"
xcrun actool --compile "$staged_app/Contents/Resources" \
    --platform macosx --target-device mac --product-type com.apple.product-type.application \
    --minimum-deployment-target "$minimum_macos" --app-icon GopherIcon \
    --output-partial-info-plist "$stage/icon-metadata.plist" --output-format human-readable-text \
    "$project_dir/Assets/GopherIcon.icon"
/usr/libexec/PlistBuddy -c "Merge \"$stage/icon-metadata.plist\"" "$staged_app/Contents/Info.plist"

codesign --force --sign - "$staged_app"
mkdir -p "$output_dir"
ditto --noextattr --norsrc "$staged_app" "$app"
echo "$app"
