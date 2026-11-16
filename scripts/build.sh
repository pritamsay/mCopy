#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
BUILD_ROOT="$PROJECT_ROOT/.build/universal"
MODULE_CACHE="$PROJECT_ROOT/.build/module-cache"
APP_PATH="$PROJECT_ROOT/dist/myCopy.app"
EXTENSION_PATH="$APP_PATH/Contents/PlugIns/MyCopyFinder.appex"
mkdir -p "$BUILD_ROOT" "$MODULE_CACHE"

for MCOPY_ARCH in arm64 x86_64; do
    ARCH_PATH="$BUILD_ROOT/$MCOPY_ARCH"
    mkdir -p "$ARCH_PATH"
    xcrun swiftc -O -whole-module-optimization -swift-version 5 \
        -target "$MCOPY_ARCH-apple-macos13.0" -module-cache-path "$MODULE_CACHE" \
        -parse-as-library -emit-library -static -emit-module -module-name MoverCore \
        Sources/MoverCore/*.swift \
        -emit-module-path "$ARCH_PATH/MoverCore.swiftmodule" -o "$ARCH_PATH/libMoverCore.a"
    xcrun swiftc -O -whole-module-optimization -swift-version 5 \
        -target "$MCOPY_ARCH-apple-macos13.0" -module-cache-path "$MODULE_CACHE" \
        -I "$ARCH_PATH" -L "$ARCH_PATH" -lMoverCore \
        Sources/myCopy/*.swift -o "$ARCH_PATH/myCopy"
    xcrun swiftc -O -whole-module-optimization -swift-version 5 \
        -target "$MCOPY_ARCH-apple-macos13.0" -module-cache-path "$MODULE_CACHE" \
        -application-extension -parse-as-library -module-name MyCopyFinder \
        -framework AppKit -framework FinderSync -Xlinker -e -Xlinker _NSExtensionMain \
        Sources/MoverCore/FinderClipboard.swift Sources/MoverCore/FinderMenu.swift \
        FinderExtension/MyCopyFinderSync.swift -o "$ARCH_PATH/MyCopyFinder"
done

rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$EXTENSION_PATH/Contents/MacOS"
xcrun lipo -create "$BUILD_ROOT/arm64/myCopy" "$BUILD_ROOT/x86_64/myCopy" -output "$APP_PATH/Contents/MacOS/myCopy"
xcrun lipo -create "$BUILD_ROOT/arm64/MyCopyFinder" "$BUILD_ROOT/x86_64/MyCopyFinder" -output "$EXTENSION_PATH/Contents/MacOS/MyCopyFinder"
cp Resources/App-Info.plist "$APP_PATH/Contents/Info.plist"
cp Resources/Finder-Info.plist "$EXTENSION_PATH/Contents/Info.plist"
/usr/bin/codesign --force --sign - --entitlements Resources/Finder.entitlements "$EXTENSION_PATH"
/usr/bin/codesign --force --sign - "$APP_PATH"
/usr/bin/codesign --verify --deep --strict "$APP_PATH"
print "Built universal app: $APP_PATH"
