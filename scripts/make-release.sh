#!/usr/bin/env bash
# Build a universal (Apple Silicon + Intel) Release "Genius Typer.app", sign it and pack it into
# build/release/GeniusTyper-<version>.dmg (the app and a link to /Applications) and a .zip (what
# the in-app updater downloads), plus SHA256SUMS. Used by .github/workflows/release.yml; works
# locally too. GENIUSTYPER_SIGN_IDENTITY names the signing certificate (CI: the release
# certificate imported from the repository secrets); without it the app stays ad-hoc signed and
# cannot update itself.
set -euo pipefail
cd "$(dirname "$0")/.."

version=$(sed -nE 's/^ *MARKETING_VERSION: *"?([0-9.]+)"?.*/\1/p' project.yml)
app="build/dd-release/Build/Products/Release/Genius Typer.app"
out=build/release
rm -rf build/dd-release "$out"
mkdir -p "$out"

xcodegen generate -q
xcodebuild -project GeniusTyper.xcodeproj -scheme GeniusTyper -configuration Release \
  -derivedDataPath build/dd-release ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build -quiet
lipo -info "$app/Contents/MacOS/Genius Typer" "$app/Contents/MacOS/GeniusTyperEngine"

if [ -n "${GENIUSTYPER_SIGN_IDENTITY:-}" ]; then
  # A stable certificate: macOS ties Input Monitoring / Accessibility / the microphone to it, so
  # they survive updates, and the updater only installs a copy signed with the same certificate.
  # Inside out (not --deep, which Apple deprecates): SQLCipher, the engine helper, then the app.
  codesign --force -s "$GENIUSTYPER_SIGN_IDENTITY" "$app/Contents/Frameworks/SQLCipher.framework"
  codesign --force -s "$GENIUSTYPER_SIGN_IDENTITY" -i com.dmemruk.GeniusTyperEngine "$app/Contents/MacOS/GeniusTyperEngine"
  codesign --force -s "$GENIUSTYPER_SIGN_IDENTITY" "$app"
  codesign --verify --deep --strict "$app"
  codesign -d -r- "$app" 2>&1 | sed -n 's/^designated => /designated requirement: /p'
else
  echo "warning: GENIUSTYPER_SIGN_IDENTITY not set; the release stays ad-hoc signed" >&2
fi

ditto -c -k --keepParent "$app" "$out/GeniusTyper-$version.zip"
stage=$(mktemp -d)
ditto "$app" "$stage/Genius Typer.app"
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -volname "Genius Typer $version" -srcfolder "$stage" -format UDZO \
  -fs HFS+ "$out/GeniusTyper-$version.dmg"
rm -rf "$stage"
# The build copy would show up as another Genius Typer in Launchpad / Spotlight (and confuse the
# permissions, which go by bundle ID).
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -u "$PWD/$app" 2>/dev/null || true
rm -rf "$app"
(cd "$out" && shasum -a 256 GeniusTyper-* | tee SHA256SUMS)
