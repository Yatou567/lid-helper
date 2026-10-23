#!/bin/zsh
set -euo pipefail
SOURCE_DIR="${0:A:h}"
DESTINATION="${SOURCE_DIR:h}"
BUILD_DIR="${LIDHELPER_BUILD_DIR:-$(mktemp -d -t lidhelper)}"
APP_PATH="$DESTINATION/合盖助手.app"
mkdir -p "$BUILD_DIR/module-cache" "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
SWIFTC="$(xcrun --find swiftc)"
SDK_PATH="$(xcrun --show-sdk-path)"
EXTRA_FLAGS=()
# A sandboxed build host may not support the compiler's additional nested sandbox.
if [[ "${LIDHELPER_DISABLE_PLUGIN_SANDBOX:-0}" == "1" ]]; then EXTRA_FLAGS=(-disable-sandbox); fi
"$SWIFTC" "${EXTRA_FLAGS[@]}" -sdk "$SDK_PATH" -parse-as-library -swift-version 6 -target arm64-apple-macosx14.0 \
    -module-cache-path "$BUILD_DIR/module-cache" -O \
    "$SOURCE_DIR/Sources/PowerCore.swift" "$SOURCE_DIR/Sources/LidHelper.swift" \
    -o "$APP_PATH/Contents/MacOS/LidHelper"
cp "$SOURCE_DIR/Info.plist" "$APP_PATH/Contents/Info.plist"
"$SWIFTC" -sdk "$SDK_PATH" -module-cache-path "$BUILD_DIR/module-cache" "$SOURCE_DIR/make-icon.swift" -o "$BUILD_DIR/make-icon"
"$BUILD_DIR/make-icon" "$BUILD_DIR/AppIcon.iconset" "$APP_PATH/Contents/Resources/AppIcon.icns"
/usr/bin/codesign --force --sign - "$APP_PATH"
"$SWIFTC" -sdk "$SDK_PATH" -parse-as-library -swift-version 6 -target arm64-apple-macosx14.0 \
    -module-cache-path "$BUILD_DIR/module-cache" \
    "$SOURCE_DIR/Sources/PowerCore.swift" "$SOURCE_DIR/Tests/PowerCoreTests.swift" \
    -o "$BUILD_DIR/PowerCoreTests"
"$BUILD_DIR/PowerCoreTests"
"$APP_PATH/Contents/MacOS/LidHelper" --status
print "Built: $APP_PATH"
