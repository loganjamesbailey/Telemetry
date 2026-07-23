#!/bin/bash
# Build, sign (Developer ID), notarize, staple, and package a release.
#
# One-time prerequisites (both are yours to do, not an agent's):
#   1. Developer ID Application certificate in the keychain:
#      Xcode → Settings → Accounts → team → Manage Certificates → +
#      → "Developer ID Application"
#   2. Notary credentials stored in the keychain (prompts for an
#      app-specific password from account.apple.com — the password goes
#      straight into Apple's tool):
#      xcrun notarytool store-credentials telemetry-notary \
#          --apple-id <your-apple-id> --team-id GA9YBC44ZN
#
# Then:  ./Scripts/release.sh [--publish]
#   --publish  also attaches the artifact to the GitHub release for the
#              current version tag (creates the release if needed).
set -euo pipefail
cd "$(dirname "$0")/.."

NOTARY_PROFILE="telemetry-notary"
VERSION=$(sed -n 's/.*MARKETING_VERSION: "\(.*\)"/\1/p' project.yml | head -1)
ARTIFACT="Telemetry-${VERSION}.zip"

# ── Preflight ────────────────────────────────────────────────────────────────
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    echo "✗ No 'Developer ID Application' certificate in the keychain." >&2
    echo "  Create one: Xcode → Settings → Accounts → Manage Certificates → +" >&2
    exit 1
fi
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "✗ Notary profile '$NOTARY_PROFILE' not found." >&2
    echo "  Store it (uses an app-specific password from account.apple.com):" >&2
    echo "  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <apple-id> --team-id GA9YBC44ZN" >&2
    exit 1
fi

# ── Build, signed for distribution ───────────────────────────────────────────
xcodegen generate
xcodebuild -project Telemetry.xcodeproj -scheme Telemetry -configuration Release \
    -derivedDataPath .build-release \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    build | grep -E "error:|BUILD" || true

APP=".build-release/Build/Products/Release/Telemetry.app"
[ -d "$APP" ] || { echo "build failed" >&2; exit 1; }

# The daemon must carry the same identity as the app (SMAppService rule),
# and notarization requires hardened runtime + secure timestamps throughout.
codesign --verify --deep --strict "$APP"
for bin in "$APP" "$APP/Contents/MacOS/TelemetryHelper" "$APP/Contents/PlugIns/TelemetryWidget.appex"; do
    codesign -dvv "$bin" 2>&1 | grep -q "Authority=Developer ID Application" \
        || { echo "✗ $bin is not Developer ID signed" >&2; exit 1; }
done
echo "✓ Developer ID signatures verified"

# ── Notarize & staple ────────────────────────────────────────────────────────
STAGE=$(mktemp -d)
ditto -c -k --keepParent "$APP" "$STAGE/notarize.zip"
echo "Submitting to Apple notary service (typically 1–5 min)..."
xcrun notarytool submit "$STAGE/notarize.zip" \
    --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"

# Gatekeeper's own verdict, not ours:
spctl --assess --type execute --verbose "$APP"
echo "✓ Notarized, stapled, and accepted by Gatekeeper"

# ── Package ──────────────────────────────────────────────────────────────────
rm -f "$ARTIFACT"
ditto -c -k --keepParent "$APP" "$ARTIFACT"
shasum -a 256 "$ARTIFACT"
echo "✓ $ARTIFACT ready"

# ── Publish (optional) ───────────────────────────────────────────────────────
if [ "${1:-}" = "--publish" ]; then
    TAG="v${VERSION}"
    if gh release view "$TAG" >/dev/null 2>&1; then
        gh release upload "$TAG" "$ARTIFACT" --clobber
    else
        gh release create "$TAG" "$ARTIFACT" \
            --title "Telemetry $TAG" \
            --notes "Notarized build. Download, unzip, drag to /Applications. Fan control needs one-time helper approval in System Settings → Login Items & Extensions."
    fi
    echo "✓ Published to GitHub release $TAG"
fi
