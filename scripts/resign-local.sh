#!/bin/bash
# Re-sign a local VoiceInk.app with a stable self-signed identity so that
# Accessibility / Input Monitoring (TCC) grants persist across rebuilds.
#
# Why this is needed:
#   - `make local` lets xcodebuild fall back to ad-hoc signing (the self-signed
#     cert is not policy-"valid", so xcodebuild ignores it). Ad-hoc gives a new
#     code identity every build, so macOS treats each rebuild as a new app and
#     drops its TCC permissions.
#   - A stable cert pins the code's Designated Requirement to the cert hash, so
#     the granted permission survives rebuilds.
#
# It also strips Backblaze placeholder symlinks (.BC.D_*) that get injected into
# the embedded frameworks and break the code seal ("unsealed contents present in
# the root directory of an embedded framework").
#
# Usage: scripts/resign-local.sh <APP_PATH> <ENTITLEMENTS> <IDENTITY>
set -euo pipefail

APP="${1:?app path required}"
ENT="${2:?entitlements path required}"
ID="${3:?signing identity required}"

if [ ! -d "$APP" ]; then
    echo "App not found: $APP" >&2
    exit 1
fi

echo "Stripping Backblaze placeholder symlinks (.BC.D_*)..."
find "$APP" -name ".BC.D_*" -type l -delete 2>/dev/null || true

sign() { codesign --force --sign "$ID" --timestamp=none "$1" >/dev/null 2>&1 && echo "  signed $(basename "$1")"; }

echo "Signing nested code (inside-out) with '$ID'..."
# Sparkle auto-updater pieces (version dir may be B)
SP_BASE="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SP_BASE" ]; then
    SP_VER="$(/bin/ls "$SP_BASE/Versions" 2>/dev/null | grep -E '^[A-Z]$' | head -1)"
    SP="$SP_BASE/Versions/$SP_VER"
    for x in "$SP/XPCServices/Downloader.xpc" "$SP/XPCServices/Installer.xpc" \
             "$SP/Updater.app" "$SP/Autoupdate"; do
        [ -e "$x" ] && sign "$x"
    done
fi

# Embedded frameworks
for fw in "$APP"/Contents/Frameworks/*.framework; do
    [ -d "$fw" ] && sign "$fw"
done

# Embedded dylibs alongside the main executable
for dl in "$APP"/Contents/MacOS/*.dylib; do
    [ -e "$dl" ] && sign "$dl"
done

echo "Signing main app bundle..."
codesign --force --sign "$ID" --timestamp=none --entitlements "$ENT" "$APP"

echo "Verifying..."
codesign --verify --deep --strict "$APP"
echo "Re-signed OK with identity '$ID'."
echo "Designated Requirement:"
codesign -d -r- "$APP" 2>&1 | grep -i designated || true
