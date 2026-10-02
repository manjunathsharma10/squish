# Squish for Windows

The Windows version of Squish, built with WPF on .NET 10. It has the same design, modes, presets and size predictions as the macOS app, and uses the codecs built into Windows wherever possible.

## Requirements

- Windows 10 (version 1809) or Windows 11, on x64 or Arm64.
- The [.NET 10 Desktop Runtime](https://dotnet.microsoft.com/download/dotnet/10.0) for the regular build, a 7 MB download. Most of that is Microsoft's WinRT bridge to the Windows imaging, PDF and media APIs. The standalone build includes the runtime and needs nothing else.
- Optional free or low-cost codec extensions from the Microsoft Store add more formats:

| Extension | Adds |
|---|---|
| HEIF Image Extensions | Reading HEIC photos, and **writing** HEIC (also needs HEVC Video Extensions) |
| HEVC Video Extensions | Reading and writing HEVC video; HEIC encoding |
| Webp Image Extensions | Reading WebP |
| AV1 Video Extension | Reading AVIF |
| Raw Image Extension | Reading camera RAW files |

Squish checks which encoders are present and only offers formats it can actually write.

## Build

```bash
dotnet publish Squish/Squish.csproj -c Release -r win-x64 --self-contained false -p:PublishSingleFile=true -o publish
```

The project also builds on macOS and Linux, because `EnableWindowsTargeting` is set, which is handy for checking that it compiles. It only runs on Windows.

## How it works

| Kind | Engine |
|---|---|
| Images | Windows.Graphics.Imaging (WIC). It decodes any format Windows has a codec for, and applies EXIF orientation and sRGB colour management in one pass. Lossy PNG uses the same palette quantizer as macOS, ported to C#. |
| PDF | PDFsharp rewrites the image streams directly: photos and plain RGB/grey bitmaps are downsampled and re-encoded as JPEG. This also reaches images inside form objects, which macOS's Quartz filter can't. |
| PDF → images | Windows.Data.Pdf, Windows' built-in renderer |
| Images → PDF | PDFsharp, one page per image |
| Video and audio | Media Foundation's MediaTranscoder, on the hardware H.264/HEVC encoders, with bitrates planned the same way as on macOS |

## Differences from the macOS app

- **Video:** MP4 output only, since Windows has no MOV writer. Matching tracks are re-encoded rather than copied losslessly.
- **Audio:** M4A, **MP3** and WAV. Windows can encode MP3 but not AIFF.
- **Images:** no AVIF output.
- **AAC bitrates:** 96, 128, 160 or 192 kbps, the only values Windows' AAC encoder accepts.
- **Recycle Bin:** replaced results go to the Recycle Bin rather than the Trash.

## Project layout

```
Squish/
  App.xaml(.cs)          Startup, styles, light/dark themes
  MainWindow.xaml(.cs)   The window: header, modes, presets, convert panel, queue, footer
  AppModel.cs            Queue, settings, running jobs, naming, size predictions
  Models.cs              File kinds, presets, formats, settings, queue items
  Controls.cs            Option rows, segmented switch, hairline slider, tracked caps
  Engines/               Imaging, ImageEngine, PaletteEncoder, PdfEngine, MediaEngine
  Themes/                Light.xaml, Dark.xaml
  DebugSnapshot.cs       Debug builds only: scripted UI run with screenshots (used by CI)
scripts/
  make-fixtures.ps1      Generates test files with ffmpeg
  run-snapshots.ps1      Runs a scripted pass and prints its log
```
