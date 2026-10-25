# Diktant: agent guide

Personal macOS menu bar app replacing **TypeWhisper** (voice dictation): only the features the
owner uses. Swift, xcodegen (`project.yml`), ad-hoc signed and re-signed with the local certificate
"dmemruk Local Code Signing", installed to `~/Applications` by `scripts/install.sh`, bundle ID
`com.dmemruk.Diktant`. Same conventions as the other own apps (see `../AGENTS.md`).

## Spec (agreed 2026-10-26, not implemented yet)

- **Hotkey: Right Option, hybrid.** Hold = push-to-talk (release stops and inserts); short press =
  toggle (dictate as long as needed, press again to stop and insert). Esc while recording cancels
  without inserting. Short start/stop sounds.
- **Engine: NVIDIA Parakeet TDT 0.6B v3** on device (CoreML / Neural Engine, via FluidAudio),
  RU/EN with automatic language detection. Architecture allows more engines: cloud API engines
  (Groq, OpenAI, any OpenAI-compatible Whisper endpoint) with a key; not used yet.
- **Insertion:** text into the clipboard, ⌘V to the frontmost app, previous clipboard restored.
- **Indicator:** like TypeWhisper's "Overlay" + "Classic" theme: small dark pill (red dot, timer,
  level bars) while recording / transcribing.
- **History:** text only (no audio), kept forever: text, app, engine/model, duration, date.
- **Statistics:** words total, by app, by model; WPM, time saved.
- **Settings:** launch at login; app language (architecture for RU and EN, only RU implemented).
- **Menu bar icon** (`StatusItemController`); right click → "Завершить".
- Not needed: workflows, logins, file transcription, recorder, speakers, dictionary, snippets,
  translation, sync.
