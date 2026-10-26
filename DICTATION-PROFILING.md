# Diktant: memory and CPU

Measured 2026-10-26 on macOS 26.6.2 (M-series), Diktant 0.1.0, footprint as Activity Monitor
shows it (`phys_footprint`).

## Baseline: TypeWhisper

~113 MB (`TypeWhisper`) + ~30 MB (`TypeWhisperWidgetExtension`) idle, from `ps` RSS.

## Diktant

| State | Diktant | DiktantEngine |
|---|---|---|
| Idle after launch | 15 MB, 0.0 % CPU, 0 idle wake-ups (`top -l 4 -s 10`) | not running |
| Settings window open (any page) | 27–33 MB | — |
| Model loaded, dictating | ~17 MB | ~35–37 MB |
| After unload | back to the previous figure | exited |

Model: load 0.17–0.27 s from a warm cache (helper start included in the 0.27–0.39 s of the first
transcription); 7 s of speech in 0.07 s, 20.7 s in 0.28 s. Settings pages open in 11–213 ms
(`general` is the slowest, first opening).

`--stress-test` (3 rounds of all pages + model load/run/unload): flat across rounds, no leak.

## Lesson: the model in a separate process

First version loaded Parakeet in Diktant itself. Footprint after one load + unload stayed at
54 MB (31 MB before), in every round. `heap` showed only 11 MB live; `vmmap` showed
DefaultMallocZone 40.8 MB dirty with 76 % fragmentation, and `malloc_zone_pressure_relief`
returned 0 KB: freed small blocks from CoreML/FluidAudio loading, interleaved with live ones, that
macOS never takes back from a running process. Moving FluidAudio into the `DiktantEngine` helper,
which exits on unload, brought Diktant back to 15–17 MB idle after dictation, and its binary from
~40 MB to 2.3 MB.

## Telegram voices popup (0.1.3)

Popup open: 20 MB (Diktant) + the helper while the model is loaded. 9 s voice message transcribed
in 0.46 s (model start included), 3 s in 0.05 s; reopening shows cached text at once.

## Genius Typer 0.13.1: everything after the merge (2026-10-26)

Profiling build (`PROFILE=1 scripts/install.sh`), M1-series, macOS 26.6.

| Check | Result |
|---|---|
| Idle after launch (`scripts/profile.py 30`) | 23 MB, 0.03 % CPU, 0 wake-ups/s |
| `--stress-test` (panel ×10 + clipboard history ×10, 3 rounds) | 41.6 → 38.9 → 41.7 MB; live heap 13.20 → 13.23 MB after rounds 1 and 3 (`heap`) |
| `--dictation-stress-test` (all settings pages + model load/run/unload, 3 rounds) | 41.1 → 41.4 → 41.4 MB, helper 34.5–34.7 MB and exits on unload; pages open in 40–118 ms (first `general` 275 ms) |
| `leaks` | 286 objects, 14 KB, all inside macOS (`NSXPCConnection` "com.apple.linkd.autoShortcut" cycles of App Intents), none of ours |
| `--transcribe-file` (10 s of `say -v Milena`) | exact text; 0.35 s with the helper start, 0.08 s warm; app 20 MB + helper 36 MB |

After the settings window has been opened once the app stays at ~41 MB instead of 23: +6 MB of
live one-time runtime caches (Swift metadata, method caches, SwiftUI type descriptors; they do not
grow on reopening) and ~13 MB of freed but fragmented malloc pages that
`malloc_zone_pressure_relief` cannot return (the same effect as with the model in-process, see
above). Not a leak; moving the settings window into its own process would be the only cure.

### Dictation pill and animations (`--indicator-test`)

12 s per animation (10 s of steady speech, 2 s quiet), CPU of the app, two rounds:

| | Before (APNG, layer shadow) | 0.13.1 (`.frames`, baked shadow) |
|---|---|---|
| Pill only (the default) | 1.2–1.9 % | 1.2–1.3 % |
| Monkey | 4.9–5.4 % | 3.2–3.3 % |
| Grey cat | 3.8–4.9 % | 2.7–3.2 % |
| Cat in a wig | 4.5–4.8 % | 2.9–3.2 % |
| Bruce | 6.0–7.1 % | 3.6–5.2 % |
| Footprint while shown | 24.8–26.1 MB | 23.6–24.1 MB |

#### 0.13.12: level styles (2026-10-26)

`--indicator-test` now runs each level style without an animation, then each animation with the
bars, at the owner's speech levels (0.15–0.36, random, 12 a second) instead of a steady 0.6, two
rounds. WindowServer measured from outside with `ps -o time=` over the same 12 s. The machine was
busier than for the table above (WindowServer 43.8 % with no pill at all), so the pill numbers
are higher than 1.2 % there; compare the rows with each other.

| | App CPU | WindowServer | Footprint |
|---|---|---|---|
| Nothing shown (idle) | 0.1 % | 43.8 % (baseline) | — |
| Полоски | 2.3–2.4 % | 43.6–43.7 % | 23.8–24.4 MB |
| Плотная волна | 2.3–2.7 % | 44.2 % | 23.9–24.7 MB |
| Линия (60 fps) | 9.3–9.6 % | 43.8–44.9 % | 24.0–24.8 MB |
| Полоски + monkey | 4.7–4.9 % | 44.6–45.2 % | 24.0–25.7 MB |
| Полоски + grey cat | 4.0–4.2 % | 44.4–44.6 % | 23.8–23.9 MB |
| Полоски + cat in a wig | 4.1–4.2 % | 44.4–44.8 % | 23.8–23.9 MB |
| Полоски + Bruce | 5.5–5.6 % | 44.4–45.3 % | 24.0–24.3 MB |

The line is the only style that redraws on its own (60 times a second, the speed of the preview
the owner chose); the bars and the wave redraw only when a level arrives (~12 a second).
WindowServer stays within ~1.5 % of its baseline for all of them. Footprint does not grow
between rounds.

What `sample` showed: with the pill alone the app is asleep nearly all the time (the level
bars, now their own view, redraw ~12 times a second; the text twice a second). With an animation
the time went into PNG decoding (zlib inflate + PNG filters, ~1 ms a frame at 12–15 fps).
Measured per frame: APNG 0.8–1.5 ms, the same frames as HEIC ~4 ms, raw RGBA with LZFSE 0.15 ms,
LZ4 0.05 ms (1.3× bigger than LZFSE). Now `scripts/make-mascot-frames.swift` stores the frames at
the size they are shown (96 pt high at 2×) with the shadow baked in (Core Animation blurred a
layer shadow for every new frame, in WindowServer), LZFSE-compressed, memory-mapped (clean
pages, not in the footprint): 16 MB in the bundle instead of 19 MB.
What is left of an animation's cost: LZFSE decoding, and Core Animation converting each frame
from sRGB to the screen's colours (vImage, ~40 % of it). Tagging the frames with the screen's
colour space would remove that, but colours would be slightly off on the P3 built-in screen; kept
correct. WindowServer's own CPU could not be measured: it was at ~42 % from the rest of the screen.
