# Genius Typer — RU/EN keyboard layout switcher, clipboard history and local dictation for Mac

**English** | [Русский](README.ru.md)

[![macOS 15+](https://img.shields.io/badge/macOS-15%2B-000?logo=apple)](#requirements)
[![Apple Silicon native](https://img.shields.io/badge/Apple%20Silicon-native%20%C2%B7%20Neural%20Engine-0a84ff)](#built-for-apple-silicon)
[![Swift](https://img.shields.io/badge/Swift-native-F05138?logo=swift&logoColor=white)](#built-for-apple-silicon)
[![Idle memory 23 MB](https://img.shields.io/badge/idle-23%20MB%20%C2%B7%200%20wake--ups-2ea44f)](#built-for-apple-silicon)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

**Genius Typer** is a free, open-source macOS menu bar app for everything about typing for people
who write in **Russian and English**. A Punto Switcher / Caramba Switcher alternative, a Maccy-style
clipboard manager and offline voice typing (speech-to-text) in one native app, tuned for Apple
Silicon (M1, M2, M3, M4, M5):

- **Wrong layout fixed automatically**: "ghbdtn" becomes "привет" after the space, "руддщ" becomes
  "hello". **Caps Lock switches the layout** instantly, like on Windows / Linux setups.
- **ё where it belongs**: "еще" → "ещё", "Артем" → "Артём".
- **Clipboard history** (⇧⌘C), Maccy-style.
- **Voice dictation** on your Mac: hold right ⌥ and talk, the text is typed where the cursor is.
  NVIDIA Parakeet runs locally on the Neural Engine; nothing leaves the Mac unless you choose a cloud
  service.
- **Telegram voice messages** transcribed from the Telegram app's cache (⌃⌥V).

It replaces three apps — **Caramba Switcher** (or Punto Switcher), **Maccy** and **TypeWhisper**
(or superwhisper, MacWhisper dictation) — with one icon, one login item and ~23 MB of memory.
Each part has its own switch; turn off what you do not need.

## Why Genius Typer

- **Three apps in one, lighter than any of them**: 23 MB of memory at rest for layout switching,
  clipboard history and dictation together.
- **Zero background cost**: 0 CPU wake-ups per second at rest (Maccy: ~100/s), so it does not
  touch your battery life.
- **Offline speech recognition on the Neural Engine**: 10 seconds of speech becomes text in
  0.08 s, about 100× faster than real time. No subscription, no account, no audio sent anywhere.
- **The model is not kept in memory**: it lives in a helper process that exits after a few idle
  minutes, so dictation costs nothing while you are not talking.
- **Native Swift + AppKit**, a universal binary (arm64 + x86_64): no Electron, no Python, no web
  view. The main binary is 6.6 MB; the speech engine is a separate helper.
- **Private by design**: macOS's own spell checker decides what is a word, the typing journal holds
  no text, password managers and secure input are never seen.
- **Free and open source** (MIT), every number below reproducible with the scripts in the
  repository.

The interface is in **Russian** (the app is for Russian speakers). The strings go through a String
Catalog (`GeniusTyper/Localizable.xcstrings`), so an English translation can be added.

## Features

### Layout (Genius Switcher)

- **Caps Lock** switches between the English and the Russian layout on every press (⇧ + Caps Lock
  is the real Caps Lock). Right after an automatic fix it undoes it; in the middle of a word it
  retypes the letters in the other layout; **twice** it converts the whole phrase since the last
  line break.
- **Auto-fix**: after a space or punctuation, a word that is gibberish as typed and a real word in
  the other layout is retyped and the layout switched. Caps Lock right after undoes it; ⇧+Space
  ends a word without fixing it. Off by default in terminals and code editors; per-app and
  per-word exceptions.
- **ё**: a dictionary of ~107 000 forms where ё is always right (`все`/`всё`-like words are never
  touched).
- macOS spell checking in both languages decides what is a word: no cloud, no word lists sent
  anywhere.
- Works with any English and any Russian layout enabled in System Settings (ABC, U.S., Russian,
  Russian – PC…).

### Clipboard history

- ⇧⌘C (changeable) opens the history at the pointer: search (also typed in the wrong layout),
  app icons, preview, ⏎ pastes, ⇧⏎ pastes without formatting, ⌘1…9.
- The newest entries also sit in the menu bar icon's left-click menu: point at "История буфера" for
  the list with search; a click copies an entry, the one under the pointer shows its preview.
- Settings → История has the whole clipboard history next to the dictations and the voice
  messages ("Вся история…" under each list of the left-click menu opens its tab), with the same
  line under each: how many, the space taken and how long they are kept.
- Text, rich text, images and files; a size limit in MB.
- Skips password managers, private/transient pasteboard types and crypto seed phrases.

### Dictation (Diktant)

- **Right ⌥** (changeable): hold to talk, or tap to start and tap again to stop. Esc cancels.
- **Local**: Parakeet Ultra (Moondream's post-trained NVIDIA Parakeet TDT 0.6B v3, the default) or
  Parakeet v3 itself (25 European languages, automatic detection) via
  [FluidAudio](https://github.com/FluidInference/FluidAudio) on the Neural Engine. Ultra is as fast
  and noticeably more accurate (on the author's meetings and an English lesson: Whisper sided with
  Ultra 216 times and with v3 71 times where the two differed), at ~630 MB on disk instead of ~470 MB. It runs in a helper
  process that exits after a few idle minutes, so the model does not sit in memory.
- **Cloud, optional**: Groq, OpenAI or any OpenAI-compatible `/audio/transcriptions` service with
  your own key (stored in the Keychain).
- A small pill at the bottom of the screen with the microphone level (its scale adapts to the
  microphone and the room, and is remembered per microphone), ё restored in the text,
  history with search, kept forever or for 30 days / 90 days / a year, and statistics (words,
  words per minute, time saved).
- **Telegram voice messages**: the newest voice messages from the official Telegram app's cache,
  transcribed locally and kept for a few days or forever, each with who sent it (the person, or
  the author and the group); search them, copy or delete each text, also in the settings' history.

## Built for Apple Silicon

Measured on an M-series Mac, macOS 26, with `scripts/profile.py`, `top`, `heap`, `leaks` and the
app's own `--…-test` modes; memory is the footprint Activity Monitor shows. Details:
[DICTATION-PROFILING.md](DICTATION-PROFILING.md), [MACCY-BASELINE.md](MACCY-BASELINE.md) (Russian).

| | Genius Typer | Replaced apps |
|---|---|---|
| Idle: memory | **23 MB** (all three parts) | Maccy 353–505 MB, TypeWhisper ~113 MB + 30 MB widget (cloud engine selected, no local model) |
| Idle: CPU, wake-ups | **0.03%, 0/s** | Maccy 0.03%, ~100/s |
| Copying text once a second | **0.95% CPU** | Maccy 17.3% |
| Copying an 800×600 image every 2 s | **1.5% CPU, 37 MB** | Maccy 12.6%, 546 MB |
| Dictating | ~17 MB + model helper ~36 MB, gone after idle | — |
| Leaks after 3 stress rounds | none of ours (`leaks`), footprint flat | — |

Maccy was measured as it was used, not as a clean install: version 2.7.1 after four days of
running with a real history, so its memory figures depend on that history. The copying rows ran the
same scripts against both apps.

**Local dictation** (NVIDIA Parakeet TDT 0.6B v3, CoreML on the Neural Engine):

| | Time |
|---|---|
| Model load (warm) | 0.17–0.27 s, while you are already speaking |
| 7 s of speech | 0.07 s |
| 10 s of speech | 0.08 s (0.35 s including the helper start) |
| 20.7 s of speech | 0.28 s |
| 9 s Telegram voice message | 0.46 s, model start included |

**How it stays this light:**

- The speech model runs on the **Neural Engine** through CoreML, not on the CPU or GPU, and in a
  separate process: freed CoreML memory cannot be returned by a running process, so the helper
  simply exits (54 MB → 15–17 MB after a dictation).
- Nothing polls except the clipboard (`changeCount` twice a second, as every clipboard manager
  does). Timers exist only while the dictation pill is on screen.
- The recording pill is drawn by **Core Animation** layers at 60 fps: each bar is a layer whose
  frame changes, the line one path a frame; the view never redraws (~3% CPU, the line was 9.5%
  drawn by the view); WindowServer stays within ~1.5% of its baseline.
- Animation frames are raw pixels compressed with Apple's **LZFSE**, memory-mapped and decoded one
  at a time: 0.15 ms a frame against ~1 ms for PNG.
- The ё dictionary (~107 000 words) is memory-mapped and binary-searched: no heap.
- Windows are built when opened and released when closed; no SwiftUI `Charts`/`Canvas` or system
  `Toggle`, which alone took ~100 MB of graphics memory.

## Privacy

- The keyboard is watched listen-only; letters exist in memory only while a word is typed.
- The **journal** (for improving the detector) has no text: layouts, lengths, verdicts, timings and
  the app's bundle ID. The **words log** keeps only fixed words (typed → result), 30 days, can be
  turned off; nothing from terminals and code editors.
- The clipboard history is stored locally in `~/Library/Application Support/GeniusTyper/`.
- Dictation is local unless you choose a cloud engine. Audio is never saved.
- Password managers are excluded; secure input fields are invisible to the app.

## Requirements

- macOS 15 or later. Apple Silicon recommended for local dictation (Neural Engine).
- Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
- An English and a Russian keyboard layout in System Settings → Keyboard → Input Sources.

## Build and install

```bash
git clone https://github.com/ProteinR/GeniusTyper.git
cd GeniusTyper
./scripts/install.sh
```

This builds a Release copy, signs it, installs it to `~/Applications/Genius Typer.app` and starts
it. Settings → Основное lists the permissions it needs and opens the right System Settings pages:

- **Input Monitoring** — to see which keys are typed (layout fixing, Caps Lock, dictation key).
- **Accessibility** — to retype words and paste (clipboard history, dictation).
- **Microphone** — only when dictation is on.

Dictation is off on a fresh install: turn it on in Settings → Диктовка; the local model (~470 MB)
is downloaded from Hugging Face then.

### Signing (keeps permissions across rebuilds)

There are no signed binary releases (no Apple Developer account). Without a stable signature every
rebuild looks like a new app to macOS and the permissions have to be granted again. To avoid that,
create a self-signed code signing certificate once:

1. Keychain Access → Certificate Assistant → Create a Certificate…
2. Name: `Genius Typer Local Code Signing`, Identity Type: Self-Signed Root, Certificate Type:
   Code Signing.

`install.sh` finds it by that name (or set `GENIUSTYPER_SIGN_IDENTITY` to another one). Without it
the app is ad-hoc signed and still works.

If permissions get stuck (granted but the app keeps asking):

```bash
tccutil reset ListenEvent com.dmemruk.GeniusTyper
tccutil reset Accessibility com.dmemruk.GeniusTyper
```

## Configuring with scripts or AI agents

All settings are user defaults; [SETTINGS.md](SETTINGS.md) lists the keys and values.
[AGENTS.md](AGENTS.md) describes how the app works, for agents (and people) changing the code.

## Tests

```bash
./scripts/test.sh
```

## Alternatives it replaces

Looking for a **Punto Switcher for Mac**, a **Caramba Switcher** alternative, an automatic keyboard
layout switcher for macOS, a free **Maccy** alternative, or an offline **superwhisper / MacWhisper /
Wispr Flow / TypeWhisper** alternative for voice typing? Genius Typer does all of it in one menu bar
app, for free, without sending your text or voice anywhere.

| You need | Usually | Genius Typer |
|---|---|---|
| Fix text typed in the wrong layout (RU ↔ EN) | Punto Switcher, Caramba Switcher | Auto-fix + Caps Lock |
| Switch layout with Caps Lock | System setting, Karabiner-Elements | Built in, instant, with undo |
| Clipboard history | Maccy, Paste, Raycast | ⇧⌘C, searchable in either layout |
| Voice typing / dictation | superwhisper, MacWhisper, Wispr Flow, TypeWhisper | Local Parakeet on the Neural Engine, or Groq/OpenAI |
| Transcribe Telegram voice messages | Telegram Premium, bots | Local, from Telegram's cache |

## FAQ

**Does it run on Intel Macs?** Yes, it is a universal binary; local dictation needs the Neural
Engine of Apple Silicon to be fast, so on Intel use a cloud engine.

**Is it free? Does it need an internet connection?** Free and MIT-licensed. Only the first download
of the speech model (~470 MB) needs the internet; after that everything works offline.

**Does it work with other languages?** Layout fixing is built for one English and one Russian
layout. Dictation understands 25 European languages.

**Is Caps Lock gone?** ⇧ + Caps Lock still toggles it. Caps Lock is remapped to F18 for the session
with `hidutil`; the mapping is removed when the app quits. Switching with Caps Lock can be turned off.

**Does it conflict with Maccy or Punto Switcher?** Run one layout switcher at a time. Maccy also
takes ⇧⌘C; quit it or change the shortcut.

## Notes

- Telegram voice messages are read from the cache of the official Telegram for macOS app
  (`ru.keepcoder.Telegram`); only files Telegram has downloaded are found. The sender comes from
  Telegram's own database on this Mac, opened read-only with [SQLCipher](https://github.com/sqlcipher/SQLCipher.swift)
  (BSD) in the helper process; with a passcode set in Telegram the names are not shown.
- The ё dictionary is built from [eyo-kernel](https://github.com/hcodes/eyo-kernel) (MIT,
  `GeniusTyper/yo-LICENSE.txt`). Parakeet v3 is NVIDIA's, Parakeet Ultra is Moondream's, both CC BY 4.0.
- The dictation animations (a cat in a wig, Bruce Almighty) are made from widely shared GIFs and
  a film clip; they are not covered by the MIT license and belong to their owners.

## License

[MIT](LICENSE)
