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
