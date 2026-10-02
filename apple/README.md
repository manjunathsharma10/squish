# Squish

A small, native macOS app for compressing and converting images, PDFs, video and audio. Everything runs on your Mac using Apple's own frameworks. There are no dependencies, no network access, and the app is about 1.4 MB.

## Build

Requires macOS 14 or later and Xcode (or the Command Line Tools).

```bash
./scripts/build.sh
```

This produces `build/Squish.app`, a universal (Apple silicon + Intel), ad-hoc signed bundle. Drag it into `/Applications`, or run it in place:

```bash
open build/Squish.app
```

Because the app is ad-hoc signed rather than notarized, a Mac that didn't build it may need you to right-click → **Open** the first time.

## Using it

Squish has two modes. Switch between them at the top of the window, or with ⌘1 and ⌘2.

### Compress (⌘1)

Makes files smaller while keeping each one's format. The exception is audio, which becomes AAC (M4A).

1. Pick a preset: **Small**, **Balanced** or **High**. Once files are queued, each preset shows the predicted total size (for example "≈ 9.8 MB −87%").
2. Drop files or folders onto the window (or the Dock icon, or press ⌘O).
3. Press **Compress** (⌘↩).

**Fine-tune** sets quality, maximum size, video codec, metadata and where to save. With custom settings, the predicted total appears next to "Custom".

Results are saved as `name-squished.ext`. If a file can't be made meaningfully smaller, no new file is written and the row says so.

### Convert (⌘2)

Changes file types. Choose a target for each kind of file. Rows for kinds that aren't in the queue are dimmed.

| From | To |
|---|---|
| Images | JPEG, PNG, HEIC, AVIF, TIFF, or **PDF** (one PDF per image, or **Combine** all images into one PDF in queue order) |
| PDF | JPEG or PNG images of every page, at 150 or 300 DPI |
| Video | MP4 or MOV, in H.264 or HEVC |
| Audio | M4A (AAC), WAV or AIFF |

Converting changes the file type but not the size: images keep their full resolution, and PNG output is always lossless. Each row previews the change ("HEIC → JPEG") and the header shows the predicted total. If a video or audio track is already in the target codec, it's copied without re-encoding, so MOV (H.264) → MP4 is instant and lossless. Files already in the target format are skipped.

Converted files keep their name with the new extension (`photo.heic` → `photo.jpg`), or get `-converted` if that name is taken. Multi-page PDFs become a `name-pages` folder (`name-1.jpg`, `name-2.jpg`, …), and a combined PDF is named after its first image (`first-combined.pdf`).

### Either mode

Results go next to the originals unless you choose a folder. Originals are never modified. Changing a setting marks finished files as ready to run again. A re-run that would make the same kind of file replaces the previous result, which goes to the Trash. Converting to a different format keeps earlier results.

## What it does

| Kind | Reads | Writes | How |
|---|---|---|---|
| Images | JPEG, PNG, HEIC/HEIF, WebP, AVIF, TIFF, BMP, RAW, JPEG XL, PSD | JPEG, PNG, HEIC, AVIF, TIFF | ImageIO for resizing and re-encoding. Lossy PNG uses a built-in 256-colour palette quantizer (median cut, k-means, dithering), similar to pngquant. |
| PDF | PDF | PDF | A Quartz filter downsamples and recompresses embedded images. Text and vector graphics stay sharp and selectable. |
| Video | MP4, MOV, M4V, 3GP | MP4, MOV in HEVC or H.264 | AVAssetReader → AVAssetWriter on the hardware encoder, with bitrate scaled to resolution and frame rate. HDR (HLG/PQ) and rotation are preserved. |
| Audio | MP3, M4A, AAC, WAV, AIFF, FLAC, CAF | M4A (AAC), WAV, AIFF | AAC bitrate follows the quality setting. |

In Compress mode, images keep their format when macOS can write it. Otherwise they become PNG if they have transparency, or JPEG if they don't. Images → PDF stores opaque images as JPEG at the chosen quality and transparent ones losslessly.

### Presets

| | Quality | Max size (longest edge) |
|---|---|---|
| Small | 50 | 1920 px |
| Balanced | 72 | 3840 px |
| High | 88 | Original |

### How the predictions work

Predictions use the same code paths as compression, so they track the real result closely. In testing they were within 1–2%.

- **Images:** really encoded for each preset, in memory, so the figure is exact.
- **PDFs:** run through the real filter into a temporary file. Files over 150 MB are assumed to stay the same size. For PDF → images, up to three pages are rendered and the result scaled by the page count.
- **Video and audio:** calculated from the target bitrate and the duration, or from the source bitrate for copied tracks.

Estimates run in the background at low priority and pause while a batch compresses. In a large batch, the total is first extrapolated from the files estimated so far (shown dimmed), then refined until it's exact.

## Known limits

- **No WebP or MP3 output.** macOS has no encoder for either. WebP files are converted to JPEG or PNG, and MP3s to M4A.
- **Some PDFs won't shrink.** The Quartz filter can't reach images placed inside "form" objects, which some apps (Word, InDesign and others) use. Those PDFs are left as they are.
- **Animated GIFs are skipped** so they don't lose their animation.
- **Images → PDF puts one image on each page.** Pages are capped at A4's long edge (842 pt), and the image keeps its full resolution.

## Project layout

```
Sources/Squish/
  SquishApp.swift         App entry, window, menu, Dock drops
  AppModel.swift          Queue, settings, running jobs, output naming
  Models.swift            File kinds, presets, formats, formatting
  Engines/
    ImageEngine.swift     ImageIO resize / re-encode / convert, images → PDF
    PaletteEncoder.swift  Lossy PNG quantizer + PNG writer
    PDFEngine.swift       Quartz-filter PDF compression, PDF → page images
    MediaEngine.swift     AVFoundation transcoding and lossless stream copy
  Views/                  SwiftUI interface (Theme, ContentView, FileList)
  DebugSnapshot.swift     Debug builds only: scripted UI snapshots
scripts/
  build.sh                Builds and bundles Squish.app
  make-icon.swift         Draws the app icon
```

### Debug snapshots

Debug builds can drive the UI through its states and save window snapshots, which is handy for checking design changes:

```bash
swift build && SQUISH_SNAPSHOT=/tmp/snaps SQUISH_FILES=/path/a.jpg:/path/b.mov .build/debug/Squish
```

Optional variables: `SQUISH_PRESET` (`small`, `balanced` or `high`), `SQUISH_OUT` (output folder) and `SQUISH_SETTINGS` (settings as JSON, for example `{"mode":"convert","convert":{"image":"pdf","combineImages":true}}`).
