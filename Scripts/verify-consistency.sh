#!/bin/bash
# The five strings that must agree or launchd fails with status 78:
#   1. daemon plist Label
#   2. daemon plist filename
#   3. MachServices key in the plist
#   4. BundleProgram path in the plist
#   5. the constants in TelemetryShared/HelperProtocol.swift
set -euo pipefail
cd "$(dirname "$0")/.."

PLIST="Helper/com.jamesbailey.telemetry.helper.plist"
SHARED="Packages/TelemetryCore/Sources/TelemetryShared/HelperProtocol.swift"
FAIL=0

check() {
    if [ "$2" != "$3" ]; then
        echo "MISMATCH $1: '$2' vs '$3'" >&2
        FAIL=1
    else
        echo "ok  $1 = $2"
    fi
}

label=$(/usr/libexec/PlistBuddy -c "Print :Label" "$PLIST")
mach=$(/usr/libexec/PlistBuddy -c "Print :MachServices" "$PLIST" | sed -n 's/^ *\([a-z0-9.]*\) = .*/\1/p' | head -1)
program=$(/usr/libexec/PlistBuddy -c "Print :BundleProgram" "$PLIST")
assoc=$(/usr/libexec/PlistBuddy -c "Print :AssociatedBundleIdentifiers:0" "$PLIST")

shared_helper_id=$(grep 'helperBundleID = ' "$SHARED" | sed 's/.*"\(.*\)".*/\1/')
shared_mach=$(grep 'machServiceName = ' "$SHARED" | sed 's/.*"\(.*\)".*/\1/')
shared_plist=$(grep 'plistName = ' "$SHARED" | sed 's/.*"\(.*\)".*/\1/')
shared_app_id=$(grep 'appBundleID = ' "$SHARED" | sed 's/.*"\(.*\)".*/\1/')

check "plist filename vs shared plistName" "$(basename "$PLIST")" "$shared_plist"
check "Label vs shared helperBundleID" "$label" "$shared_helper_id"
check "MachServices vs shared machServiceName" "$mach" "$shared_mach"
check "AssociatedBundleIdentifiers vs shared appBundleID" "$assoc" "$shared_app_id"
check "BundleProgram" "$program" "Contents/MacOS/TelemetryHelper"

grep -q "PRODUCT_BUNDLE_IDENTIFIER: $shared_helper_id" project.yml \
    && echo "ok  helper target bundle id" \
    || { echo "MISMATCH: helper PRODUCT_BUNDLE_IDENTIFIER in project.yml" >&2; FAIL=1; }
grep -q "PRODUCT_BUNDLE_IDENTIFIER: $shared_app_id" project.yml \
    && echo "ok  app target bundle id" \
    || { echo "MISMATCH: app PRODUCT_BUNDLE_IDENTIFIER in project.yml" >&2; FAIL=1; }

exit $FAIL
