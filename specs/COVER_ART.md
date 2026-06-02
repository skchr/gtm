# Cover Art

## Status
P3 (new feature)

## Overview

Cover art refers to embedded album artwork in audio files. This feature adds cover art display to the Now Playing view, with a fallback ASCII art placeholder for songs without embedded art.

## Current State
No cover art support exists anywhere in the codebase. The `TrackMetadata` object in `src/audio.nim:18-23` does not have a cover art field. There is no image loading or rendering capability.

## Requirements

### Extract Embedded Cover Art
- Support embedded cover art from MP3 (ID3v2 APIC frame), FLAC (METADATA_BLOCK_PICTURE), OGG (Vorbis comment metadata), M4A (iTunes metadata)
- MiniAudio does not natively support metadata extraction — need a separate approach
- Options:
  1. Use Nim's standard library or a Nimble package for tag reading (e.g., `taglib` wrapper or pure Nim implementation)
  2. Shell out to `ffprobe` or `exiftool` for cover extraction
  3. Implement minimal ID3v2/FLAC parsing for APIC/PICTURE blocks

### Display in Now Playing View
- If cover art exists, display it in the Now Playing view
- Position: top-right of the Now Playing view (next to track info)
- Size constraints: max 20x10 characters (terminal cells)
- Downscale image to fit terminal character grid using ASCII art or half-block characters (▀ ▄ █)

### ASCII Art Fallback
- For songs without cover art, display a default ASCII art music note or speaker icon
- Example:
  ```
    ╔══════════╗
    ║  ♪  ♫   ║
    ║          ║
    ║  ♪  ♫   ║
    ╚══════════╝
  ```

### Caching
- Cache extracted cover art to disk (`dataDir/cache/covers/`)
- Cache key: hash of file path + file modification time
- On subsequent plays, load from disk cache instead of re-extracting
- Max cache size: 100 MB, LRU eviction

### Supported Image Formats
- JPEG, PNG (primary)
- Optionally: BMP, GIF (non-animated)
- Terminal rendering will use Unicode half-block characters for grayscale approximation

## Implementation Plan

1. Add cover art extraction to `TrackMetadata` in `src/audio.nim`
2. Create `src/coverart.nim` module for loading, caching, and rendering cover art
3. Add cover art display to `src/ui.nim` NowPlayingView
4. Add default ASCII art fallback
5. Add caching logic
6. Update `schema.json` with cover art config options (enable/disable, max size)

## Affected Files
- `src/audio.nim` — add `coverArt` field to `TrackMetadata`, extraction logic
- `src/coverart.nim` — new file for cover art subsystem
- `src/ui.nim` — render cover art in NowPlayingView
- `src/state.nim` — add cover art cache path
- `schema.json` — add cover art config
