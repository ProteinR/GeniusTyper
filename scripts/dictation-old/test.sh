#!/usr/bin/env bash
# Run the unit tests, then remove the Debug app they need as a host: an ad-hoc signed second copy
# with the same bundle ID confuses macOS permissions (Accessibility / Microphone end up
# attached to it instead of ~/Applications/Diktant.app).
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate -q
status=0
xcodebuild -project Diktant.xcodeproj -scheme Diktant -derivedDataPath build/dd test -quiet || status=$?
DEBUG_APP="build/dd/Build/Products/Debug/Diktant.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u "$PWD/$DEBUG_APP" 2>/dev/null || true
rm -rf "$DEBUG_APP"
[ "${KEEP_BUILD:-0}" = "1" ] || rm -rf build
exit $status
