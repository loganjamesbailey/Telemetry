#!/bin/bash
# FALLBACK ONLY — use when SMAppService refuses to register the daemon
# (the macOS 26 SDK notes that apps containing LaunchDaemons "must be
# notarized"; development-signed local registration is widely reported to work,
# but if it does not on some OS build, this installs the same daemon the
# classic way).
#
# Run with:  sudo Scripts/daemon-fallback-install.sh [--uninstall]
#
# The Mach service name, XPC protocol, and code-signing checks are identical to
# the SMAppService path, so the app works the same either way.
set -euo pipefail

LABEL="com.jamesbailey.telemetry.helper"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
APP="/Applications/Telemetry.app"

[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }

if [ "${1:-}" = "--uninstall" ]; then
    launchctl bootout system "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    echo "daemon uninstalled"
    exit 0
fi

[ -x "$APP/Contents/MacOS/TelemetryHelper" ] || {
    echo "install the app to /Applications first (Scripts/install-local.sh)" >&2
    exit 1
}

# Same label and Mach service; Program instead of BundleProgram because this
# plist lives outside the app bundle.
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>Program</key>
    <string>$APP/Contents/MacOS/TelemetryHelper</string>
    <key>MachServices</key>
    <dict>
        <key>$LABEL.xpc</key>
        <true/>
    </dict>
</dict>
</plist>
EOF
chown root:wheel "$PLIST"
chmod 644 "$PLIST"

launchctl bootout system "$PLIST" 2>/dev/null || true
launchctl bootstrap system "$PLIST"
echo "daemon bootstrapped; verify with: sudo launchctl print system/$LABEL | head -20"
