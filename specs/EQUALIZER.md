# Equalizer

10-band peaking biquad filters applied post-crossfade to final PCM output.

## Bands

| Band | Freq  |
|------|-------|
| 0    | 31 Hz |
| 1    | 62 Hz |
| 2    | 125 Hz |
| 3    | 250 Hz |
| 4    | 500 Hz |
| 5    | 1 kHz |
| 6    | 2 kHz |
| 7    | 4 kHz |
| 8    | 8 kHz |
| 9    | 16 kHz |

## Presets

Flat, Rock, Pop, Classical, Jazz, HipHop, Vocal, BassBoost, Headphones, Laptop

## Commands

- `set_eq_band {band, gain_db}` — set single band gain (-12 to +12 dB)
- `set_eq_preset {name}` — apply named preset

## Implementation

- C code in `ffmpeg_impl.c` (vendor/ffmpeg)
- Preset values duplicated in Nim (`cycleEqPreset` in gtm.nim) and C (`EQ_PRESETS`)
- Applied in MixerBackend post-crossfade
