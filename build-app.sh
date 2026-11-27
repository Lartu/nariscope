#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")" && pwd)"
output_dir="${1:-$project_dir/outputs}"
build_dir="${2:-$project_dir/.build}"
app="$output_dir/Nariscope.app"
stage="$(mktemp -d)"
trap 'rm -rf -- "$stage"' EXIT
staged_app="$stage/Nariscope.app"

swift build --package-path "$project_dir" --scratch-path "$build_dir" -c release
bin_dir="$(swift build --package-path "$project_dir" --scratch-path "$build_dir" -c release --show-bin-path)"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
cp "$project_dir/Info.plist" "$staged_app/Contents/Info.plist"
cp "$project_dir/Sources/Nariscope/Resources/Reader.css" \
    "$project_dir/Sources/Nariscope/Resources/ReaderDark.css" "$staged_app/Contents/Resources/"
install -m 755 "$bin_dir/Nariscope" "$staged_app/Contents/MacOS/Nariscope"

minimum_macos="$(plutil -extract LSMinimumSystemVersion raw "$project_dir/Info.plist")"
compile_icon() {
    local name="$1" destination="$2" metadata="$3"
    mkdir -p "$destination"
    xcrun actool --compile "$destination" \
        --platform macosx --target-device mac --product-type com.apple.product-type.application \
        --minimum-deployment-target "$minimum_macos" --app-icon "$name" \
        --output-partial-info-plist "$metadata" --output-format human-readable-text \
        "$project_dir/Assets/$name.icon"
}

compile_icon GopherIcon "$staged_app/Contents/Resources" "$stage/icon-metadata.plist"
/usr/libexec/PlistBuddy -c "Merge \"$stage/icon-metadata.plist\"" "$staged_app/Contents/Info.plist"

for icon in GopherIcon2 GopherIcon3; do
    compile_icon "$icon" "$stage/$icon" "$stage/$icon.plist"
    cp "$stage/$icon/$icon.icns" "$staged_app/Contents/Resources/$icon.icns"
done

codesign --force --sign - "$staged_app"
mkdir -p "$output_dir"
ditto --noextattr --norsrc "$staged_app" "$app"
echo "$app"
