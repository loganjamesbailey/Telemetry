#!/bin/sh
set -euo pipefail
APP="$BUILT_PRODUCTS_DIR/$FULL_PRODUCT_NAME"
mkdir -p "$APP/Contents/Library/LaunchDaemons"
cp "$BUILT_PRODUCTS_DIR/TelemetryHelper" "$APP/Contents/MacOS/TelemetryHelper"
cp "$SRCROOT/Helper/com.jamesbailey.telemetry.helper.plist" "$APP/Contents/Library/LaunchDaemons/"

