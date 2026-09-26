#!/bin/sh
# build.sh — compile the Catalyst Silex host renderer.
set -e
D=$(dirname "$0")
SDK=$(xcrun --show-sdk-path)
xcrun clang -target arm64e-apple-ios18.0-macabi -isysroot "$SDK" \
  -F "$SDK/System/iOSSupport/System/Library/Frameworks" \
  -fobjc-arc -framework Foundation -framework UIKit -framework CoreGraphics -framework ImageIO \
  -o "$D/render" "$D/render.m" 2>&1 | grep -E 'error' || true
file "$D/render"
