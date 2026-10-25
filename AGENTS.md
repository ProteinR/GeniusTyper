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
- **Light on memory and CPU**, as MXCtl, Genius Switcher and MeetRec were made (their
  `PROFILING.md`, `scripts/profile.py`, `--stress-test`). Baseline to beat, measured 2026-10-26:
  TypeWhisper ~113 MB + widget extension ~30 MB idle.
  - Idle: no timers or polling, ~0 wake-ups, 0.00 % CPU; only the Right Option listener (flags
    changes only, not every key). Target ≤ ~20–25 MB idle.
  - The model is the big cost (hundreds of MB): it is loaded when recording starts (in parallel
    with speaking, so no wait) and unloaded after a few minutes without dictation (setting, default
    5 min). Microphone engine runs only while recording, then is torn down.
  - Indicator: own lightweight `NSPanel`, ordered out and its views freed when idle; no level
    animation while hidden.
  - Settings/statistics/history window: created on open, released on close. Lessons from MXCtl:
    no Swift Charts / `Canvas` / system `Toggle` in a `Form` (≈100 MB graphics memory on macOS 26),
    charts drawn with AppKit into an `NSImage`, `Menu` instead of `Picker`, no `TabView` around
    long lists, `sizingOptions` off. History is paged from disk (SQLite), not held in memory;
    statistics are aggregated in the store, not by loading all entries.
  - Measure before/after with a stress test (repeated dictations, window open/close: footprint
    must stay flat) and record results in `PROFILING.md`.
- Not needed: workflows, logins, file transcription, recorder, speakers, dictionary, snippets,
  translation, sync.
