# Genius Typer — RU/EN keyboard layout switcher, clipboard history and local dictation for Mac

**English** | [Русский](README.ru.md)

**Genius Typer** is a free, open-source macOS menu bar app for everything about typing for people
who write in **Russian and English**:

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
- Text, rich text, images and files; a size limit in MB.
- Skips password managers, private/transient pasteboard types and crypto seed phrases.

### Dictation (Diktant)

- **Right ⌥** (changeable): hold to talk, or tap to start and tap again to stop. Esc cancels.
- **Local**: NVIDIA Parakeet TDT 0.6B v3 (25 European languages, automatic detection) via
  [FluidAudio](https://github.com/FluidInference/FluidAudio) on the Neural Engine. It runs in a helper
  process that exits after a few idle minutes, so the model does not sit in memory.
- **Cloud, optional**: Groq, OpenAI or any OpenAI-compatible `/audio/transcriptions` service with
  your own key (stored in the Keychain).
- A small pill at the bottom of the screen with the microphone level, ё restored in the text,
  history with search and statistics (words, words per minute, time saved).
- **Telegram voice messages**: the newest voice messages from the official Telegram app's cache,
  transcribed locally and kept for a few days.

## Lightweight by design

Measured on Apple Silicon, macOS 26, with `scripts/profile.py`; memory is the footprint Activity
Monitor shows. Details: [DICTATION-PROFILING.md](DICTATION-PROFILING.md),
[MACCY-BASELINE.md](MACCY-BASELINE.md) (Russian).

| | Genius Typer | Replaced apps |
|---|---|---|
| Idle: memory | **23 MB** (all three parts) | Maccy 353–505 MB, TypeWhisper ~113 MB + 30 MB widget |
| Idle: CPU, wake-ups | **0.03%, 0/s** | Maccy 0.03%, ~100/s |
| Dictating | ~17 MB + model helper ~36 MB, gone after idle | TypeWhisper keeps the model loaded |

Nothing polls except the clipboard (`changeCount` twice a second, as every clipboard manager does).

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

## FAQ

**Does it work with other languages?** Layout fixing is built for one English and one Russian
layout. Dictation understands 25 European languages.

**Is Caps Lock gone?** ⇧ + Caps Lock still toggles it. Caps Lock is remapped to F18 for the session
with `hidutil`; the mapping is removed when the app quits. Switching with Caps Lock can be turned off.

**Does it conflict with Maccy or Punto Switcher?** Run one layout switcher at a time. Maccy also
takes ⇧⌘C; quit it or change the shortcut.

## Notes

- Telegram voice messages are read from the cache of the official Telegram for macOS app
  (`ru.keepcoder.Telegram`); only files Telegram has downloaded are found.
- The ё dictionary is built from [eyo-kernel](https://github.com/hcodes/eyo-kernel) (MIT,
  `GeniusTyper/yo-LICENSE.txt`). The Parakeet model is NVIDIA's, CC BY 4.0.
- The dictation animations (a monkey, two cats, Bruce Almighty) are made from widely shared GIFs and
  a film clip; they are not covered by the MIT license and belong to their owners.

## License

[MIT](LICENSE)
