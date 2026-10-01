# Changelog

## 2.4.1

- The C# analysis engine is now compiled with optimizations. Measured on a real 56-track album, the analysis
  is 2.3x faster on all cores and 3x faster on a single thread; the results are unchanged.

## 2.4.0

- The launcher, the PowerShell 7 downloader and the analyzer are now a single file, `Lossless-Analyzer.bat`.
- All command-line parameters can be passed directly to the `.bat` file.
- FFT work buffers are reused instead of being re-allocated for every batch.
- A worker continues as soon as a file is finished instead of waiting in fixed polling steps.
- The progress dashboard is computed in the C# engine, which keeps it fast for very large batches.
- Tools are looked up in their usual place first instead of crawling the whole `tools` folder.
- Spectrogram file names are stable between runs, so a re-run overwrites the PNG instead of adding a new one.

## 2.3.1

- Last version that consisted of three files (`Lossless-Analyzer.bat`, `Get-PortablePowerShell.ps1`,
  `Test-LosslessAuthenticity.ps1`).
