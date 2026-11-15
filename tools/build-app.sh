#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

OUTPUT_DIR="${1:-$ROOT_DIR}"
BUILD_DIR=$(mktemp -d /tmp/appvault-build.XXXXXX)

echo "==> Building AppVault in $BUILD_DIR..."

cd "$ROOT_DIR"

if [ -f "$ROOT_DIR/tools/generate_icons.py" ]; then
    echo "==> Generating AppIcon set..."
    python3 "$ROOT_DIR/tools/generate_icons.py" || true
fi

if command -v xcodegen >/dev/null 2>&1; then
    echo "==> Generating Xcode project with xcodegen..."
    xcodegen generate
    
    echo "==> Compiling with xcodebuild..."
    xcodebuild build \
        -project AppVault.xcodeproj \
        -scheme AppVault \
        -configuration Release \
        -sdk iphoneos \
        -derivedDataPath "$BUILD_DIR/DerivedData" \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGN_IDENTITY="" \
        AD_HOC_CODE_SIGNING_ALLOWED=YES

    APP_PATH=$(find "$BUILD_DIR/DerivedData/Build/Products/Release-iphoneos" -name "AppVault.app" -type d | head -n 1)
else
    echo "==> Compiling directly with swiftc for iOS arm64..."
    SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path)
    mkdir -p "$BUILD_DIR/Payload/AppVault.app"
    APP_PATH="$BUILD_DIR/Payload/AppVault.app"

    SWIFT_FILES=$(find "$ROOT_DIR/Sources" -name "*.swift")

    swiftc \
        -target arm64-apple-ios15.0 \
        -sdk "$SDK_PATH" \
        -O \
        -import-objc-header /dev/null 2>/dev/null || true \
        $SWIFT_FILES \
        -emit-executable \
        -o "$APP_PATH/AppVault"

    cp "$ROOT_DIR/Resources/Info.plist" "$APP_PATH/Info.plist"
fi

echo "==> Staging IPA Payload..."
mkdir -p "$BUILD_DIR/Payload"
cp -R "$APP_PATH" "$BUILD_DIR/Payload/AppVault.app"

echo "==> Signing with TrollStore entitlements..."
if command -v ldid >/dev/null 2>&1; then
    ldid -S"$ROOT_DIR/Resources/entitlements.plist" "$BUILD_DIR/Payload/AppVault.app/AppVault"
fi

mkdir -p "$OUTPUT_DIR"
cd "$BUILD_DIR"

echo "==> Packaging .ipa and .tipa..."
zip -q -r9 "$OUTPUT_DIR/AppVault.ipa" Payload
cp "$OUTPUT_DIR/AppVault.ipa" "$OUTPUT_DIR/AppVault.tipa"

echo "==> Packaging complete:"
ls -lh "$OUTPUT_DIR/AppVault.ipa" "$OUTPUT_DIR/AppVault.tipa"

rm -rf "$BUILD_DIR"
echo "==> Build successful!"
