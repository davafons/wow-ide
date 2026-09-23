#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_path="$repo_dir/dist/WoW IDE.app"
resources_dir="$repo_dir/Resources"

cd "$repo_dir"
swift package --allow-writing-to-package-directory --allow-network-connections all \
    cef bundle --product WoWIDEFeasibility --configuration release \
    --name "WoW IDE" --bundle-id com.davafons.wowide \
    --sign - --output "$repo_dir/dist"

# CEF's bundler assembles the framework and helper apps. Keep the probe
# menu-bar-only after its Info.plist is generated, then re-sign the main app.
/usr/libexec/PlistBuddy -c 'Add :LSUIElement bool true' "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 0.1.0' "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string AppIcon' "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :LSApplicationCategoryType string public.app-category.developer-tools' "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :LSMultipleInstancesProhibited bool true' "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :NSAppTransportSecurity dict' "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :NSAppTransportSecurity:NSAllowsLocalNetworking bool true' "$app_path/Contents/Info.plist"
mkdir -p "$app_path/Contents/Resources"
cp "$resources_dir/AppIcon.icns" "$app_path/Contents/Resources/AppIcon.icns"
cp "$resources_dir/PrivacyInfo.xcprivacy" "$app_path/Contents/Resources/PrivacyInfo.xcprivacy"
cp "$repo_dir/THIRD_PARTY_NOTICES.md" "$app_path/Contents/Resources/THIRD_PARTY_NOTICES.md"
plutil -lint "$app_path/Contents/Info.plist"
codesign --force --sign - "$app_path"
codesign --verify --strict "$app_path"
printf 'Packaged: %s\n' "$app_path"
