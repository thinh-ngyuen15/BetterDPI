#!/bin/zsh
# Builds BetterDPI.app (universal) into ./build
set -euo pipefail
cd "$(dirname "$0")"
APP=build/BetterDPI.app
# Regenerate the app icon when logo.png changed (or the icon is missing).
if [[ ! -f Resources/AppIcon.icns || logo.png -nt Resources/AppIcon.icns ]]; then
  swift tools/make_icon.swift logo.png Resources
fi
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
for arch in arm64 x86_64; do
  clang -c -O2 -fobjc-arc -target $arch-apple-macos14.0 -ISources Sources/Private.m -o build/Private-$arch.o
  swiftc -O -swift-version 5 -target $arch-apple-macos14.0 \
    -import-objc-header Sources/Bridging.h \
    -framework AppKit -framework SwiftUI -framework CoreGraphics -framework ServiceManagement \
    -framework QuartzCore -framework Metal -framework MetalKit -framework CoreImage \
    -framework ScreenCaptureKit -framework IOKit -framework UniformTypeIdentifiers \
    Sources/*.swift build/Private-$arch.o -o build/BetterDPI-$arch
done
lipo -create build/BetterDPI-arm64 build/BetterDPI-x86_64 -output "$APP/Contents/MacOS/BetterDPI"
rm build/BetterDPI-arm64 build/BetterDPI-x86_64 build/Private-*.o
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "built $APP"
