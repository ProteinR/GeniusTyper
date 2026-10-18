# Genius Switcher: agent guide

App `~/Applications/Genius Switcher.app`, bundle ID `com.dmemruk.GeniusSwitcher`, module and folder
`GeniusSwitcher` (renamed from "Switcher" on 2026-10-18; journal and settings were moved over).

Personal macOS menu bar app replacing **Caramba Switcher** (automatic RU/EN layout fixing). It
fixes words typed in the wrong layout and keeps a text-free journal of how the owner types and
switches, so the detector can be improved on real data. Layouts: ABC + RussianWin.
Icon: `scripts/make-icon.swift`: the "Genius" meme face (`scripts/genius.png`) in a red "no" sign — no more gibberish — plus keycaps "A" / "Я".

## What it does now

- **Caps Lock switches the layout** instantly on every press (`CapsLockSwitch.swift`): Caps Lock is
  remapped to F18 with `hidutil` (session only, removed on quit), F18 in the key tap selects the other
  layout with `TISSelectInputSource`. ⇧ + Caps Lock toggles the real Caps Lock.
- **Auto-fix** (`AutoFixer.swift`, Accessibility permission): after a space or punctuation (not
  Enter), a word with verdict `fix` on all its keys is erased and typed in the other layout, and the
  layout is switched. Caps Lock right after it (no key in between, 5 s) undoes it and adds the word
  to exceptions (SHA-256 of the key codes, no text). Off by default in terminals and code editors,
  per-app switch in the panel. Genius Switcher's own events carry a marker and are ignored by the tap.
- **Watches typing, listen-only** (`Observer.swift`, Input Monitoring permission). Clicks, arrows, ⌘/⌃ shortcuts and app switches reset the tracked line.
- `WordTracker.swift` (pure, tested): keys → finished words and *rewrites* (erase, then retype).
  Words are kept as physical keys, so "ghbdtn" and "привет" are the same keys in two layouts.
  The layout of each key is the selected input source at that moment. Not the character in the
  event: after Genius Switcher switches the layout itself, events keep carrying characters of the old
  layout while the app types in the new one (2026-10-18: "hello" typed in Russian was judged English).
- `Detector.swift`: detector v0: macOS spell checking in both layouts plus a script
  check (the Russian checker accepts Latin "ok"/"git"). Verdicts: keep / fix / ambiguous / unknown /
  skip.
- `Recorder.swift`: tracker output → journal entries; a manual wrong-layout fix = rewrite with a
  layout change and the same keys retyped (full or prefix). Words flagged "fix" but left alone for
  20 s count as detector false alarms.

## Privacy rule

The journal never contains text: only layouts, lengths, verdicts, timings and the app bundle ID
(`JournalEntry`; a test checks that words do not reach the JSON). Letters exist only in memory while
a word is typed; the menu shows the last 5 fixes as text from memory only. Password managers are
excluded by default, plus "Не следить в «…»" per app. Secure Input fields are invisible to the tap.

Journal: `~/Library/Application Support/GeniusSwitcher/journal/YYYY-MM-DD.jsonl`, 90 days.
Log: `~/Library/Logs/GeniusSwitcher/geniusswitcher.log`.

## Next

Analyse the journal (how often, which apps, early vs late fixes, auto-fixes undone, detector
caught/missed/false alarms by word length) and improve the detector (letter trigrams); fixing
mid-word; manual exceptions; a "convert last word / selection" hotkey; later possibly merge
Genius Switcher, MonitorCtl and a clipboard history into one app.

The panel shows today or the last 7 days (stats are per day; after midnight "today" starts empty).
Right click on the menu bar icon: auto-fix, pause, quit.

Build and install: `scripts/install.sh`. Tests: `scripts/test.sh` (also removes the Debug app afterwards: a second copy with the same bundle ID steals the permissions).
