#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
source_dir="$project_dir/native"
mkdir -p "$project_dir/work"
build_dir="$(mktemp -d "$project_dir/work/translation-native.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
export CLANG_MODULE_CACHE_PATH="$build_dir/clang-module-cache"
export SWIFT_MODULE_CACHE_PATH="$build_dir/swift-module-cache"
app_dir="$build_dir/Yike.app"
contents_dir="$app_dir/Contents"
macos_dir="$contents_dir/MacOS"
resources_dir="$contents_dir/Resources"
asset_catalog_dir="$build_dir/AppAssets.xcassets"
iconset_dir="$asset_catalog_dir/AppIcon.appiconset"
dmg_root="$build_dir/dmg-root"
output_file="$project_dir/outputs/Yike-macOS-arm64.dmg"

mkdir -p "$macos_dir" "$resources_dir" "$iconset_dir" "$dmg_root" "$project_dir/outputs"

bash "$source_dir/build_speech_engine.sh"
cp "$project_dir/work/voice-edit-update/whisper-build/bin/whisper-cli" "$macos_dir/whisper-cli"
codesign --force --sign - "$macos_dir/whisper-cli"

xcrun swiftc -O -target arm64-apple-macos13.0 -parse-as-library -module-name FanyiApp \
  "$source_dir/"*.swift \
  -o "$macos_dir/Translation" \
  -framework SwiftUI -framework AppKit -framework Foundation -framework Speech -framework AVFoundation -framework Translation -framework Security -framework Vision -framework NaturalLanguage -framework UniformTypeIdentifiers -framework ApplicationServices -framework Carbon

cp "$source_dir/Info.plist" "$contents_dir/Info.plist"
cp "$source_dir/ThirdPartyNotices.txt" "$resources_dir/ThirdPartyNotices.txt"
cp "$source_dir/UpdateInstaller.sh" "$resources_dir/UpdateInstaller.sh"
cp "$project_dir/work/voice-edit-update/whisper.cpp/LICENSE" "$resources_dir/Whisper-LICENSE.txt"
plutil -lint "$contents_dir/Info.plist" >/dev/null

sips -z 1024 1024 "$source_dir/AppIconSource.png" --out "$build_dir/AppIcon.png" >/dev/null
sips -z 16 16 "$build_dir/AppIcon.png" --out "$iconset_dir/icon_16x16.png" >/dev/null
sips -z 32 32 "$build_dir/AppIcon.png" --out "$iconset_dir/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$build_dir/AppIcon.png" --out "$iconset_dir/icon_32x32.png" >/dev/null
sips -z 64 64 "$build_dir/AppIcon.png" --out "$iconset_dir/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$build_dir/AppIcon.png" --out "$iconset_dir/icon_128x128.png" >/dev/null
sips -z 256 256 "$build_dir/AppIcon.png" --out "$iconset_dir/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$build_dir/AppIcon.png" --out "$iconset_dir/icon_256x256.png" >/dev/null
sips -z 512 512 "$build_dir/AppIcon.png" --out "$iconset_dir/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$build_dir/AppIcon.png" --out "$iconset_dir/icon_512x512.png" >/dev/null
cp "$build_dir/AppIcon.png" "$iconset_dir/icon_512x512@2x.png"
cp "$source_dir/AppIconContents.json" "$iconset_dir/Contents.json"
xcrun actool "$asset_catalog_dir" \
  --compile "$resources_dir" \
  --platform macosx \
  --minimum-deployment-target 13.0 \
  --app-icon AppIcon \
  --output-partial-info-plist "$build_dir/AppIcon-Info.plist" \
  >/dev/null

codesign --force --deep --sign - \
  --identifier "com.yijian.translator.kimi" \
  --requirements '=designated => identifier "com.yijian.translator.kimi"' \
  "$app_dir" >/dev/null
codesign --verify --deep --strict "$app_dir"

ditto "$app_dir" "$dmg_root/Yike.app"
ln -s /Applications "$dmg_root/Applications"
hdiutil create -volname "Yike安装" -srcfolder "$dmg_root" -ov -format UDZO "$output_file" >/dev/null

echo "$output_file"
