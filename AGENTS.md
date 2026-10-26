# Genius Typer: agent guide

GitHub: ProteinR/GeniusTyper (private; was ProteinR/GeniusSwitcher). App `~/Applications/Genius Typer.app`,
bundle ID `com.dmemruk.GeniusTyper`, module and folder `GeniusTyper`.

Personal macOS menu bar app for everything about typing text: **Genius Switcher** (RU/EN layout
fixing, replaced Caramba Switcher; ё; clipboard history, replaced Maccy) and **Diktant** (voice
dictation, replaced TypeWhisper) merged into one on 2026-10-26: one icon, one login item, one set
of permissions (Input Monitoring, Accessibility, Microphone). Diktant's git history is merged in
(its sources are under `GeniusTyper/Dictation/`, the helper is `GeniusTyperEngine/`). History of
names: "Switcher" → "Genius Switcher" (2026-10-18) → "Genius Typer" (2026-10-26, new bundle ID).
Layouts: ABC + RussianWin.
Icon: `scripts/make-icon.swift`: the "Genius" meme face (`scripts/genius.png`) in a red "no" sign — no more gibberish — plus keycaps "A" / "Я".

**Migration** (`Migration.swift`, first launch only, flag `migratedFromSwitcherAndDiktant`): the
settings of `com.dmemruk.GeniusSwitcher` and `com.dmemruk.Diktant` are copied into
`com.dmemruk.GeniusTyper` (Diktant's `sounds` → `dictationSounds`, `shortcut` →
`dictationShortcut`; window frames and the icon position skipped), `Application Support/GeniusSwitcher/*`
into `Application Support/GeniusTyper/`, `Application Support/Diktant/*` into
`Application Support/GeniusTyper/dictation/` (copied, not moved), dictation stays on if Diktant was
used, and the app registers itself as a login item.

## Menu and settings (designed with the owner on 2026-10-26, from an interactive preview)

- **Left click** (`QuickPanel.swift`): a short menu-like panel under the icon, built on show and
  released on close. Rows only for parts that are on: "Голосовые из Telegram ›" (its column is
  open at once when the voices are on, so they start transcribing), "История диктовок ›" (column
  on hover, 0.3 s, like a submenu), "История буфера" (opens the history window); then
  **"Исправлять текст"** (= not paused: one switch instead of Genius Switcher's separate "Пауза",
  which confused the owner next to "Автоисправление") and under it "в «app in front»"
  (`autoOffApps`); "Клавиши не видны: защищённый ввод" while macOS Secure Input is on
  (`SecureInput.holder()`, checked on opening: key taps then get only modifiers, so Caps Lock,
  Esc and the auto-fix stop; loginwindow sometimes keeps it after the screen was locked, cure:
  lock and unlock, 2026-10-26); "Нужны разрешения" when one is missing; "Настройки…", "Завершить". Icon hidden:
  the panel opens at the top right (reopening the app from Spotlight/Finder).
- **Right click**: Исправлять текст, История буфера, История диктовок…, Настройки…, Завершить.
- **Settings window** (`SettingsWindow.swift`, `SettingsPages.swift`, `Dictation/DictationPage.swift`;
  built on open, released on close): Основное (login, icon and the language on it, all
  permissions with their state), Раскладка, Буфер обмена, Диктовка, История (dictations),
  Статистика (Печать = the journal numbers, `TypingStatsView`; Диктовка = `DictationStatsView`).
  **The rule**: Раскладка, Буфер обмена and Диктовка each start with their own switch
  (`ModuleSwitch`), everything under it is grey and inactive while it is off (`.active(_:)`), the
  sidebar has a green dot for the parts that are on. The model and its settings are inside
  Диктовка. "Переключать раскладку клавишей Caps Lock" is its own section in Раскладка and works
  even while fixing is off. Switches are `LightSwitchStyle` (the system one took ~100 MB of
  graphics memory), menus are `Menu`, segments are `Segments`, no `TabView`.

## What it does now

- **Caps Lock switches the layout** instantly on every press (`CapsLockSwitch.swift`): Caps Lock is
  remapped to F18 with `hidutil` (session only, removed on quit), F18 in the key tap selects the other
  layout with `TISSelectInputSource`. F18 is swallowed by a small filtering tap (needs
  Accessibility): apps beeped at it on every press (2026-10-19). ⇧ + Caps Lock toggles the real Caps Lock. One rule: Caps Lock
  makes the text be in the other layout. Right after an auto-fix it undoes it; in the middle of a
  word (letters typed, no separator yet) it retypes those letters in the other layout and switches
  (`retypeCurrentWord`, journal `capsFix`), the word goes on as one word, unless the letters already
  are a word as typed (detector `keep`: "пишут" + Caps Lock + ":" stays "пишут:", 2026-10-20);
  otherwise it only switches. **Caps Lock twice** (within 0.4 s, `convertPhrase`, journal
  `phraseFix`/`phraseUndo`): the tracked text since the last line break goes into the layout in
  which more of its words are words (`PhraseFix`; a tie, e.g. names only: the other layout of most
  keys); nothing to change → the second press is a plain one. Caps Lock right after undoes it.
  Competitors use double Shift or Pause for "convert last word"; Caps Lock covers it here.
- **Auto-fix** (`AutoFixer.swift`, Accessibility permission): after a space or punctuation (not
  Enter), a word with verdict `fix` on all its keys is erased and typed in the other layout, and the
  layout is switched. One-letter words right before it go along when they are not a word as typed
  and are one in the other layout (`OneLetterWords`: "z lfdfq" → "я давай", not "z давай"). ⇧+Space ends a word without fixing it (journal `autoSkip`). Caps Lock right
  after a fix (no key in between, 5 s) undoes it. Undo, or ⇧+Space twice for the same word
  (`SkipCounter`, memory only), shows `ExceptionSuggestion`: a non-activating panel in the top right
  ("«rtl» — в исключения?", hides after 8 s, never takes the focus). Off by default in terminals and
  code editors. Genius Typer's own events carry a marker and are ignored by the tap.
- **ё** (`Yoficator.swift`, as Caramba's "Ёфикатор"; panel "Ставить ё", on by default): after a
  space or punctuation a Russian word typed with е where ё is always right gets it ("еще" → "ещё",
  "Артем" → "Артём", "ЕЩЕ" → "ЕЩЁ"); also in words the auto-fix turns into Russian. Only the letters
  from the first ё on are retyped. Words with both spellings (все/всё, узнаем/узнаём) are never
  touched. Same rules as the auto-fix: not after Enter, ⇧+Space keeps the word, Caps Lock right
  after puts е back (journal `yoFix` / `yoUndo`) and offers the exceptions (a word there is never
  given ё), off in "Не исправлять в" apps. Dictionary `GeniusTyper/yo.txt`: eyo-kernel's
  `dictionary/safe.txt` (MIT, github.com/hcodes/eyo-kernel, licence in `yo-LICENSE.txt`) expanded
  by `scripts/make-yo-dictionary.py` into ~107 000 sorted forms; memory-mapped and binary-searched,
  no heap. To update: download a newer `safe.txt`, run the script, run the tests.
- **Exceptions window** (`ExceptionsEditor.swift`; panel "Изменить…", right-click "Исключения…"):
  tab "Слова" = `UserExceptions`, words as typed, never fixed, stored as text in the settings
  (`userExceptions`), never in the journal. Only the owner fills it: an agent seeded it on
  2026-10-18 with INVENTIRE abbreviations (rtl, ctx, deps…) the owner never types, and the owner
  deleted them as useless; do not add words on your own. On 2026-10-26 it held len, rec, вифи, ии,
  мд, сиви, смс. Tab "Приложения": "Не исправлять в" (`autoOffApps`) and "Не следить в"
  (`excludedApps`), added from the current app, running apps or Finder. Older undos (before 0.3.0)
  added hashes of the key codes (`FixExceptions`, no text): still honoured, "Сбросить" clears them.
- **Clipboard history** (replaces Maccy, 2026-10-19; `ClipboardStore.swift`, `ClipboardItem.swift`
  = pure rules, tested, `ClipboardWindow.swift`, `HotKey.swift`): ⇧⌘C (Carbon hot key, key code, works
  in any layout) opens a non-activating panel at the pointer: search (also in the wrong layout:
  "ghbdtn" finds "привет"), list with app icons, preview beside it after 1.5 s. ⏎ pastes (⌘V posted
  to the app in front, needs Accessibility), ⌥⏎ copies only, ⇧⏎ without formatting, ⌘1…9, ⌥⌫
  deletes. Polls `changeCount` every 0.5 s. Keeps text (+ RTF/HTML), images (TIFF saved as PNG) and
  files, same content moves to the top; limit in MB (panel: 50/100/200/500, default 100) plus 1000
  entries. Skips password managers, "Не следить в" apps, nspasteboard.org private/transient types
  and seed phrases (Maccy's regex). Stored in `~/Library/Application Support/GeniusTyper/clipboard/`
  (`index.json` with texts + one folder per entry). Measured against Maccy: `MACCY-BASELINE.md`.
  The shortcut is changeable in the panel ("Открывать": click, press a combination with ⌘/⌥/⌃;
  `KeyCombo`, stored as `clipboardHotKey`). As in Maccy, the gear at the bottom right of the
  history opens the panel (its clipboard section), and "Открыть" next to "История буфера обмена" in
  the panel opens the history. Maccy must not run at the same time: both take ⇧⌘C, the
  second registration does not fail and the app registered last gets it; the panel warns while
  Maccy is running.
- **Watches typing, listen-only** (`Observer.swift`, Input Monitoring permission). Clicks, arrows, ⌘/⌃ shortcuts and app switches reset the tracked line.
- `WordTracker.swift` (pure, tested): keys → finished words and *rewrites* (erase, then retype).
  Words are kept as physical keys, so "ghbdtn" and "привет" are the same keys in two layouts.
  The layout of each key is the selected input source at that moment. Not the character in the
  event: after Genius Typer switches the layout itself, events keep carrying characters of the old
  layout while the app types in the new one (2026-10-18: "hello" typed in Russian was judged English).
- `Detector.swift`: detector v0: macOS spell checking in both layouts plus a script
  check (the Russian checker accepts Latin "ok"/"git"). All-caps words of 2–5 letters (RTL, API)
  are abbreviations: skipped. The other side must have a vowel (y counts): the English checker
  accepts "bb", "cvc", "vl" (from ии, смс, мд). The auto-fix (`fixes(_:language:before:)`) also
  keeps a word of ≤4 keys when the two words before it in the line are real words in the same
  layout ("сделай мне ии"); one word is not enough ("ok ns" → "ok ты"). It is a dictionary, not a model: words missing from it are "unknown"
  (letter n-grams are the planned next step, after real journal data; journal before 2026-10-20 is
  mostly the owner's testing). Verdicts: keep / fix / ambiguous / unknown /
  skip.
- `Recorder.swift`: tracker output → journal entries; a manual wrong-layout fix = rewrite with a
  layout change and the same keys retyped (full or prefix). Words flagged "fix" but left alone for
  20 s count as detector false alarms.

## Dictation (was Diktant)

Off by default on a fresh install (`Prefs.dictationEnabled`, the Диктовка switch): off = no key
tap, no hot keys, no microphone, the model unloaded (`Dictation.setEnabled`). "Голосовые из
Telegram" has its own switch (`voicesEnabled`) inside it. **ё in dictated text** (`dictationYo`,
on by default): `Yoficator.restoreText` runs over the transcript before pasting (Parakeet nearly
always writes е). Its hot keys and Genius Typer's clipboard hot key are Carbon hot keys with their
own handlers on the same target: each handler takes only its own signature ("DKTY" / "GSKY") and
returns `eventNotHandledErr` for the others (otherwise the first handler swallows every hot key).


- **Dictation key** (`Shortcut`, `HotkeyMonitor`): right ⌥ by default, changeable in settings
  ("Изменить": a modifier pressed and released alone — right/left ⌥ ⌘ ⌃ ⇧, Fn — a key with ⌃/⌥/⌘,
  or an F-key alone; F18 is excluded, it is Caps Lock). Stored as a key code, so
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
- **The model runs in a helper process** `Contents/MacOS/GeniusTyperEngine` (`GeniusTyperEngine/main.swift`;
  only it links FluidAudio). Genius Typer starts it when recording starts (the model loads in ~0.2 s
  while the user speaks), sends samples over stdin, reads JSON lines from stdout, and closes its
  stdin after `Prefs.unloadAfterMinutes` (default 5; 1/5/15/60/never) without dictation, so it
  exits. Why: loading the model in-process left ~30 MB of fragmented malloc memory that
  `malloc_zone_pressure_relief` could not give back (54 MB idle forever after the first
  dictation, `PROFILING.md`). The helper also downloads the model (`download` mode, ~470 MB into
  `~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3`, started automatically on
  first launch). The first load ever compiles the model for the Neural Engine (one-time, >10 s;
  cached by macOS in `~/Library/Caches/com.apple.e5rt.e5bundlecache`, survives rebuilds).
- **Paste** (`Paster`): text to the clipboard marked `org.nspasteboard.TransientType` (the clipboard history skips it), ⌘V posted, previous clipboard restored after 0.6 s unless
  something else was copied. Needs Accessibility (the key taps need it too); without it the text
  stays on the clipboard and the pill says so.
- **Indicator** (`Indicator`): TypeWhisper's "Overlay" + "Classic": dark pill at the bottom centre
  of the screen with the pointer: red dot, timer, 5 level bars up to 30 pt (pill 38 pt high; `LevelBars`: 0.02…0.40
  onto the height with a 0.7 power curve, tuned on the owner's recorded voice
  `Tests/GeniusTyperTests/Fixtures/owner-speech.wav`: silence 0.00, speech mostly 0.15–0.36, peaks
  ~0.47; `LevelBarsTests` keep it; `-saveDictationAudio <file.wav>` records a new sample and logs
  its level percentiles); a flat white line from the first frame until the first sound, then bars to the end of
  the dictation, the quiet ones 10 pt (dots read as "loading"; a line coming back in soft speech
  read as "not hearing"; both seen on recorded dictations) (asked 2026-10-26: 3 pt dots, dim bars and bars
  filling in one by one all read as "wait, loading"); "Распознаю…"; short messages
  (no model, no key, nothing recognised). AppKit-drawn `NSPanel`, built on show, released on hide.
  **Level style** (`LevelStyle`, Диктовка → Индикатор, asked 2026-10-26 after an interactive
  preview of six): "Полоски" (above, default), "Плотная волна" (16 thin bars scrolling, a dotted
  line in silence, like Voice Memos) and "Линия" (a smooth oscilloscope line that swings with the
  voice; its own 30 fps timer only while recording, ~6 % CPU then, stopped on hide). The demo
  ("Показать", `--indicator-demo`) uses the owner's levels.
  **Animation** (`Mascot`, asked 2026-10-26; Основное → Анимация, "Показать" = 6 s demo, also
  `--indicator-demo`): a monkey, one of two cats or Bruce Almighty above the pill while recording/transcribing,
  typing at full speed while the level is above 0.3 (and 0.2 s after), then slowing down
  smoothly over 1.2 s to a stop (asked 2026-10-26: a hard stop on every pause between words looked
  like stutter). Cut out of the owner's
  GIFs with Vision by `scripts/make-mascots.swift` (largest subject only, frames where the laptop
  got lifted too are dropped; monkey: frames 106–151,0–43, every 2nd, without the facepalm) into
  `scripts/mascots/*.apng` (the sources, not bundled), which `scripts/make-mascot-frames.swift`
  turns into `GeniusTyper/Dictation/Mascots/*.frames`: 96 pt high at 2×, the shadow baked in, raw
  frames compressed with LZFSE (decoding a PNG frame took ~1 ms, this ~0.15 ms; 2026-10-26,
  `DICTATION-PROFILING.md`). Memory-mapped, one frame decompressed at a time: ~0.3 MB while
  shown, ~3 % CPU while it moves (the pill alone ~1.2 %). After changing an APNG, run the script
  for it. Bruce (replaced 2026-10-26 by the owner's green-screen clip
  `m2-res_480p.mp4`, cut with ffmpeg `chromakey=0x12FF08:0.2:0.05,despill`, 15 fps, 240 px high):
  two views, one picked at random per dictation — front (crop 854:467:0:13; slow 1.0–4.0 s, fast
  4.3–6.3 s) and side (crop 690:460:110:20; slow 6.7–8.9 s, fast 11.55–13.9 s). Each starts slow
  and switches to the fast loop after 3 s of speech; a pause over 1.5 s starts slow again.
- **History** (`History`, SQLite `~/Library/Application Support/GeniusTyper/dictation/history.sqlite`): text
  only (no audio), forever: date, text, words, duration, app, model. Paged from disk, Cyrillic
  case-insensitive search (`lower_ru`), copy, delete.
- **Statistics**: week / month / all time: words, dictations, words per minute, time saved (typing
  at 45 wpm minus speaking time — TypeWhisper's figure), words per day, by app, by model; all
  totals computed by SQLite.
- **Telegram voice messages** (`TelegramVoices`, `VoiceTranscripts`, `VoicePanel`; asked
  2026-10-26): ⌃⌥V (changeable in Основное; a Carbon hot key with id 2, same handler as the
  dictation combination) opens a popup with the 3 newest voice messages (the left-click panel shows the same list) from the official Telegram app's cache
  (`~/Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram/stable/account-*/postbox/media`,
  files without extension; voice = Ogg Opus, checked by the "OggS"/"OpusHead" header, decoded by
  `AVAudioFile`; Telegram downloads into `<name>_partial` and, once complete, `<name>` is a hard link
  to it with both kept, so a `<name>` next to a different `_partial` file is still downloading).
  More, 3 at a time: scrolling down past the end, ↓ at the end, or the "Ещё 3" button (the folder
  listing, plain `lstat` over ~10 000 files in ~0.2 s — FileManager resource values took 3 s — is
  read once per opening and paged). **Stored texts first** (asked 2026-10-26): opening shows at
  once the texts kept in `~/Library/Application Support/GeniusTyper/dictation/voice-texts.json`
  (`VoiceText`: path, file date, duration, text, when transcribed) for the last
  `Prefs.voicesKeepDays` (Диктовка → "Хранить расшифровки": 1/3/7/30 days, default 7; kept by the
  message date or by when it was transcribed), newest first, also after the file left Telegram's
  cache; meanwhile `TelegramVoices.scan` looks for voice messages of those days not stored yet
  (non-voice files are remembered for the run, so their headers are read once), they join the list
  in their place and are transcribed newest first. A quiet status beside the title: "Проверяю новые
  голосовые…" → "Расшифровываю: N" → "Все голосовые расшифрованы". Older ones on request, 3 at a
  time, as above. The format before 0.13.0 (`key` + `text`) is read and converted. Nothing goes into the dictation history or statistics (the owner wants only own dictation there). The chat a file came from is only in Telegram's encrypted database, so the
  owner keeps voice auto-download on for private chats only (Telegram → Data and Storage). Video
  circles (mp4) are not included. `-voicesRoot <folder>` points it at a test folder; `--voices`
  opens the popup at launch. The owner declined importing TypeWhisper's history (2026-10-26).
- **App language**: architecture only. Strings go through `String(localized:)` /
  `LocalizedStringKey`; `Localizable.xcstrings` (source ru) is still empty: Xcode fills it with the
  strings when the project is built in the IDE (xcodebuild does not). To add English,
  translate there, add "en" to `CFBundleLocalizations` and enable the menu item (MeetRec's
  `AppLanguage` shows the restart flow).

Not needed (TypeWhisper features left out on purpose): workflows, logins, file transcription,
recorder, speakers, dictionary, snippets, translation, sync, plugins.

### Dictation memory and CPU (Diktant alone, 2026-10-26; details in `DICTATION-PROFILING.md`)

| | Memory | CPU idle |
|---|---|---|
| TypeWhisper | ~113 MB + widget ~30 MB | — |
| Diktant idle (before the merge) | 15 MB, 0 wake-ups | 0.0 % |
| Settings window open | ~32 MB | |
| Dictating (model loaded) | ~17 MB + engine helper ~36 MB | |

Rules kept: nothing polls (one-shot unload timer, timers only while the pill is shown); no Swift
Charts / `Canvas` / system `Toggle` (`LightSwitchStyle`), plain-shape bars, `Menu` not `Picker`,
`sizingOptions` off; `Memory.giveBackSoon()` after windows and dictations.

Dictation checks: - `scripts/test.sh` also runs these unit tests (hybrid key, shortcuts, word count, history and statistics, WAV,
  Telegram voice lookup with `Tests/GeniusTyperTests/Fixtures/voice.ogg`, synthesized speech).
- `--transcribe-file <audio>`: transcribes a file with the current engine twice, logs text, time,
  footprint of the app and the helper (`say -v Milena -o ru.aiff "…"` for Russian speech).
- `--indicator-test`: the pill with each animation for 12 s (steady speech, then quiet), two rounds;
  logs the app's CPU and footprint for each.
- `--dictation-stress-test`: three rounds of every settings page plus load/transcribe/unload of the model,
  footprint after each step; growing every round = a leak.
- - `PROFILE=1 scripts/install.sh`: signs with get-task-allow for `heap`/`leaks`/`vmmap`.
- Log: `~/Library/Logs/GeniusTyper/geniustyper.log` (debug lines with `verboseLog` or any `--…-test`).

Sounds: start = own two short bass notes up a fourth (165 → 220 Hz) `GeniusTyper/Dictation/Sounds/start.wav`
(like system Funk, which the owner likes, but rising; Tink was too thin; chosen over a single gliding or flat note), text pasted = own single soft
sine tap at 740 Hz `GeniusTyper/Dictation/Sounds/success.wav` (`scripts/make-sounds.swift`, in the spirit of
Claude's voice-mode sounds; a brighter C6 bell with overtones was too sharp for the owner, and
system Pop sounded like a failure, so Pop now means nothing recognised / error), Esc = Funk.

## Privacy rule

The clipboard history is the exception: it stores what was copied (that is its job), locally only.
The second exception, asked for by the owner on 2026-10-26: the **words log**
(`~/Library/Application Support/GeniusTyper/words/YYYY-MM-DD.jsonl`, `WordLogEntry`, 30 days):
only fixes with their words: auto-fix, its undo, ⇧+Space skip, Caps Lock mid-word, Caps Lock twice,
ё, manual wrong-layout fixes (`rewrite`) and detector false alarms (`flagKept`), each as `typed` →
`result`. Plain typing is never written, nor anything in the "Не исправлять в" apps (terminals,
code editors: a password retyped in the other layout must not reach a file). Switch and
"Удалить слова" in the statistics window; "Удалить журнал" deletes it too. Use it to see which
words the detector gets wrong.
The journal never contains text: only layouts, lengths, verdicts, timings and the app bundle ID
(`JournalEntry`; a test checks that words do not reach the JSON). Letters exist only in memory while
a word is typed; the menu shows the last 5 fixes as text from memory only. Password managers are
excluded by default, plus "Не следить в «…»" per app. Secure Input fields are invisible to the tap.

Journal: `~/Library/Application Support/GeniusTyper/journal/YYYY-MM-DD.jsonl`, 90 days.
Log: `~/Library/Logs/GeniusTyper/geniustyper.log`.

## Next

Analyse the journal (how often, which apps, early vs late fixes, auto-fixes undone, detector
caught/missed/false alarms by word length) and improve the detector (letter trigrams); fixing
mid-word; manual exceptions; a "convert last word / selection" hotkey; later possibly merge
MonitorCtl into this app too.

Статистика → Печать (`TypingStatsView.swift`): today or the last 7 days (per day; after midnight
"today" starts empty), last fixes, journal open/delete, the words log switch.

Profiling (as in MXCtl): `--panel-test` (left-click panel 6 times, longest main-thread stall), `--history-test`
(history window, moving down until the preview opens), `--stress-test` (3 rounds of both, footprint
per round: growing every round = a leak); `PROFILE=1 scripts/install.sh` signs with get-task-allow
so `leaks`/`heap`/`malloc_history` can attach; `scripts/profile.py` for memory/CPU/wake-ups under
load. Results and lessons: `MACCY-BASELINE.md`. Keep high-frequency state (`TypingStats`,
`ClipboardStore.items`) out of what the panel observes: the kept panel re-renders even while hidden.

Build and install: `scripts/install.sh`. Tests: `scripts/test.sh` (also removes the Debug app afterwards: a second copy with the same bundle ID steals the permissions).
Both delete `build/` when done (~300 MB of intermediates and caches); `KEEP_BUILD=1` keeps it while
iterating. **When finished, leave no extra copies or caches behind**: only
`~/Applications/Genius Typer.app` (`mdfind "kMDItemCFBundleIdentifier == 'com.dmemruk.GeniusTyper'"`
shows one result), no `build/`, no DerivedData, and delete test screenshots (they show the clipboard).
Launch arguments for screenshots: `--open-settings [general|typing|clipboard|dictation|history|statistics]`,
`--menu [voices|history]` (a running instance ignores them: quit it first).

## Menu bar icon

`StatusItemController.swift` (derived from MonitorCtl's): left click = `QuickPanel`, right click =
menu with "Завершить". Not SwiftUI's `MenuBarExtra`: when the icon is turned off in
System Settings → Menu Bar, a `MenuBarExtra`-only app quits right after launch (MonitorCtl did, so
its keys silently stopped working, and the unit tests' host quit too). With an `NSStatusItem` the
app keeps running; opening it again from Spotlight/Finder shows the panel in a small window.

Genius Typer's icon is drawn in code (`AppDelegate.menuBarImage`): "G" with a text cursor (it
was SF Symbols' "A" with a cursor); a red `mic.fill` while dictating, an ellipsis while the text is
recognised (`MenuBarIcon.dictationPhase`). Основное → "Язык на значке: нет / RU / EN / флаг" + "с иконкой"
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
