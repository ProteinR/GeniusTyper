# Diktant: agent guide

Personal macOS menu bar app replacing **TypeWhisper** (voice dictation): only the features the
owner uses. Swift, xcodegen (`project.yml`), ad-hoc signed and re-signed with the local certificate
"dmemruk Local Code Signing", installed to `~/Applications` by `scripts/install.sh`, bundle ID
`com.dmemruk.Diktant`, UI in Russian. Same conventions as the other own apps (see `../AGENTS.md`).
Local git only. Started 2026-10-26.

## What it does

- **Dictation key** (`Shortcut`, `HotkeyMonitor`): right ⌥ by default, changeable in settings
  ("Изменить": a modifier pressed and released alone — right/left ⌥ ⌘ ⌃ ⇧, Fn — a key with ⌃/⌥/⌘,
  or an F-key alone; F18 is excluded, it is Caps Lock in Genius Switcher). Stored as a key code, so
  layout-independent. **Hybrid** (`HybridPress`, tested): hold = push-to-talk, release stops; a tap
  (< 0.35 s) = toggle, the next press stops. A single modifier is watched by an event tap on
  modifier changes only; a combination is a Carbon hot key (no tap). Every key is watched only while
  recording: Esc cancels (switch, swallowed), another key or modifier while the dictation modifier
  is held cancels silently (it was ⌥+key). Start sound and pill come 0.15 s late for that reason.
- **Recording** (`AudioRecorder`): default microphone via `AVAudioEngine`, converted to 16 kHz
  mono; the engine exists only while recording. Shorter than 0.3 s is dropped.
- **Engines**: local **Parakeet TDT 0.6B v3** (NVIDIA, FluidAudio 0.17.7, CoreML on the Neural
  Engine, 25 European languages with automatic detection; RU/EN is what matters) and cloud ones via
  the OpenAI-compatible `/audio/transcriptions` (Groq `whisper-large-v3-turbo`, OpenAI
  `gpt-4o-transcribe`, "Другой сервис" with its own address); keys in the login Keychain
  (`Keychain`). Not used yet beyond the code; the owner may want Groq/OpenAI later.
- **The model runs in a helper process** `Contents/MacOS/DiktantEngine` (`DiktantEngine/main.swift`;
  only it links FluidAudio). Diktant starts it when recording starts (the model loads in ~0.2 s
  while the user speaks), sends samples over stdin, reads JSON lines from stdout, and closes its
  stdin after `Prefs.unloadAfterMinutes` (default 5; 1/5/15/60/never) without dictation, so it
  exits. Why: loading the model in-process left ~30 MB of fragmented malloc memory that
  `malloc_zone_pressure_relief` could not give back (54 MB idle forever after the first
  dictation, `PROFILING.md`). The helper also downloads the model (`download` mode, ~470 MB into
  `~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3`, started automatically on
  first launch). The first load ever compiles the model for the Neural Engine (one-time, >10 s;
  cached by macOS in `~/Library/Caches/com.apple.e5rt.e5bundlecache`, survives rebuilds).
- **Paste** (`Paster`): text to the clipboard marked `org.nspasteboard.TransientType` (Genius
  Switcher's clipboard history skips it), ⌘V posted, previous clipboard restored after 0.6 s unless
  something else was copied. Needs Accessibility (the key taps need it too); without it the text
  stays on the clipboard and the pill says so.
- **Indicator** (`Indicator`): TypeWhisper's "Overlay" + "Classic": dark pill at the bottom centre
  of the screen with the pointer: red dot, timer, 5 level bars; "Распознаю…"; short messages
  (no model, no key, nothing recognised). AppKit-drawn `NSPanel`, built on show, released on hide.
- **History** (`History`, SQLite `~/Library/Application Support/Diktant/history.sqlite`): text
  only (no audio), forever: date, text, words, duration, app, model. Paged from disk, Cyrillic
  case-insensitive search (`lower_ru`), copy, delete.
- **Statistics**: week / month / all time: words, dictations, words per minute, time saved (typing
  at 45 wpm minus speaking time — TypeWhisper's figure), words per day, by app, by model; all
  totals computed by SQLite.
- **Settings window** (`SettingsWindow`): Основное (key, sounds, Esc, permissions when missing,
  launch at login, app language), Модель, История, Статистика. Built on open, released on close.
- **Menu bar icon** (`StatusItemController`): mic; red mic.fill while recording; left click opens
  settings, right click: Настройки…, История…, Завершить Diktant.
- **App language**: architecture only. Strings go through `String(localized:)` /
  `LocalizedStringKey`; `Localizable.xcstrings` (source ru) is still empty: Xcode fills it with the
  strings when the project is built in the IDE (xcodebuild does not). To add English,
  translate there, add "en" to `CFBundleLocalizations` and enable the menu item (MeetRec's
  `AppLanguage` shows the restart flow).

Not needed (TypeWhisper features left out on purpose): workflows, logins, file transcription,
recorder, speakers, dictionary, snippets, translation, sync, plugins.

## Memory and CPU (measured 2026-10-26, details in `PROFILING.md`)

| | Memory | CPU idle |
|---|---|---|
| TypeWhisper | ~113 MB + widget ~30 MB | — |
| Diktant idle | 15 MB, 0 wake-ups | 0.0 % |
| Settings window open | ~32 MB | |
| Dictating (model loaded) | ~17 MB + DiktantEngine ~36 MB | |

Rules kept: nothing polls (one-shot unload timer, timers only while the pill is shown); no Swift
Charts / `Canvas` / system `Toggle` (`LightSwitchStyle`), plain-shape bars, `Menu` not `Picker`,
`sizingOptions` off; `Memory.giveBackSoon()` after windows and dictations.

## Checks

- `scripts/test.sh`: unit tests (hybrid key, shortcuts, word count, history and statistics, WAV).
- `--transcribe-file <audio>`: transcribes a file with the current engine twice, logs text, time,
  footprint of Diktant and the helper (`say -v Milena -o ru.aiff "…"` for Russian speech).
- `--stress-test`: three rounds of every settings page plus load/transcribe/unload of the model,
  footprint after each step; growing every round = a leak.
- `--open-settings [general|model|history|statistics]`: for screenshots.
- `PROFILE=1 scripts/install.sh`: signs with get-task-allow for `heap`/`leaks`/`vmmap`.
- Log: `~/Library/Logs/Diktant/diktant.log` (debug lines with `verboseLog` or any `--…-test`).

Build and install: `scripts/install.sh` (deletes `build/` afterwards; `KEEP_BUILD=1` keeps it).
Icon: `scripts/make-icon.swift`. Sounds: start = system Tink, text pasted = own single soft
sine tap at 740 Hz `Diktant/Sounds/success.wav` (`scripts/make-sounds.swift`, in the spirit of
Claude's voice-mode sounds; a brighter C6 bell with overtones was too sharp for the owner, and
system Pop sounded like a failure, so Pop now means nothing recognised / error), Esc = Funk. Version bumped by the pre-commit hook
(`git config core.hooksPath scripts/git-hooks`).
