#!/usr/bin/env bash
# Build Genius Switcher (ad-hoc signed) and install it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="Genius Switcher"
PRODUCT="build/dd/Build/Products/Release/$APP.app"
xcodegen generate -q
xcodebuild -project GeniusSwitcher.xcodeproj -scheme GeniusSwitcher -configuration Release \
  -derivedDataPath build/dd build -quiet
# Re-sign with the stable local certificate (the one MeetRec uses). Its designated requirement is the
# certificate, not the build hash, so the Input Monitoring permission survives rebuilds.
IDENTITY="dmemruk Local Code Signing"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  # PROFILE=1: also allow attaching tools (leaks, Instruments allocations); same certificate, so
  # the permissions stay.
  if [ "${PROFILE:-0}" = "1" ]; then
    codesign --force --deep -s "$IDENTITY" --entitlements scripts/profile.entitlements "$PRODUCT"
  else
    codesign --force --deep -s "$IDENTITY" "$PRODUCT"
  fi
else
  echo "warning: certificate '$IDENTITY' not found; app stays ad-hoc signed and permissions reset on every rebuild" >&2
fi
# Quit gracefully; kill only if it does not quit in time.
if pgrep -qx "$APP"; then
  osascript -e 'tell application id "com.dmemruk.GeniusSwitcher" to quit' >/dev/null 2>&1 || true
fi
for _ in $(seq 1 50); do pgrep -qx "$APP" || break; sleep 0.2; done
pkill -x "$APP" 2>/dev/null || true
mkdir -p ~/Applications
rm -rf "$HOME/Applications/$APP.app"
ditto "$PRODUCT" "$HOME/Applications/$APP.app"
# The build copy would show up as a second copy in Launchpad / Spotlight: remove it.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u "$PWD/$PRODUCT" 2>/dev/null || true
rm -rf "$PRODUCT"
open "$HOME/Applications/$APP.app"
echo "Installed ~/Applications/$APP.app"
