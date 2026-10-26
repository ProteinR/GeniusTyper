#!/usr/bin/env bash
# Build Genius Typer (ad-hoc signed) and install it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="Genius Typer"
PRODUCT="build/dd/Build/Products/Release/$APP.app"
xcodegen generate -q
xcodebuild -project GeniusTyper.xcodeproj -scheme GeniusTyper -configuration Release \
  -derivedDataPath build/dd build -quiet
# Re-sign with a stable local certificate. Its designated requirement is the certificate, not the
# build hash, so the Input Monitoring permission survives rebuilds.
# GENIUSTYPER_SIGN_IDENTITY names it; else the first of the usual names found (README: how to make one).
IDENTITY="${GENIUSTYPER_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  for name in "Genius Typer Local Code Signing" "dmemruk Local Code Signing"; do
    if security find-certificate -c "$name" >/dev/null 2>&1; then IDENTITY="$name"; break; fi
  done
fi
if [ -n "$IDENTITY" ] && security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  # PROFILE=1: also allow attaching tools (leaks, Instruments allocations); same certificate, so
  # the permissions stay.
  if [ "${PROFILE:-0}" = "1" ]; then
    codesign --force --deep -s "$IDENTITY" --entitlements scripts/profile.entitlements "$PRODUCT"
  else
    codesign --force --deep -s "$IDENTITY" "$PRODUCT"
  fi
else
  echo "warning: no signing certificate found (set GENIUSTYPER_SIGN_IDENTITY, see README); app stays ad-hoc signed and permissions reset on every rebuild" >&2
fi
# Quit gracefully; kill only if it does not quit in time.
if pgrep -qx "$APP"; then
  osascript -e 'tell application id "com.dmemruk.GeniusTyper" to quit' >/dev/null 2>&1 || true
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
# The rest of the build (~300 MB of intermediates and caches) is not needed once installed.
# KEEP_BUILD=1 keeps it for quick rebuilds while iterating.
[ "${KEEP_BUILD:-0}" = "1" ] || rm -rf build
open "$HOME/Applications/$APP.app"
echo "Installed ~/Applications/$APP.app"
