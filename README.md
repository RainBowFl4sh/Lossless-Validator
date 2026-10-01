# Lossless Audio Authenticity Analyzer

Detects **fake lossless** audio: files that look like FLAC, WAV or ALAC but were made from a lossy source
(MP3, AAC, ...), were upsampled, are padded to a fake bit depth, or are simply damaged.

It is a **single file** for Windows. Double-click it, drop your music on it, read the verdict.
Nothing is installed system-wide.

```text
     VERDICT       SCORE  FILE                    FORMAT              CUTOFF   TIME
   × LOSSY CODEC     100  renamed.wav             MP3 44.1k/f              -   0.1s
   × LIKELY FAKE      85  fake from mp3.flac      FLAC 44.1k/24     17.0 kHz   0.4s
   √ CLEAN +notes     10  real.flac               FLAC 44.1k/24            -   0.3s
```

> **Results are indications, not proof.** No program can prove that a file is truly lossless.
> See [Limitations](#limitations).

**Current version: 2.4.1** - see the [changelog](CHANGELOG.md).

## What's new in 2.4.1

- **About 2-3x faster.** The built-in analysis engine is now compiled with optimizations. On a real
  56-track album the run time dropped from 25.1 s to 10.8 s on all cores, and from 152.2 s to 50.5 s on a
  single thread.
- **Same results.** The verdicts, scores and findings for those 56 files are unchanged.
- Nothing else changed: same file, same menu, same parameters. Replace your old `Lossless-Analyzer.bat` with
  the new one; your `tools` folder and settings keep working.

## Quick start

1. Download `Lossless-Analyzer.bat` and put it in a folder of its own.
2. Double-click it, **or** drag files/folders onto it.
3. On the first run it offers to download what it needs (see [What gets downloaded](#what-gets-downloaded)).

That is all. The folder stays fully portable: copy it to another PC or a USB stick and it keeps working.

## Requirements

- Windows 10 or 11 (64-bit)
- An internet connection on the first run, unless the tools are already present

| Tool | Needed for | If it is missing |
| --- | --- | --- |
| PowerShell 7 | running the analyzer | offered as a portable download (about 100 MB) |
| ffmpeg + ffprobe | decoding and probing | offered as a portable download (about 110-190 MB) |
| flac | the official `flac -t` integrity test | optional, offered when FLAC files are analyzed (about 1.3 MB) |

A PowerShell 7, ffmpeg or flac that is already on your `PATH` is used as it is.

## What gets checked

| # | Check | What it finds |
| --- | --- | --- |
| 1 | Codec | A lossy codec in a lossless-looking wrapper, e.g. an `.m4a` holding AAC or a renamed MP3 |
| 2 | Integrity | `flac -t`, the MD5 stored in the FLAC header, sample count, decoder errors |
| 3 | Frequency cutoff | The low-pass that lossy encoders leave behind (about 16 kHz for MP3 128 kbit/s, about 20 kHz for MP3 V0/320) |
| 4 | Per-frame low-pass | A sharp spectral cliff in nearly every frame, fixed (CBR/ABR) or wandering (VBR) |
| 5 | Upsampling | A "96 kHz" file whose content ends at 22 kHz |
| 6 | Bit depth | A "24-bit" file that only uses 16 bits, or whose sample values still sit on a 16-bit grid |
| 7 | Stereo | Dual mono, channels out of phase, one silent channel |
| 8 | Signal | Clipping, DC offset, digital-silence dropouts, peak / RMS / crest factor |
| 9 | Metadata | Encoder strings and tags that mention `mp3`, `lame`, `aac`, `320kbps`, `transcoded`, ... |

Supported formats: FLAC, WAV, AIFF/AIFC, ALAC (`.m4a`), Monkey's Audio (APE), WavPack, TTA, TAK, Shorten,
MLP/TrueHD, CAF, W64 and MKA. DSD is skipped.

## Verdicts

Every finding adds suspicion points. The sum, capped at 100, decides the verdict.

| Verdict | Score | Meaning |
| --- | --- | --- |
| `CLEAN` | 0-9 | No relevant findings |
| `CLEAN (with notes)` | 10-29 | Only minor notes |
| `SUSPICIOUS` | 30-59 | Warning signs, check the spectrogram |
| `LIKELY FAKE` | 60-100 | Very probably made from a lossy source |
| `LOSSY CODEC` | 100 | The file natively contains a lossy codec |
| `DEFECTIVE` | 100 | The integrity check failed (damaged or truncated file) |
| `SKIPPED` | - | Not analyzable, e.g. DSD |

## Usage

### Interactive menu

Double-click `Lossless-Analyzer.bat`.

- `[1]` Analyze files or folders (type a path or drag & drop into the window)
- `[2]` Settings (saved to `LosslessAnalyzer.settings.json` next to the file)
- `[3]` Help (the complete built-in manual)
- `[4]` System & tool info

### Drag & drop

Drop files and/or folders onto `Lossless-Analyzer.bat`. They are analyzed, sub folders included, and the menu
opens afterwards.

### Command line

```bat
Lossless-Analyzer.bat -Path "D:\Music" -Recurse
Lossless-Analyzer.bat -Path "D:\Music\Album" -NoMenu -ReportCsv "D:\report.csv"
Lossless-Analyzer.bat -Path .\a.flac, .\b.wav -NoMenu -Detail Full
Lossless-Analyzer.bat -Help
```

Parameters use PowerShell syntax. Put quotes around paths that contain spaces, and use "double quotes" when a
path also contains characters such as `&`.

| Parameter | Description |
| --- | --- |
| `-Path <paths>` | Files and/or folders to analyze. Omit it to start the menu. |
| `-Recurse` | Include sub folders |
| `-Extensions <list>` | Extensions picked up when a folder is scanned |
| `-FftSize <n>` | `2048`, `4096`, `8192` (default) or `16384` |
| `-Threads <0-64>` | Files analyzed in parallel, `0` = automatic |
| `-CpuThreads <0-256>` | CPU thread budget, `0` = all logical threads |
| `-Detail <mode>` | `Auto`, `Full`, `Issues` or `Brief` |
| `-SpectrogramDir <dir>` | Write a spectrogram PNG per file into this folder |
| `-ReportCsv <file>` / `-ReportJson <file>` | Write report files |
| `-OutputDir <dir>` | Base folder for output created from the menu (default: `.\Output`) |
| `-FfmpegPath <file>` / `-FlacPath <file>` | Explicit tool locations |
| `-ToolsDir <dir>` | Folder for the portable tools (default: `.\tools`) |
| `-Yes` | Download missing tools without asking |
| `-NoMenu` | Exit after the analysis |
| `-PassThru` | Emit the result objects (use with `-NoMenu`) |
| `-Help` | Print the built-in help and exit |

## Reading a spectrogram

Enable spectrograms in Settings or pass `-SpectrogramDir`. Time runs left to right, frequency bottom to top.

- **Genuine lossless:** energy fades out smoothly towards the top, usually reaching 20-22 kHz.
- **Lossy source:** a razor-sharp horizontal ceiling (16 kHz for MP3 128, 19-20 kHz for higher bitrates), often
  with flickering holes in the treble.
- **Upsampled hi-res:** a 96 kHz file with a ceiling at 22 kHz, the upper half of the picture is empty.

## What gets downloaded

Downloads only happen after you answer `Y` (or pass `-Yes`), and only into the `tools` folder next to the file.

| Tool | Source | Verification |
| --- | --- | --- |
| PowerShell 7 | Latest release from [PowerShell/PowerShell](https://github.com/PowerShell/PowerShell/releases) | SHA-256 when the release publishes one |
| ffmpeg | [GyanD/codexffmpeg](https://github.com/GyanD/codexffmpeg/releases), then [yt-dlp/FFmpeg-Builds](https://github.com/yt-dlp/FFmpeg-Builds), [BtbN/FFmpeg-Builds](https://github.com/BtbN/FFmpeg-Builds) and [gyan.dev](https://www.gyan.dev/ffmpeg/builds/) as fallbacks | SHA-256 where the source publishes one |
| flac | [Xiph.Org](https://ftp.osuosl.org/pub/xiph/releases/flac/), then [xiph/flac](https://github.com/xiph/flac/releases) | none published |

Nothing is written to the registry, `AppData` or `PATH`. Delete the folder to remove everything.

## Folder layout

```text
Lossless-Analyzer.bat             the program
LosslessAnalyzer.settings.json    your settings (created when you change one)
tools\                            portable PowerShell 7, ffmpeg, flac (created on demand)
Output\                           reports and spectrograms (created on demand)
```

## How it works

`Lossless-Analyzer.bat` is a batch/PowerShell hybrid. `cmd` runs the first lines, finds or downloads
PowerShell 7 and hands the same file over to it; PowerShell treats the batch part as a comment.

The analysis engine is C# compiled at run time (with optimizations). It reads the PCM stream that ffmpeg
decodes and computes the FFT, the statistics and the MD5 in one pass. Several files are analyzed in parallel,
and CPU threads that are not needed for parallel files run the FFT of each file in parallel.

Keep the file encoded as **UTF-8 without BOM** and with **CRLF** line endings when you edit it. The
`.gitattributes` file in this repository stops Git from converting it.

## Performance

Measured with version 2.4.1 on an 8-core / 16-thread desktop CPU, FFT size 8192, mostly 44.1 and 48 kHz FLAC:

- **Where the time goes:** the spectrum analysis (FFT) is the largest part of the CPU work, followed by the
  per-sample statistics and the MD5. Decoding is cheap: ffmpeg decodes FLAC several thousand times faster
  than real time.
- **Typical speed:** a 56-track album takes about 11 s on all cores once the files are in the disk cache.
- **Large collections on a hard disk:** reading the files usually takes longer than analyzing them. At about
  100 MB/s a 125 GB collection needs roughly 20 minutes just to be read, so a faster CPU does not shorten
  the run.
- **No GPU support:** only the FFT could run on a GPU. It would add a vendor-specific dependency and break
  the single-file design, and on a hard disk the drive is the limit anyway.

## Limitations

- High-bitrate lossy sources (MP3 V0/320, AAC 256) end near 20 kHz, just like many genuine CD masters. Such
  cases are rated `SUSPICIOUS` at most.
- Old analog, tape or vinyl transfers can have a natural low-pass and look suspicious.
- A file that was lossy, then converted to lossless **and** mastered further can hide its traces.
- Fake 24-bit detection needs a few minutes of material. Heavy noise-shaped dither can hide the 16-bit grid.
- Mono and dual-mono recordings are legitimate; the tool only notes them.
- The launcher is Windows only. The PowerShell code contains Linux and macOS paths, but they are untested.

## Troubleshooting

| Problem | Solution |
| --- | --- |
| "ffmpeg not found" | Answer `Y` to the download prompt, or copy `ffmpeg.exe` and `ffprobe.exe` into `tools\ffmpeg` |
| Download fails (firewall, proxy, offline) | Download ffmpeg manually and place it as above, or pass `-FfmpegPath` |
| No colors or bars | Use Windows Terminal or a recent console |
| PC becomes sluggish during big batches | Lower the CPU thread budget in Settings `[2]` |
| Slow on a hard disk or network share | Reduce the number of workers in Settings `[1]` |
| `flac -t` reports errors | The file is damaged; re-rip or re-download it |

## License

[MIT](LICENSE)

ffmpeg, flac and PowerShell are separate projects with their own licenses. They are downloaded from their
official sources at run time and are not part of this repository.
