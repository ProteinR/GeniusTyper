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
  layout with `TISSelectInputSource`. F18 is swallowed by a small filtering tap (needs
  Accessibility): apps beeped at it on every press (2026-10-19). ⇧ + Caps Lock toggles the real Caps Lock. One rule: Caps Lock
  makes the text be in the other layout. Right after an auto-fix it undoes it; in the middle of a
  word (letters typed, no separator yet) it retypes those letters in the other layout and switches
  (`retypeCurrentWord`, journal `capsFix`), the word goes on as one word; otherwise it only switches.
  Competitors use double Shift for "convert last word"; not added (2026-10-19): Caps Lock covers it,
  only "noticed after the space" is left, add double Shift if the journal shows that often.
- **Auto-fix** (`AutoFixer.swift`, Accessibility permission): after a space or punctuation (not
  Enter), a word with verdict `fix` on all its keys is erased and typed in the other layout, and the
  layout is switched. ⇧+Space ends a word without fixing it (journal `autoSkip`). Caps Lock right
  after a fix (no key in between, 5 s) undoes it. Undo, or ⇧+Space twice for the same word
  (`SkipCounter`, memory only), shows `ExceptionSuggestion`: a non-activating panel in the top right
  ("«rtl» — в исключения?", hides after 8 s, never takes the focus). Off by default in terminals and
  code editors. Genius Switcher's own events carry a marker and are ignored by the tap.
- **Exceptions window** (`ExceptionsEditor.swift`; panel "Изменить…", right-click "Исключения…"):
  tab "Слова" = `UserExceptions`, words as typed, never fixed, stored as text in the settings
  (`userExceptions`), never in the journal; seeded on 2026-10-18 with INVENTIRE abbreviations the
  detector would fix (rtl, ctx, deps…; 2-letter ones and ones whose Russian side is a common word,
  dfc = «вас», left out). Tab "Приложения": "Не исправлять в" (`autoOffApps`) and "Не следить в"
  (`excludedApps`), added from the current app, running apps or Finder. Older undos (before 0.3.0)
  added hashes of the key codes (`FixExceptions`, no text): still honoured, "Сбросить" clears them.
- **Watches typing, listen-only** (`Observer.swift`, Input Monitoring permission). Clicks, arrows, ⌘/⌃ shortcuts and app switches reset the tracked line.
- `WordTracker.swift` (pure, tested): keys → finished words and *rewrites* (erase, then retype).
  Words are kept as physical keys, so "ghbdtn" and "привет" are the same keys in two layouts.
  The layout of each key is the selected input source at that moment. Not the character in the
  event: after Genius Switcher switches the layout itself, events keep carrying characters of the old
  layout while the app types in the new one (2026-10-18: "hello" typed in Russian was judged English).
- `Detector.swift`: detector v0: macOS spell checking in both layouts plus a script
  check (the Russian checker accepts Latin "ok"/"git"). All-caps words of 2–5 letters (RTL, API)
  are abbreviations: skipped. It is a dictionary, not a model: words missing from it are "unknown"
  (letter n-grams are the planned next step, after real journal data; journal before 2026-10-20 is
  mostly the owner's testing). Verdicts: keep / fix / ambiguous / unknown /
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

The panel is kept short on purpose (compared with Caramba / Lang Switcher, which have almost no
settings): auto-fix, "Исправлять в «app»", Caps Lock, pause, a 3-line key hint, buttons
"Исключения…", "Статистика…", "Выйти", and login item / menu bar icon. `StatsWindow.swift`: today or
the last 7 days (per day; after midnight "today" starts empty), last fixes, journal open/delete.
Right click on the menu bar icon: auto-fix, pause, exceptions, statistics, quit.

Build and install: `scripts/install.sh`. Tests: `scripts/test.sh` (also removes the Debug app afterwards: a second copy with the same bundle ID steals the permissions).

## Menu bar icon

`StatusItemController.swift` (the same file in Genius Switcher and MonitorCtl): left click = panel,
right click = menu with "Завершить". Not SwiftUI's `MenuBarExtra`: when the icon is turned off in
System Settings → Menu Bar, a `MenuBarExtra`-only app quits right after launch (MonitorCtl did, so
its keys silently stopped working, and the unit tests' host quit too). With an `NSStatusItem` the
app keeps running; opening it again from Spotlight/Finder shows the panel in a small window.

Genius Switcher's icon is drawn in code (`AppDelegate.menuBarImage`): "G" with a text cursor (it
was SF Symbols' "A" with a cursor). Panel "Язык на значке: нет / RU / EN / флаг" + "с иконкой"
(`MenuBarIcon.LanguageMark`, `showsSymbol`): with the icon the language is small at its right
(text ~10.5 pt in the image; a flag is a 14 pt title, emoji flags look smaller than text), without
it the language is the whole icon ("RU" in a frame, or a flag). Meant to replace macOS's own input
menu (System Settings → Keyboard → Input Sources).

## Versions

Every fix or feature bumps the version (`project.yml`). The pre-commit hook
(`scripts/git-hooks/pre-commit`; enable once per clone: `git config core.hooksPath scripts/git-hooks`)
does it when a commit touches the app: `CURRENT_PROJECT_VERSION` +1 and the patch (0.1.0 → 0.1.1).
For a new feature bump the minor by hand before committing (`MARKETING_VERSION: "0.2.0"`); the hook
keeps a hand-made bump. The version is shown next to the title in the panel; the log's launch line
also has the build number.
