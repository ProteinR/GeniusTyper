# ProteinKit

Shared pieces of a few small native macOS menu bar apps (MeetRec, Genius Typer, …), so they look
and behave alike. SwiftUI/AppKit only, no dependencies. macOS 15+.

Contents (0.1.0):

- `LightSwitchStyle`, `LightSlider` — a switch and a slider drawn by SwiftUI. The system ones on
  macOS 26 take ~100 MB of graphics memory for a moment on first draw.
  `LightSwitchStyle(spreads: true)` puts the switch at the right edge of a form row.
- `AboutFooter(appName:)` — the version line with the author link at the bottom of the settings.
- `Links.author`, `AppInfo.version` / `.build`.

Strings are written in Russian (the source language) with English translations in
`Localizable.xcstrings`.

## Use in an app

ProteinKit is not published as its own repository. Each app keeps a copy in
`Vendor/ProteinKit`, made by `scripts/vendor.sh`, so the app builds from its own repository alone
(also on GitHub Actions):

```bash
scripts/vendor.sh ../MyApp           # copy the committed ProteinKit into ../MyApp/Vendor/ProteinKit
scripts/vendor.sh --check ../MyApp   # the copy still matches the commit it names?
```

```yaml
# the app's project.yml (XcodeGen)
packages:
  ProteinKit:
    path: Vendor/ProteinKit
targets:
  App:
    dependencies:
      - package: ProteinKit
```

A change reaches an app when the copy is refreshed there; until then the app keeps the version
named in `Vendor/ProteinKit/VENDORED`. The copy is never edited by hand.

## Tests

```bash
xcodebuild test -scheme ProteinKit -destination 'platform=macOS' -derivedDataPath .build/xcode
```

`swift test` runs too, but it does not compile `.xcstrings`, so the English-strings test fails
there.

MIT license.
