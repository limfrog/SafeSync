#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
configuration="${CONFIGURATION:-release}"
./scripts/build-icons.sh
architecture_options=()
if [[ "${ARCHITECTURE:-native}" == "universal" ]]; then
    architecture_options=(--arch arm64 --arch x86_64)
fi
debug_options=()
if [[ "$configuration" == "release" ]]; then debug_options=(-debug-info-format none); fi
swift build -c "$configuration" "${architecture_options[@]}" "${debug_options[@]}" --product SafeSync --disable-sandbox
binary_directory="$(swift build -c "$configuration" "${architecture_options[@]}" --show-bin-path --disable-sandbox)"
app="${APP_OUTPUT:-$PWD/build/SafeSync.app}"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_directory/SafeSync" "$app/Contents/MacOS/SafeSync"
cp Resources/SafeSync.icns Resources/SafeSync.png "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.limfrog.SafeSync.macOS</string>
<key>CFBundleName</key><string>SafeSync</string>
<key>CFBundleDisplayName</key><string>SafeSync</string>
<key>CFBundleExecutable</key><string>SafeSync</string>
<key>CFBundleIconFile</key><string>SafeSync</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.4</string>
<key>CFBundleVersion</key><string>6</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSDocumentsFolderUsageDescription</key><string>선택한 문서 폴더의 파일을 백업합니다.</string>
<key>NSDesktopFolderUsageDescription</key><string>선택한 데스크탑 폴더의 파일을 백업합니다.</string>
<key>NSDownloadsFolderUsageDescription</key><string>선택한 다운로드 폴더의 파일을 백업합니다.</string>
<key>NSRemovableVolumesUsageDescription</key><string>선택한 외장 드라이브에 백업을 읽고 기록합니다.</string>
<key>NSNetworkVolumesUsageDescription</key><string>선택한 네트워크 폴더에 백업을 읽고 기록합니다.</string>
</dict></plist>
PLIST
identity="${SIGNING_IDENTITY:--}"
if [[ "$identity" == "-" ]]; then
    codesign --force --deep --sign - "$app"
else
    codesign --force --deep --options runtime --timestamp --sign "$identity" "$app"
fi
codesign --verify --deep --strict "$app"
printf '%s\n' "$app"
