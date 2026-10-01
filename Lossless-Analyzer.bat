<# : batch launcher (cmd runs this part; PowerShell sees it as a comment)
@echo off
setlocal EnableExtensions
title Lossless Audio Authenticity Analyzer

rem ============================================================
rem  Lossless Audio Authenticity Analyzer - single file, fully portable
rem  - Double-click            : opens the interactive menu
rem  - Drop files/folders here : analyzes them first, then opens the menu
rem  - Command line            : Lossless-Analyzer.bat -Path "D:\Music" -Recurse -NoMenu   (see -Help)
rem  This file is a batch launcher and the PowerShell 7 program in one.
rem  Tools (PowerShell 7, ffmpeg, flac) live in the "tools" folder
rem  next to this file. Nothing is installed system-wide.
rem ============================================================

set "LA_SELF=%~f0"
set "LA_TOOLS=%~dp0tools"
set "PORTABLE_PWSH=%~dp0tools\powershell\pwsh.exe"
set "PWSH="
set "LA_ARGS="
set "LA_PATHS="

rem keep PowerShell from writing update/telemetry data
set "POWERSHELL_TELEMETRY_OPTOUT=1"
set "POWERSHELL_UPDATECHECK=Off"
set "DOTNET_CLI_TELEMETRY_OPTOUT=1"

rem --- Arguments: parameters (first one starts with "-") or dropped paths ---
set "LA_FIRST=%~1"
if not defined LA_FIRST goto findpwsh
if not "%LA_FIRST:~0,1%"=="-" goto collect
rem (no quotes around the assignment: quoted arguments must keep protecting characters like "&")
set LA_ARGS=%*
goto findpwsh

:collect
if "%~1"=="" goto findpwsh
if defined LA_PATHS (set "LA_PATHS=%LA_PATHS%|%~1") else set "LA_PATHS=%~1"
shift
goto collect

:findpwsh
rem --- 1. portable PowerShell next to this file ---
if exist "%PORTABLE_PWSH%" goto useportable

rem --- 2. PowerShell 7 already available on this PC ---
where pwsh >nul 2>&1
if not errorlevel 1 goto usepath

echo.
echo  PowerShell 7 was not found. It is required to run the analyzer.
echo  A portable copy (about 100 MB) can be downloaded into:
echo    %LA_TOOLS%\powershell
echo  Nothing is installed on this PC.
echo.
choice /c YN /m "Download portable PowerShell 7 now"
if errorlevel 2 goto nopwsh

rem the download script is embedded below (PWSH-BOOTSTRAP region) and runs in Windows PowerShell 5.1
powershell -NoProfile -ExecutionPolicy Bypass -Command "$m = [regex]::Match([IO.File]::ReadAllText($env:LA_SELF), '(?ms)^#region PWSH-BOOTSTRAP\r?$(.*?)^#endregion PWSH-BOOTSTRAP'); if (-not $m.Success) { Write-Host '  ERROR: embedded download script not found.'; exit 1 }; & ([scriptblock]::Create($m.Groups[1].Value)) -Destination (Join-Path $env:LA_TOOLS 'powershell')"
if errorlevel 1 goto fail
if not exist "%PORTABLE_PWSH%" goto fail

:useportable
set "PWSH=%PORTABLE_PWSH%"
goto run

:usepath
set "PWSH=pwsh"

:run
"%PWSH%" -NoProfile -ExecutionPolicy Bypass -Command "$sb = [scriptblock]::Create([IO.File]::ReadAllText($env:LA_SELF)); if ($env:LA_ARGS) { Invoke-Expression ('& $sb ' + $env:LA_ARGS) } elseif ($env:LA_PATHS) { & $sb -Path ($env:LA_PATHS -split '\|') -Recurse } else { & $sb }"
if errorlevel 1 goto fail
exit /b 0

:nopwsh
echo.
echo  PowerShell 7 is required. Run this file again and answer Y to the download,
echo  or place a portable PowerShell 7 in: %LA_TOOLS%\powershell

:fail
echo.
pause
exit /b 1

---- end of the batch part ----------------------------------------------------------------

#region PWSH-BOOTSTRAP
# Downloads a PORTABLE PowerShell 7 (zip, no installer) into the given folder.
# Must stay compatible with Windows PowerShell 5.1 (the launcher above runs it when pwsh is missing).
param([Parameter(Mandatory)][string]$Destination)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'   # progress rendering makes Invoke-WebRequest very slow in 5.1

try {
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'win-arm64' } else { 'win-x64' }
    Write-Host "  Looking up the latest PowerShell 7 release ($arch)..."
    $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest' -Headers @{ 'User-Agent' = 'LosslessAnalyzer' }
    $asset = $rel.assets | Where-Object { $_.name -match "^PowerShell-[\d\.]+-$arch\.zip$" } | Select-Object -First 1
    if (-not $asset) { throw 'No matching PowerShell release asset found.' }

    $parent = Split-Path -Parent $Destination
    $tmp = Join-Path $parent '_download'
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $zip = Join-Path $tmp $asset.name

    Write-Host ("  Downloading {0} ({1:N0} MB) - this can take a minute..." -f $asset.name, ($asset.size / 1MB))
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing

    if ($asset.PSObject.Properties['digest'] -and "$($asset.digest)" -match '^sha256:([0-9a-fA-F]{64})$') {
        $actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
        if ($actual -ne $Matches[1]) { throw "SHA-256 mismatch (expected $($Matches[1]), got $actual)" }
        Write-Host '  SHA-256 verified.'
    }

    Write-Host '  Extracting...'
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Expand-Archive -LiteralPath $zip -DestinationPath $Destination -Force

    if (-not (Test-Path -LiteralPath (Join-Path $Destination 'pwsh.exe'))) { throw 'pwsh.exe not found after extraction.' }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "  Portable PowerShell ready: $Destination"
    exit 0
}
catch {
    Write-Host ('  ERROR: ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
#endregion PWSH-BOOTSTRAP
#>

<#
.SYNOPSIS
    Lossless Audio Authenticity Analyzer - detects fake lossless files (FLAC, WAV, AIFF, ALAC, APE, WavPack, TTA, TAK ...).

.DESCRIPTION
    Interactive tool (main menu, settings, built-in help) with a multithreaded batch engine.
    Run without parameters for the menu, or pass -Path for direct use.

    Checks per file: real codec (lossless vs. lossy), integrity (flac -t, decoder errors, sample count, MD5),
    spectrum / frequency cutoff (MP3/AAC/Vorbis/Opus low-pass), upsampling, fake bit depth, stereo anomalies,
    clipping, DC offset, dropouts, suspicious metadata. Optional spectrogram PNGs and CSV/JSON reports.

    Required : ffmpeg + ffprobe   (offered as a portable download into .\tools next to the script)
    Optional : flac               (same - offered when FLAC files are analyzed)
    Nothing is installed system-wide and nothing is written to AppData: the folder stays fully portable.

    A script can never PROVE a file is truly lossless - it finds indications. See the built-in Help (menu [3] or -Help).

.PARAMETER Path          File(s) and/or folder(s) to analyze. Omit to start the interactive menu.
.PARAMETER Recurse       Include sub folders.
.PARAMETER Extensions    Extensions picked up when a folder is scanned.
.PARAMETER FftSize       FFT size: 2048 / 4096 / 8192 / 16384.
.PARAMETER Threads       Number of files analyzed in parallel (workers). 0 = automatic.
.PARAMETER CpuThreads    CPU thread budget. 0 (default) = use ALL detected logical threads. Threads not needed for
                 parallel files are used for a parallel FFT inside each file.
.PARAMETER Detail        Report detail: Auto, Full, Issues (full report only for files with findings), Brief.
.PARAMETER SpectrogramDir  Write a spectrogram PNG per file into this folder.
.PARAMETER ReportCsv / ReportJson  Write report files to these paths.
.PARAMETER OutputDir     Base folder for reports/spectrograms created from the menu (default: .\Output next to the script).
.PARAMETER FfmpegPath / FlacPath  Explicit paths to ffmpeg / flac.
.PARAMETER ToolsDir     Folder for the portable tools (ffmpeg, flac). Default: .\tools next to the script.
.PARAMETER Yes           Download missing tools without asking.
.PARAMETER NoMenu        Exit after the analysis instead of returning to the main menu.
.PARAMETER Help          Print the complete built-in help and exit.
.PARAMETER PassThru      Emit result objects to the pipeline (use with -NoMenu).

.EXAMPLE
    Lossless-Analyzer.bat
.EXAMPLE
    Lossless-Analyzer.bat -Path 'D:\Music' -Recurse -Threads 6 -SpectrogramDir 'D:\Spectro' -NoMenu
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string[]]$Path,
    [switch]$Recurse,
    [string[]]$Extensions = @('.flac', '.wav', '.wave', '.w64', '.aif', '.aiff', '.aifc', '.m4a', '.alac', '.caf',
                              '.ape', '.wv', '.tta', '.tak', '.shn', '.mka', '.mlp', '.thd'),
    [ValidateSet(2048, 4096, 8192, 16384)][int]$FftSize = 8192,
    [ValidateRange(0, 64)][int]$Threads = 0,
    [ValidateRange(0, 256)][int]$CpuThreads = 0,
    [ValidateSet('Auto', 'Full', 'Issues', 'Brief')][string]$Detail = 'Auto',
    [string]$SpectrogramDir,
    [string]$ReportCsv,
    [string]$ReportJson,
    [string]$OutputDir,
    [string]$FfmpegPath,
    [string]$FlacPath,
    [string]$ToolsDir,
    [switch]$Yes,
    [switch]$NoMenu,
    [switch]$Help,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'PowerShell 7 or newer is required. Start the analyzer by running Lossless-Analyzer.bat.' }
$ProgressPreference = 'SilentlyContinue'   # the built-in web/archive progress bars slow downloads down
$AppName = 'LOSSLESS AUDIO AUTHENTICITY ANALYZER'
$AppVersion = '2.4.1'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8; $OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$esc = [char]27

# ========================================================================================
#  C# engine: FLAC metadata parser, FFT, statistics, MD5, background analysis, progress board
# ========================================================================================
$csharp = @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Numerics;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace FlacTools
{
    public sealed class FlacInfo
    {
        public bool Valid;
        public string Error;
        public long FileSize;
        public long Id3Bytes;
        public int SampleRate;
        public int Channels;
        public int BitsPerSample;
        public long TotalSamples;
        public string Md5Hex;
        public int MinBlock, MaxBlock, MinFrame, MaxFrame;
        public string Vendor;
        public int PictureCount;
        public bool HasSeekTable;
        public long PaddingBytes;
    }

    public static class FlacMetaReader
    {
        static bool ReadFully(Stream s, byte[] buf, int count)
        {
            int off = 0;
            while (off < count)
            {
                int n = s.Read(buf, off, count - off);
                if (n <= 0) return false;
                off += n;
            }
            return true;
        }

        static long LE32(byte[] b, int o)
        {
            return (long)((uint)b[o] | ((uint)b[o + 1] << 8) | ((uint)b[o + 2] << 16) | ((uint)b[o + 3] << 24));
        }

        public static FlacInfo Read(string path)
        {
            var m = new FlacInfo();
            try
            {
                using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                {
                    m.FileSize = fs.Length;
                    long pos = 0;
                    byte[] hdr = new byte[10];
                    int n = fs.Read(hdr, 0, 10);
                    if (n == 10 && hdr[0] == 'I' && hdr[1] == 'D' && hdr[2] == '3')
                    {
                        int size = ((hdr[6] & 0x7F) << 21) | ((hdr[7] & 0x7F) << 14) | ((hdr[8] & 0x7F) << 7) | (hdr[9] & 0x7F);
                        bool footer = (hdr[5] & 0x10) != 0;
                        pos = 10 + size + (footer ? 10 : 0);
                        m.Id3Bytes = pos;
                    }
                    fs.Position = pos;
                    byte[] sig = new byte[4];
                    if (!ReadFully(fs, sig, 4) || sig[0] != 'f' || sig[1] != 'L' || sig[2] != 'a' || sig[3] != 'C')
                    {
                        m.Error = "No 'fLaC' signature at the start of the file.";
                        return m;
                    }
                    bool last = false;
                    while (!last)
                    {
                        int h = fs.ReadByte();
                        if (h < 0) { m.Error = "Metadata area truncated."; return m; }
                        last = (h & 0x80) != 0;
                        int type = h & 0x7F;
                        byte[] l3 = new byte[3];
                        if (!ReadFully(fs, l3, 3)) { m.Error = "Metadata block header truncated."; return m; }
                        int len = (l3[0] << 16) | (l3[1] << 8) | l3[2];
                        long next = fs.Position + len;
                        if (next > fs.Length) { m.Error = "Metadata block extends past end of file."; return m; }

                        if (type == 0 && len >= 34)
                        {
                            byte[] b = new byte[len];
                            ReadFully(fs, b, len);
                            m.MinBlock = (b[0] << 8) | b[1];
                            m.MaxBlock = (b[2] << 8) | b[3];
                            m.MinFrame = (b[4] << 16) | (b[5] << 8) | b[6];
                            m.MaxFrame = (b[7] << 16) | (b[8] << 8) | b[9];
                            ulong packed = 0;
                            for (int i = 10; i < 18; i++) packed = (packed << 8) | b[i];
                            m.SampleRate = (int)(packed >> 44);
                            m.Channels = (int)((packed >> 41) & 7) + 1;
                            m.BitsPerSample = (int)((packed >> 36) & 0x1F) + 1;
                            m.TotalSamples = (long)(packed & 0xFFFFFFFFFUL);
                            var sb = new StringBuilder();
                            for (int i = 18; i < 34; i++) sb.Append(b[i].ToString("x2"));
                            m.Md5Hex = sb.ToString();
                        }
                        else if (type == 4 && len >= 8 && len < 16 * 1024 * 1024)
                        {
                            byte[] b = new byte[len];
                            ReadFully(fs, b, len);
                            long vl = LE32(b, 0);
                            if (4 + vl <= len) m.Vendor = Encoding.UTF8.GetString(b, 4, (int)vl);
                        }
                        else if (type == 3) m.HasSeekTable = true;
                        else if (type == 6) m.PictureCount++;
                        else if (type == 1) m.PaddingBytes += len;

                        fs.Position = next;
                    }
                    m.Valid = m.SampleRate > 0 && m.BitsPerSample > 0;
                    if (!m.Valid) m.Error = "STREAMINFO missing or invalid.";
                }
            }
            catch (Exception ex)
            {
                m.Error = ex.Message;
            }
            return m;
        }
    }

    public sealed class AudioStats
    {
        public int Channels, SampleRate, Bits;
        public long Frames;
        public double[] AvgPower;
        public double[] ChPeak, ChRms, ChDc;
        public long[] ChClipSamples, ChClipRuns;
        public long ZeroFrames, LeadingZeroFrames, TrailingZeroFrames, InternalZeroRuns, LongestInternalZero;
        public long IdenticalFrames;
        public double Corr;
        public int EffectiveBits;
        public bool AllSilent;
        public string Md5Hex;
        public int SpectrumFrames;
        public int FftThreadsUsed;
        public long TFramesValid, TFramesCliff;
        public double TModeHz, TModeShare, TMedianHz, TP10Hz, TP90Hz;
        public long DistinctValues, OccWindowSamples, OccOccupied, OccSlots;
        public int ExitCode;
        public string FfmpegErrors;
    }

    // Handle returned to PowerShell so it can poll the progress while the analysis runs in the background.
    public sealed class AnalysisJob
    {
        public long TotalFrames;
        long done;
        public Task<AudioStats> Completion;
        public long Done { get { return Interlocked.Read(ref done); } }
        internal void Report(long v) { Interlocked.Exchange(ref done, v); }
    }

    // Thread-safe state shared between the worker runspaces and the dashboard of the main thread.
    public sealed class FileState
    {
        public string Name;
        public volatile string Status = "Queued";
        public double Percent;
        public int State;            // 0 = queued, 1 = running, 2 = finished
        public volatile string Verdict;
        public int Score;
        public long StartTicks, EndTicks;
    }

    public sealed class ProgressBoard
    {
        public readonly FileState[] Files;
        int done;
        public ProgressBoard(string[] names)
        {
            Files = new FileState[names.Length];
            for (int i = 0; i < names.Length; i++) Files[i] = new FileState { Name = names[i] };
        }
        public int DoneCount { get { return Volatile.Read(ref done); } }
        // Dashboard helpers: one pass over all files without going through the PowerShell pipeline.
        public double AveragePercent()
        {
            if (Files.Length == 0) return 0.0;
            double sum = 0;
            for (int i = 0; i < Files.Length; i++) sum += Files[i].Percent;
            return sum / Files.Length;
        }
        public FileState[] GetRunning(int max)
        {
            var list = new List<FileState>();
            for (int i = 0; i < Files.Length && list.Count < max; i++)
            {
                if (Files[i].State == 1) list.Add(Files[i]);
            }
            return list.ToArray();
        }
        public void Start(int i)
        {
            var f = Files[i];
            f.Status = "Starting...";
            f.Percent = 0;
            f.StartTicks = DateTime.UtcNow.Ticks;
            f.State = 1;
        }
        public void Update(int i, string status, double pct)
        {
            var f = Files[i];
            f.Status = status;
            f.Percent = pct;
        }
        public void Finish(int i, string verdict, int score)
        {
            var f = Files[i];
            f.Verdict = verdict;
            f.Score = score;
            f.Percent = 100;
            f.Status = "Done";
            f.EndTicks = DateTime.UtcNow.Ticks;
            f.State = 2;
            Interlocked.Increment(ref done);
        }
    }

    internal sealed class Fft
    {
        readonly int n;
        readonly int[] rev;
        readonly double[] cs, sn;

        public Fft(int n)
        {
            this.n = n;
            int bitsN = 0;
            while ((1 << bitsN) < n) bitsN++;
            rev = new int[n];
            for (int i = 0; i < n; i++) rev[i] = (rev[i >> 1] >> 1) | ((i & 1) << (bitsN - 1));
            cs = new double[n / 2];
            sn = new double[n / 2];
            for (int i = 0; i < n / 2; i++)
            {
                cs[i] = Math.Cos(2.0 * Math.PI * i / n);
                sn[i] = -Math.Sin(2.0 * Math.PI * i / n);
            }
        }

        public void Transform(double[] re, double[] im)
        {
            for (int i = 0; i < n; i++)
            {
                int j = rev[i];
                if (j > i)
                {
                    double t = re[i]; re[i] = re[j]; re[j] = t;
                    t = im[i]; im[i] = im[j]; im[j] = t;
                }
            }
            for (int size = 2; size <= n; size <<= 1)
            {
                int half = size >> 1;
                int step = n / size;
                for (int i = 0; i < n; i += size)
                {
                    for (int j = 0, k = 0; j < half; j++, k += step)
                    {
                        double wr = cs[k], wi = sn[k];
                        int a = i + j, b = a + half;
                        double tr = re[b] * wr - im[b] * wi;
                        double ti = re[b] * wi + im[b] * wr;
                        re[b] = re[a] - tr; im[b] = im[a] - ti;
                        re[a] += tr; im[a] += ti;
                    }
                }
            }
        }
    }

    public sealed class ProcResult
    {
        public int ExitCode;
        public string Output;
        public string Error;
    }

    // Runs an external program in the background (used for flac -t and spectrogram rendering).
    public sealed class ProcRun
    {
        public Task<ProcResult> Completion;

        public static ProcRun Start(string exe, string[] args)
        {
            var pr = new ProcRun();
            pr.Completion = Task.Run(() =>
            {
                var psi = new ProcessStartInfo(exe)
                {
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                };
                foreach (var a in args) psi.ArgumentList.Add(a);
                using (var p = Process.Start(psi))
                {
                    Task<string> o = p.StandardOutput.ReadToEndAsync();
                    Task<string> e = p.StandardError.ReadToEndAsync();
                    p.WaitForExit();
                    return new ProcResult { ExitCode = p.ExitCode, Output = o.Result, Error = e.Result };
                }
            });
            return pr;
        }
    }

    public static class AudioAnalyzer
    {
        sealed class Local
        {
            public double[] Re, Im, Pm, Lvl;
            public double[][] Acc;
            public int[] Cnt;
            public Local(int ch, int fftSize, int bins, int nbA)
            {
                Re = new double[fftSize];
                Im = new double[fftSize];
                Pm = new double[bins];
                Lvl = new double[nbA];
                Acc = new double[ch][];
                for (int c = 0; c < ch; c++) Acc[c] = new double[bins];
                Cnt = new int[ch];
            }
        }

        // bits = 0 -> unknown / floating point (bit-depth dependent statistics are then meaningless)
        public static AnalysisJob Start(string ffmpeg, string file, int channels, int sampleRate, int bits, int fftSize, int fftThreads, long totalFrames)
        {
            var job = new AnalysisJob { TotalFrames = totalFrames };
            job.Completion = Task.Run(() => Run(ffmpeg, file, channels, sampleRate, bits, fftSize, fftThreads, job));
            return job;
        }

        static AudioStats Run(string ffmpeg, string file, int channels, int sampleRate, int bits, int fftSize, int fftThreads, AnalysisJob job)
        {
            var psi = new ProcessStartInfo(ffmpeg)
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };
            string[] a = { "-hide_banner", "-nostdin", "-v", "error", "-err_detect", "crccheck+bitstream",
                           "-i", file, "-map", "0:a:0", "-vn", "-sn", "-dn", "-f", "s32le", "-acodec", "pcm_s32le", "-" };
            foreach (var x in a) psi.ArgumentList.Add(x);

            using (var p = Process.Start(psi))
            {
                Task<string> errTask = p.StandardError.ReadToEndAsync();
                AudioStats st;
                try
                {
                    st = Analyze(p.StandardOutput.BaseStream, channels, sampleRate, bits, fftSize, fftThreads, job);
                }
                catch
                {
                    try { p.Kill(true); } catch { }
                    throw;
                }
                p.WaitForExit();
                st.ExitCode = p.ExitCode;
                st.FfmpegErrors = errTask.Result;
                return st;
            }
        }

        static AudioStats Analyze(Stream s, int ch, int sr, int declaredBits, int fftSize, int fftThreads, AnalysisJob job)
        {
            int bits = declaredBits <= 0 ? 32 : Math.Min(declaredBits, 32);
            fftThreads = Math.Max(1, fftThreads);
            var st = new AudioStats { Channels = ch, SampleRate = sr, Bits = declaredBits, FftThreadsUsed = fftThreads };
            int half = fftSize / 2;
            int bins = half + 1;
            int shift = Math.Max(0, 32 - bits);
            int bps = (bits + 7) / 8;
            long maxVal = bits >= 32 ? int.MaxValue : (1L << (bits - 1)) - 1;
            long minVal = -(maxVal + 1);
            const double inv = 1.0 / 2147483648.0;

            var fft = new Fft(fftSize);
            double[] win = new double[fftSize];
            double wsum = 0;
            for (int i = 0; i < fftSize; i++)
            {
                win[i] = 0.5 - 0.5 * Math.Cos(2.0 * Math.PI * i / fftSize);
                wsum += win[i];
            }
            double norm = 1.0 / ((wsum / 2.0) * (wsum / 2.0));   // full-scale sine => 0 dB

            // ---- per-frame (time-resolved) low-pass analysis setup ----
            const double bw = 250.0;
            const int tWin = 4;
            double binHz = (double)sr / fftSize;
            int nbT = (int)Math.Floor((sr / 2.0) / bw);
            int nbA = Math.Max(1, nbT);
            int[] bandLo = new int[nbA];
            int[] bandHi = new int[nbA];
            for (int bI = 0; bI < nbT; bI++)
            {
                int lo = Math.Max(1, (int)Math.Floor(bI * bw / binHz));
                int hi = Math.Min(half, (int)Math.Ceiling((bI + 1) * bw / binHz));
                if (hi < lo) hi = lo;
                bandLo[bI] = lo;
                bandHi[bI] = hi;
            }
            int refLo = Math.Max(1, (int)Math.Floor(1000.0 / binHz));
            int refHi = Math.Min(half, (int)Math.Ceiling(6000.0 / binHz));
            int tFirst = (int)Math.Ceiling(8000.0 / bw);
            int tLast = nbT - tWin;
            bool temporalOk = tLast > tFirst && refHi > refLo;
            int[] cliffHist = new int[nbA + 1];
            long tValid = 0, tCliff = 0;

            double[][] buf = new double[ch][];
            double[][] acc = new double[ch][];
            int[] specCount = new int[ch];
            for (int c = 0; c < ch; c++) { buf[c] = new double[fftSize]; acc[c] = new double[bins]; }
            int fill = 0;

            // frames are collected in batches and transformed on several threads
            int batchSize = Math.Max(1, fftThreads * 4);
            double[][][] batch = new double[batchSize][][];
            for (int q = 0; q < batchSize; q++)
            {
                batch[q] = new double[ch][];
                for (int c = 0; c < ch; c++) batch[q][c] = new double[fftSize];
            }
            int[] cliffRes = new int[batchSize];
            int bj = 0;
            long framesQueued = 0;
            // FFT work buffers are pooled and reused across batches (they are large; re-allocating them
            // for every batch keeps the garbage collector busy). Their spectra are merged once at the end.
            var locals = new List<Local>();
            var pool = new ConcurrentBag<Local>();
            Local seqLocal = null;
            if (fftThreads <= 1) { seqLocal = new Local(ch, fftSize, bins, nbA); locals.Add(seqLocal); }
            Func<Local> rentLocal = () =>
            {
                Local l;
                if (pool.TryTake(out l)) return l;
                l = new Local(ch, fftSize, bins, nbA);
                lock (locals) locals.Add(l);
                return l;
            };
            var parOpts = new ParallelOptions { MaxDegreeOfParallelism = fftThreads };

            long[] peak = new long[ch];
            double[] sumSq = new double[ch], sumDc = new double[ch];
            long[] clipS = new long[ch], clipR = new long[ch], run = new long[ch];
            int[] runSign = new int[ch];
            int orBits = 0;
            long frames = 0, zeroFrames = 0, leading = 0, internalRuns = 0, longest = 0, zeroRun = 0, identical = 0;
            bool seenNonZero = false;
            double sL = 0, sR = 0, sLL = 0, sRR = 0, sLR = 0;

            // bit-depth evidence (17..24 bit): distinct values + occupancy of the range around zero
            ulong[] seen = (declaredBits > 16 && bits <= 24) ? new ulong[(int)((1L << bits) >> 6)] : null;
            int occW = (seen != null) ? (1 << (bits - 9)) : 0;
            bool[] occ = (seen != null) ? new bool[2 * occW + 1] : null;
            long occIn = 0;

            var md5 = IncrementalHash.CreateHash(HashAlgorithmName.MD5);
            int frameBytes = 4 * ch;
            const int chunkFrames = 8192;
            byte[] raw = new byte[frameBytes * chunkFrames];
            byte[] md5buf = new byte[bps * ch * chunkFrames];
            int[] cur = new int[ch];
            int have = 0;

            void Merge(Local L)
            {
                for (int c = 0; c < ch; c++)
                {
                    double[] a = acc[c];
                    double[] bb = L.Acc[c];
                    for (int k = 0; k < bins; k++) a[k] += bb[k];
                    specCount[c] += L.Cnt[c];
                }
            }

            void ProcessFrame(int fj, Local L)
            {
                int used = 0;
                Array.Clear(L.Pm, 0, bins);
                for (int c = 0; c < ch; c++)
                {
                    double[] bf = batch[fj][c];
                    bool any = false;
                    for (int i = 0; i < fftSize; i++) { if (bf[i] != 0.0) { any = true; break; } }
                    if (!any) continue;
                    for (int i = 0; i < fftSize; i++) { L.Re[i] = bf[i] * win[i]; L.Im[i] = 0.0; }
                    fft.Transform(L.Re, L.Im);
                    double[] ac = L.Acc[c];
                    for (int k = 0; k < bins; k++)
                    {
                        double pw = (L.Re[k] * L.Re[k] + L.Im[k] * L.Im[k]) * norm;
                        ac[k] += pw;
                        L.Pm[k] += pw;
                    }
                    L.Cnt[c]++;
                    used++;
                }
                cliffRes[fj] = -2;
                if (used == 0 || !temporalOk) return;
                double invUsed = 1.0 / used;
                double refSum = 0;
                for (int k = refLo; k <= refHi; k++) refSum += L.Pm[k];
                double refDb = 10.0 * Math.Log10(refSum * invUsed / (refHi - refLo + 1) + 1e-20);
                if (refDb < -95.0) return;
                for (int bI = 0; bI < nbT; bI++)
                {
                    double sm = 0;
                    int lo = bandLo[bI], hi = bandHi[bI];
                    for (int k = lo; k <= hi; k++) sm += L.Pm[k];
                    L.Lvl[bI] = 10.0 * Math.Log10(sm * invUsed / (hi - lo + 1) + 1e-20);
                }
                int best = -1;
                double bestDrop = -999.0;
                for (int i = tFirst; i <= tLast; i++)
                {
                    double below = 0, above = 0;
                    for (int k = 1; k <= tWin; k++) { below += L.Lvl[i - k]; above += L.Lvl[i + k - 1]; }
                    double drop = (below - above) / tWin;
                    if (drop > bestDrop) { bestDrop = drop; best = i; }
                }
                cliffRes[fj] = bestDrop >= 25.0 ? best : -1;
            }

            void ProcessBatch(int count)
            {
                if (count <= 0) return;
                if (fftThreads <= 1)
                {
                    for (int fj = 0; fj < count; fj++) ProcessFrame(fj, seqLocal);
                }
                else
                {
                    Parallel.For<Local>(0, count, parOpts, rentLocal,
                        (pj, state, loc) => { ProcessFrame(pj, loc); return loc; },
                        loc => pool.Add(loc));
                }
                for (int fj = 0; fj < count; fj++)
                {
                    int cr = cliffRes[fj];
                    if (cr == -2) continue;
                    tValid++;
                    if (cr >= 0) { tCliff++; cliffHist[cr]++; }
                }
            }

            while (true)
            {
                int n = s.Read(raw, have, raw.Length - have);
                if (n <= 0) break;
                have += n;
                int nf = have / frameBytes;
                int mp = 0;
                for (int f = 0; f < nf; f++)
                {
                    int off = f * frameBytes;
                    bool allZero = true;
                    for (int c = 0; c < ch; c++)
                    {
                        int v = BitConverter.ToInt32(raw, off + 4 * c);
                        cur[c] = v;
                        orBits |= v;
                        if (v != 0) allZero = false;
                        long av = v < 0 ? -(long)v : v;
                        if (av > peak[c]) peak[c] = av;
                        double x = v * inv;
                        sumSq[c] += x * x;
                        sumDc[c] += x;
                        long o = (long)(v >> shift);
                        int sign = o >= maxVal ? 1 : (o <= minVal ? -1 : 0);
                        if (sign != 0)
                        {
                            clipS[c]++;
                            if (sign == runSign[c]) run[c]++; else { run[c] = 1; runSign[c] = sign; }
                            if (run[c] == 3) clipR[c]++;
                        }
                        else { run[c] = 0; runSign[c] = 0; }
                        if (seen != null)
                        {
                            long idx = o + (1L << (bits - 1));
                            seen[(int)(idx >> 6)] |= 1UL << (int)(idx & 63);
                            if (o != 0 && o >= -occW && o <= occW) { occIn++; occ[o + occW] = true; }
                        }
                        for (int b = 0; b < bps; b++) md5buf[mp++] = (byte)(o >> (8 * b));
                        buf[c][fill] = x;
                    }
                    if (allZero)
                    {
                        zeroFrames++; zeroRun++;
                        if (!seenNonZero) leading++;
                    }
                    else
                    {
                        if (seenNonZero && zeroRun >= 32)
                        {
                            internalRuns++;
                            if (zeroRun > longest) longest = zeroRun;
                        }
                        zeroRun = 0;
                        seenNonZero = true;
                    }
                    if (ch >= 2)
                    {
                        int l = cur[0], r = cur[1];
                        if (l == r) identical++;
                        double xl = l * inv, xr = r * inv;
                        sL += xl; sR += xr; sLL += xl * xl; sRR += xr * xr; sLR += xl * xr;
                    }
                    frames++;
                    fill++;
                    if (fill == fftSize)
                    {
                        for (int c = 0; c < ch; c++)
                        {
                            Array.Copy(buf[c], 0, batch[bj][c], 0, fftSize);
                            Array.Copy(buf[c], half, buf[c], 0, half);
                        }
                        bj++;
                        framesQueued++;
                        fill = half;
                        if (bj == batchSize) { ProcessBatch(bj); bj = 0; }
                    }
                }
                md5.AppendData(md5buf, 0, mp);
                int usedBytes = nf * frameBytes;
                have -= usedBytes;
                if (have > 0) Buffer.BlockCopy(raw, usedBytes, raw, 0, have);
                if (job != null) job.Report(frames);
            }

            if (bj > 0) { ProcessBatch(bj); bj = 0; }
            // very short file: pad with zeros once
            if (framesQueued == 0 && fill > 0)
            {
                for (int c = 0; c < ch; c++)
                {
                    for (int i = fill; i < fftSize; i++) buf[c][i] = 0.0;
                    Array.Copy(buf[c], 0, batch[0][c], 0, fftSize);
                }
                ProcessBatch(1);
            }
            foreach (var l in locals) Merge(l);

            st.Frames = frames;
            st.ChPeak = new double[ch]; st.ChRms = new double[ch]; st.ChDc = new double[ch];
            st.ChClipSamples = clipS; st.ChClipRuns = clipR;
            for (int c = 0; c < ch; c++)
            {
                st.ChPeak[c] = peak[c] * inv;
                st.ChRms[c] = frames > 0 ? Math.Sqrt(sumSq[c] / frames) : 0.0;
                st.ChDc[c] = frames > 0 ? sumDc[c] / frames : 0.0;
            }
            st.ZeroFrames = zeroFrames;
            st.LeadingZeroFrames = leading;
            st.TrailingZeroFrames = seenNonZero ? zeroRun : 0;
            st.InternalZeroRuns = internalRuns;
            st.LongestInternalZero = longest;
            st.IdenticalFrames = identical;
            st.Corr = double.NaN;
            if (ch >= 2 && frames > 1)
            {
                double nn = frames;
                double num = sLR - sL * sR / nn;
                double den = Math.Sqrt(Math.Max(0, sLL - sL * sL / nn) * Math.Max(0, sRR - sR * sR / nn));
                if (den > 1e-20) st.Corr = num / den;
            }
            if (orBits == 0) { st.AllSilent = true; st.EffectiveBits = 0; }
            else
            {
                uint u = (uint)orBits; int tz = 0;
                while ((u & 1u) == 0) { tz++; u >>= 1; }
                st.EffectiveBits = 32 - tz;
            }
            st.Md5Hex = BitConverter.ToString(md5.GetHashAndReset()).Replace("-", "").ToLowerInvariant();

            if (seen != null)
            {
                long dsum = 0;
                for (int w = 0; w < seen.Length; w++) dsum += BitOperations.PopCount(seen[w]);
                st.DistinctValues = dsum;
                long oc = 0;
                for (int w = 0; w < occ.Length; w++) { if (w != occW && occ[w]) oc++; }
                st.OccOccupied = oc;
                st.OccSlots = 2L * occW;
                st.OccWindowSamples = occIn;
            }

            st.TFramesValid = tValid;
            st.TFramesCliff = tCliff;
            if (tCliff > 0)
            {
                int bestIdx = 0;
                long bestSum = -1;
                for (int i = 0; i < cliffHist.Length; i++)
                {
                    long sm = 0;
                    int d1 = Math.Max(0, i - 2), d2 = Math.Min(cliffHist.Length - 1, i + 2);
                    for (int d = d1; d <= d2; d++) sm += cliffHist[d];
                    if (sm > bestSum) { bestSum = sm; bestIdx = i; }
                }
                st.TModeHz = bestIdx * bw;
                st.TModeShare = (double)bestSum / tCliff;
                long cum = 0;
                double p10 = 0, p50 = 0, p90 = 0;
                bool g10 = false, g50 = false, g90 = false;
                for (int i = 0; i < cliffHist.Length; i++)
                {
                    cum += cliffHist[i];
                    double fr = (double)cum / tCliff;
                    if (!g10 && fr >= 0.10) { p10 = i * bw; g10 = true; }
                    if (!g50 && fr >= 0.50) { p50 = i * bw; g50 = true; }
                    if (!g90 && fr >= 0.90) { p90 = i * bw; g90 = true; }
                }
                st.TMedianHz = p50; st.TP10Hz = p10; st.TP90Hz = p90;
            }

            double[] avg = new double[bins];
            int usedCh = 0, maxSpec = 0;
            for (int c = 0; c < ch; c++)
            {
                if (specCount[c] > 0)
                {
                    usedCh++;
                    if (specCount[c] > maxSpec) maxSpec = specCount[c];
                    for (int k = 0; k < bins; k++) avg[k] += acc[c][k] / specCount[c];
                }
            }
            if (usedCh > 0)
            {
                for (int k = 0; k < bins; k++) avg[k] /= usedCh;
                st.AvgPower = avg;
                st.SpectrumFrames = maxSpec;
            }
            return st;
        }
    }
}
'@

# ========================================================================================
#  Settings (session based; changeable in the Settings menu)
# ========================================================================================
# LA_SELF is set by the batch launcher (the script then runs as a script block, without $PSScriptRoot)
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } elseif ($env:LA_SELF) { Split-Path -Parent $env:LA_SELF } else { (Get-Location).Path }
$ToolsRoot = if ($ToolsDir) { $ToolsDir } else { Join-Path $scriptDir 'tools' }
$script:AllResults = [System.Collections.Generic.List[object]]::new()
$script:flacDeclined = $false
$script:ffmpeg = $null; $script:ffprobe = $null; $script:flac = $null; $script:Sys = $null

# ========================================================================================
#  UI helpers
# ========================================================================================
function Set-ConsoleSize {
    # Default console is 120x30; enlarge it by about 25 % (150x38) at startup. Never shrinks an already larger window.
    # Works in the classic console host (Windows 10 / cmd). Windows Terminal ignores or rejects this - that is fine.
    if ([Console]::IsOutputRedirected) { return }
    try {
        $raw = $Host.UI.RawUI
        $cur = $raw.WindowSize
        $max = $raw.MaxPhysicalWindowSize
        $w = [Math]::Min($max.Width, [Math]::Max($cur.Width, 150))
        $h = [Math]::Min($max.Height, [Math]::Max($cur.Height, 38))
        if ($w -le $cur.Width -and $h -le $cur.Height) { return }
        $buf = $raw.BufferSize
        $raw.BufferSize = [System.Management.Automation.Host.Size]::new($w, [Math]::Max($buf.Height, $h))
        $raw.WindowSize = [System.Management.Automation.Host.Size]::new($w, $h)
    }
    catch { }
}

function Get-ConsoleWidth {
    try { return [Math]::Max(70, [Math]::Min(140, [Console]::WindowWidth - 1)) } catch { return 100 }
}

function Limit-Text {
    param([string]$Text, [int]$Max)
    if ($null -eq $Text) { $Text = '' }
    if ($Text.Length -le $Max) { return $Text.PadRight($Max) }
    return $Text.Substring(0, [Math]::Max(1, $Max - 1)) + '…'
}

function Format-Bar {
    param([double]$Percent, [int]$Width = 20)
    $p = [Math]::Min(100, [Math]::Max(0, $Percent))
    $f = [int][Math]::Round($Width * $p / 100)
    return ('█' * $f) + ('░' * ($Width - $f))
}

function Format-Time {
    param($Seconds)
    if ($null -eq $Seconds) { return '?' }
    $t = [TimeSpan]::FromSeconds([Math]::Max(0, $Seconds))
    if ($t.TotalHours -ge 1) { return $t.ToString('h\:mm\:ss') }
    return $t.ToString('m\:ss')
}

function Format-Wrapped {
    param([string]$Text, [int]$Width = 100, [string]$Indent = '        ')
    $out = [System.Collections.Generic.List[string]]::new()
    $line = ''
    foreach ($w in ($Text -split '\s+')) {
        if (($line.Length + $w.Length + 1) -gt $Width) { $out.Add($Indent + $line.Trim()); $line = '' }
        $line += "$w "
    }
    if ($line.Trim()) { $out.Add($Indent + $line.Trim()) }
    return $out
}

function Write-Banner {
    param([string]$Section = '')
    try { Clear-Host } catch { }
    $w = [Math]::Min(96, (Get-ConsoleWidth) - 2)
    $inner = $w - 2
    $title = "  ♪  $AppName"
    $ver = "v$AppVersion  "
    $line1 = $title.PadRight($inner - $ver.Length) + $ver
    $sub = if ($Section) { "  » $Section" } else { '     fake lossless · upsampling · fake bit depth · damaged files' }
    Write-Host (' ╔' + ('═' * $inner) + '╗') -ForegroundColor Cyan
    Write-Host (' ║' + (Limit-Text $line1 $inner) + '║') -ForegroundColor Cyan
    Write-Host (' ║' + (Limit-Text $sub $inner) + '║') -ForegroundColor DarkCyan
    Write-Host (' ╚' + ('═' * $inner) + '╝') -ForegroundColor Cyan
}

function Write-Rule {
    param([string]$Title = '', [string]$Color = 'DarkGray')
    $w = (Get-ConsoleWidth) - 2
    if ($Title) {
        $t = "─ $Title "
        Write-Host (' ' + $t + ('─' * [Math]::Max(1, $w - $t.Length))) -ForegroundColor $Color
    }
    else { Write-Host (' ' + ('─' * $w)) -ForegroundColor $Color }
}

function Read-MenuKey {
    param([string]$Prompt = '  Select an option » ')
    Write-Host ''
    Write-Host $Prompt -NoNewline -ForegroundColor Cyan
    if ([Console]::IsInputRedirected) {
        $l = Read-Host
        if ($l) { return $l.Substring(0, 1).ToUpperInvariant() } else { return '' }
    }
    $k = [Console]::ReadKey($true)
    Write-Host $k.KeyChar
    return "$($k.KeyChar)".ToUpperInvariant()
}

function Wait-AnyKey {
    param([string]$Message = '  Press any key to return to the main menu...')
    Write-Host ''
    Write-Host $Message -ForegroundColor DarkCyan
    if ([Console]::IsInputRedirected) { [void](Read-Host) } else { [void][Console]::ReadKey($true) }
}

function Read-YesNo {
    param([string]$Question)
    if ($Yes) { Write-Host "  $Question [Y/N]: Y (auto-confirmed by -Yes)"; return $true }
    if ([Console]::IsInputRedirected) { return $false }
    while ($true) {
        $a = (Read-Host "  $Question [Y/N]").Trim().ToLowerInvariant()
        if ($a -in 'y', 'yes') { return $true }
        if ($a -in 'n', 'no') { return $false }
        Write-Host '  Please answer Y or N.'
    }
}

function Get-VerdictColor {
    param([string]$Verdict)
    if (($Verdict -in @('DEFECTIVE', 'LOSSY CODEC')) -or $Verdict -like 'LIKELY*' -or $Verdict -like 'ERROR*') { return 'Red' }
    if ($Verdict -eq 'SUSPICIOUS') { return 'Yellow' }
    if ($Verdict -like '*notes*') { return 'Cyan' }
    if ($Verdict -eq 'SKIPPED') { return 'DarkGray' }
    return 'Green'
}

function Get-VerdictIcon {
    param([string]$Verdict)
    $c = Get-VerdictColor $Verdict
    switch ($c) { 'Red' { return '×' } 'Yellow' { return '▲' } 'DarkGray' { return '–' } default { return '√' } }
}

function Get-VerdictShort {
    param([string]$Verdict)
    if ($Verdict -like 'LIKELY*') { return 'LIKELY FAKE' }
    if ($Verdict -like '*notes*') { return 'CLEAN +notes' }
    if ($Verdict -like 'ERROR*') { return 'ERROR' }
    return $Verdict
}

# ========================================================================================
#  System detection (CPU / RAM) and worker calculation
# ========================================================================================
function Get-SystemInfo {
    $logical = [Environment]::ProcessorCount
    $info = [ordered]@{
        CpuName = 'Unknown CPU'; Logical = $logical; Physical = $logical
        RamTotalGB = $null; RamFreeGB = $null
        OS = [Runtime.InteropServices.RuntimeInformation]::OSDescription
    }
    try {
        if ($IsWindows) {
            $cpus = @(Get-CimInstance Win32_Processor -ErrorAction Stop)
            $info.CpuName = ($cpus[0].Name -replace '\s+', ' ').Trim()
            $phys = ($cpus | Measure-Object NumberOfCores -Sum).Sum
            if ($phys -gt 0) { $info.Physical = [Math]::Min([int]$phys, $logical) }
            $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
            $info.RamTotalGB = [Math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
            $info.RamFreeGB = [Math]::Round($os.FreePhysicalMemory / 1MB, 1)
        }
        elseif ($IsLinux) {
            $ci = Get-Content /proc/cpuinfo -ErrorAction Stop
            $nm = $ci | Where-Object { $_ -match '^model name' } | Select-Object -First 1
            if ($nm) { $info.CpuName = (($nm -split ':', 2)[1]).Trim() }
            $pairs = [System.Collections.Generic.HashSet[string]]::new(); $sock = ''
            foreach ($l in $ci) {
                if ($l -match '^physical id\s*:\s*(\S+)') { $sock = $Matches[1] }
                elseif ($l -match '^core id\s*:\s*(\S+)') { [void]$pairs.Add("$sock/$($Matches[1])") }
            }
            if ($pairs.Count -gt 0) { $info.Physical = [Math]::Min($pairs.Count, $logical) }
            $mi = Get-Content /proc/meminfo -ErrorAction Stop
            foreach ($l in $mi) {
                if ($l -match '^MemTotal:\s+(\d+)') { $info.RamTotalGB = [Math]::Round([double]$Matches[1] / 1MB, 1) }
                if ($l -match '^MemAvailable:\s+(\d+)') { $info.RamFreeGB = [Math]::Round([double]$Matches[1] / 1MB, 1) }
            }
        }
        elseif ($IsMacOS) {
            $info.CpuName = (& sysctl -n machdep.cpu.brand_string 2>$null | Out-String).Trim()
            $ph = [int](& sysctl -n hw.physicalcpu 2>$null)
            if ($ph -gt 0) { $info.Physical = [Math]::Min($ph, $logical) }
            $info.RamTotalGB = [Math]::Round([double](& sysctl -n hw.memsize 2>$null) / 1GB, 1)
        }
    }
    catch { }
    return [pscustomobject]$info
}

function Get-WorkPlan {
    param($Sys, [int]$FileCount)
    # Auto mode uses ALL detected logical CPU threads. Threads that are not needed for parallel files
    # are spent on a parallel FFT inside each file (so even a single file keeps every core busy).
    $logical = [Math]::Max(1, [int]$Sys.Logical)
    $budget = if ($S.CpuThreads -gt 0) { [Math]::Min([int]$S.CpuThreads, $logical) } else { $logical }
    $byRam = if ($Sys.RamFreeGB) { [Math]::Max(1, [int][Math]::Floor($Sys.RamFreeGB * 1024 / 400)) } else { 64 }
    $files = [Math]::Max(1, $FileCount)
    $auto = [int](($budget, $byRam, $files, 64 | Measure-Object -Minimum).Minimum)
    $workers = if ($S.Threads -gt 0) { [Math]::Max(1, [Math]::Min([int]$S.Threads, $files)) } else { [Math]::Max(1, $auto) }
    $fftThreads = [Math]::Max(1, [int][Math]::Floor($budget / $workers))
    return [pscustomobject]@{ Budget = $budget; Workers = $workers; FftThreads = $fftThreads; Auto = ($S.Threads -le 0) }
}

# ========================================================================================
#  Tool detection and installation (ffmpeg / flac)
# ========================================================================================
function Find-Tool {
    param([string]$Name, [string]$Explicit)
    if ($Explicit) {
        if (Test-Path -LiteralPath $Explicit) { return (Resolve-Path -LiteralPath $Explicit).Path }
        throw "Program not found: $Explicit"
    }
    # 1. portable copy next to the script (preferred)
    $exeName = if ($IsWindows) { "$Name.exe" } else { $Name }
    if (Test-Path -LiteralPath $ToolsRoot) {
        # the usual places first - avoids crawling the whole tools folder (portable PowerShell is large)
        foreach ($sub in $Name, 'ffmpeg') {
            $direct = Join-Path $ToolsRoot (Join-Path $sub $exeName)
            if (Test-Path -LiteralPath $direct -PathType Leaf) { return $direct }
        }
        $hit =Get-ChildItem -LiteralPath $ToolsRoot -Filter $exeName -Recurse -Depth 3 -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[\\/]_' } | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    # 2. a copy that is already available on the system (PATH)
    $c = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    return $null
}

function Get-HttpText {
    param([string]$Url)
    $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 60
    $c = $resp.Content
    if ($c -is [byte[]]) { $c = [Text.Encoding]::UTF8.GetString($c) }
    return [string]$c
}

function Save-Download {
    # Streaming download with a single-line progress display. When MinSpeedMBps is set and the average speed
    # stays below it after GraceSeconds, the download is aborted so that the next (faster) source can be tried.
    param([string]$Url, [string]$OutFile, [double]$MinSpeedMBps = 0, [int]$GraceSeconds = 12)
    Write-Host "  Downloading: $Url" -ForegroundColor DarkGray
    $client = [System.Net.Http.HttpClient]::new()
    $client.Timeout = [TimeSpan]::FromMinutes(30)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd("LosslessAnalyzer/$AppVersion")
    $drawn = $false
    try {
        $resp = $client.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        [void]$resp.EnsureSuccessStatusCode()
        $total = $resp.Content.Headers.ContentLength
        $in = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $out = [System.IO.File]::Create($OutFile)
        try {
            $buf = [byte[]]::new(1MB)
            $done = 0L
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $lastDraw = -1000
            $winMs = 0; $winBytes = 0L; $speed = 0.0
            while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                $out.Write($buf, 0, $n)
                $done += $n
                $el = $sw.ElapsedMilliseconds
                if (($el - $lastDraw) -ge 250) {
                    $lastDraw = $el
                    if (($el - $winMs) -ge 1000) {            # current speed over the last ~1 s
                        $speed = ($done - $winBytes) / 1MB / (($el - $winMs) / 1000.0)
                        $winMs = $el; $winBytes = $done
                    }
                    $line = if ($total) { '  {0} {1,3:N0}%  {2:N1} / {3:N1} MB  {4:N1} MB/s' -f (Format-Bar (100.0 * $done / $total) 24), (100.0 * $done / $total), ($done / 1MB), ($total / 1MB), $speed }
                            else { '  {0:N1} MB  {1:N1} MB/s' -f ($done / 1MB), $speed }
                    [Console]::Write("`r" + $line.PadRight(78))
                    $drawn = $true
                    if ($MinSpeedMBps -gt 0 -and $sw.Elapsed.TotalSeconds -ge $GraceSeconds) {
                        $avg = $done / 1MB / $sw.Elapsed.TotalSeconds
                        if ($avg -lt $MinSpeedMBps) { throw ('Source is too slow ({0:N1} MB/s) - switching to the next source' -f $avg) }
                    }
                }
            }
        }
        finally { $out.Dispose(); $in.Dispose() }
    }
    finally {
        $client.Dispose()
        if ($drawn) { [Console]::WriteLine() }
    }
    if (-not (Test-Path -LiteralPath $OutFile) -or (Get-Item -LiteralPath $OutFile).Length -lt 100KB) {
        throw "Download failed or file too small: $Url"
    }
}

function Install-PortableFfmpeg {
    $dest = Join-Path $ToolsRoot 'ffmpeg'
    $tmp = Join-Path $ToolsRoot '_download'
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $zip = Join-Path $tmp 'ffmpeg.zip'
    $extract = Join-Path $tmp 'ffmpeg_extract'
    try {
        Write-Host '  Downloading portable ffmpeg...' -ForegroundColor Cyan

        # Source list: GitHub-hosted builds first (fast CDN), gyan.dev direct last (can be very slow).
        $sources = [System.Collections.Generic.List[object]]::new()
        try {
            $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/GyanD/codexffmpeg/releases/latest' -Headers @{ 'User-Agent' = 'LosslessAnalyzer' } -TimeoutSec 30
            $as = $rel.assets | Where-Object { $_.name -match 'essentials_build\.zip$' } | Select-Object -First 1
            if ($as) {
                $dg = if ($as.PSObject.Properties['digest'] -and "$($as.digest)" -match '^sha256:([0-9a-fA-F]{64})$') { $Matches[1] } else { $null }
                $sources.Add([pscustomobject]@{ Name = 'gyan.dev release (GitHub mirror, ~110 MB)'; Url = $as.browser_download_url; Sha = $dg; Shaurl = $null })
            }
        }
        catch { }
        $sources.Add([pscustomobject]@{ Name = 'yt-dlp FFmpeg build (GitHub, ~190 MB)'; Url = 'https://github.com/yt-dlp/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip'; Sha = $null; Shaurl = $null })
        $sources.Add([pscustomobject]@{ Name = 'BtbN FFmpeg build (GitHub, ~190 MB)'; Url = 'https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip'; Sha = $null; Shaurl = $null })
        $sources.Add([pscustomobject]@{ Name = 'gyan.dev direct (~110 MB)'; Url = 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip'; Sha = $null; Shaurl = 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip.sha256' })

        $got = $null
        for ($i = 0; $i -lt $sources.Count; $i++) {
            $src = $sources[$i]
            $isLast = ($i -eq $sources.Count - 1)
            Write-Host ("  Source {0}/{1}: {2}" -f ($i + 1), $sources.Count, $src.Name) -ForegroundColor Cyan
            try {
                Save-Download $src.Url $zip $(if ($isLast) { 0 } else { 1.0 })
                $got = $src
                break
            }
            catch { Write-Host ("  × {0}" -f $_.Exception.Message) -ForegroundColor DarkYellow }
        }
        if (-not $got) { throw 'All ffmpeg download sources failed (no internet connection?).' }

        # integrity check where a SHA-256 is published
        $expected = $got.Sha
        if (-not $expected -and $got.Shaurl) {
            try { $expected = [regex]::Match((Get-HttpText $got.Shaurl), '[0-9a-fA-F]{64}').Value } catch { }
        }
        if ($expected) {
            $actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
            if ($expected -ne $actual) { throw "SHA-256 mismatch (expected $expected, got $actual)" }
            Write-Host '  SHA-256 verified.' -ForegroundColor Green
        }
        else { Write-Host '  (no checksum published for this source - skipping verification)' -ForegroundColor DarkGray }

        Write-Host '  Extracting...' -ForegroundColor DarkGray
        if (Test-Path -LiteralPath $extract) { Remove-Item -LiteralPath $extract -Recurse -Force }
        Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force
        $ff = Get-ChildItem -LiteralPath $extract -Filter 'ffmpeg.exe' -Recurse -File | Select-Object -First 1
        $fp = Get-ChildItem -LiteralPath $extract -Filter 'ffprobe.exe' -Recurse -File | Select-Object -First 1
        if (-not $ff -or -not $fp) { throw 'ffmpeg.exe / ffprobe.exe not found in the downloaded archive.' }
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        Copy-Item -LiteralPath $ff.FullName, $fp.FullName -Destination $dest -Force
        $root = Split-Path (Split-Path $ff.FullName -Parent) -Parent
        foreach ($lic in 'LICENSE', 'README.txt', 'COPYING.GPLv3') {
            $lf = Join-Path $root $lic
            if (Test-Path -LiteralPath $lf) { Copy-Item -LiteralPath $lf -Destination $dest -Force }
        }
    }
    finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Install-PortableFlac {
    $dest = Join-Path $ToolsRoot 'flac'
    $tmp = Join-Path $ToolsRoot '_download'
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $zip = Join-Path $tmp 'flac.zip'
    $extract = Join-Path $tmp 'flac_extract'
    try {
        Write-Host '  Downloading portable flac (approx. 1.3 MB)...' -ForegroundColor Cyan
        # newest "flac-X.Y.Z-win.zip" from the official Xiph mirror, with known versions as fallback
        $versions = [System.Collections.Generic.List[string]]::new()
        try {
            $listing = Get-HttpText 'https://ftp.osuosl.org/pub/xiph/releases/flac/'
            $found = [regex]::Matches($listing, 'flac-(\d+\.\d+(?:\.\d+)?)-win\.zip') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique
            foreach ($v in ($found | Sort-Object { [version]$_ } -Descending)) { $versions.Add($v) }
        }
        catch { }
        foreach ($v in '1.5.0', '1.4.3') { if (-not $versions.Contains($v)) { $versions.Add($v) } }

        $got = $false
        foreach ($v in ($versions | Select-Object -First 4)) {
            foreach ($url in @("https://ftp.osuosl.org/pub/xiph/releases/flac/flac-$v-win.zip", "https://github.com/xiph/flac/releases/download/$v/flac-$v-win.zip")) {
                try { Save-Download $url $zip; $got = $true; break } catch { }
            }
            if ($got) { break }
        }
        if (-not $got) { throw 'All flac download sources failed (no internet connection?).' }

        Write-Host '  Extracting...' -ForegroundColor DarkGray
        if (Test-Path -LiteralPath $extract) { Remove-Item -LiteralPath $extract -Recurse -Force }
        Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force
        $want = if ([Environment]::Is64BitOperatingSystem) { 'Win64' } else { 'Win32' }
        $exes = @(Get-ChildItem -LiteralPath $extract -Filter 'flac.exe' -Recurse -File)
        $exe = $exes | Where-Object { $_.FullName -match $want } | Select-Object -First 1
        if (-not $exe) { $exe = $exes | Select-Object -First 1 }
        if (-not $exe) { throw 'flac.exe not found in the downloaded archive.' }
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        Copy-Item -Path (Join-Path $exe.DirectoryName '*') -Destination $dest -Recurse -Force
    }
    finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Install-Tool {
    param([ValidateSet('ffmpeg', 'flac')][string]$Tool)

    if ($IsWindows) {
        # Portable download into .\tools next to the script - no installer, no AppData, no registry.
        try {
            if ($Tool -eq 'ffmpeg') { Install-PortableFfmpeg } else { Install-PortableFlac }
        }
        catch {
            Write-Host ('  × Download failed: ' + $_.Exception.Message) -ForegroundColor Red
            return $false
        }
        return [bool](Find-Tool $Tool)
    }

    # Linux / macOS: no portable builds are fetched automatically - fall back to the system package manager.
    Write-Host '  Note: on this OS the tool is installed with the system package manager (not portable).' -ForegroundColor Yellow
    $cands = [System.Collections.Generic.List[object]]::new()
    if ($IsMacOS) {
        if (Get-Command brew -ErrorAction SilentlyContinue) { $cands.Add(@('brew', @('install', $Tool))) }
    }
    else {
        $useSudo = ((& id -u) -ne '0') -and [bool](Get-Command sudo -ErrorAction SilentlyContinue)
        foreach ($pm in @(
                @('apt-get', @('install', '-y', $Tool)),
                @('dnf', @('install', '-y', $Tool)),
                @('pacman', @('-S', '--noconfirm', $Tool)),
                @('zypper', @('--non-interactive', 'install', $Tool)))) {
            if (Get-Command $pm[0] -ErrorAction SilentlyContinue) {
                if ($useSudo) { $cands.Add(@('sudo', (@($pm[0]) + $pm[1]))) } else { $cands.Add($pm) }
                break
            }
        }
    }
    if ($cands.Count -eq 0) {
        Write-Host "  No supported package manager found to install $Tool automatically." -ForegroundColor Yellow
        return $false
    }
    foreach ($c in $cands) {
        Write-Host ("  Running: {0} {1}" -f $c[0], ($c[1] -join ' ')) -ForegroundColor DarkGray
        $exe = $c[0]; $pmArgs = @($c[1])
        try { & $exe @pmArgs } catch { Write-Host $_.Exception.Message -ForegroundColor DarkYellow }
        if (Find-Tool $Tool) { return $true }
    }
    return $false
}

function Get-ProbeTool {
    param([string]$FfmpegExe)
    $ext = if ($IsWindows) { '.exe' } else { '' }
    $beside = Join-Path (Split-Path $FfmpegExe -Parent) "ffprobe$ext"
    if (Test-Path -LiteralPath $beside) { return $beside }
    return (Find-Tool 'ffprobe')
}

function Get-ToolVersion {
    param([string]$Exe, [string[]]$VerArgs)
    try { return (((& $Exe @VerArgs 2>&1) | Select-Object -First 1).ToString().Trim()) } catch { return 'unknown' }
}

function Initialize-Tools {
    $script:ffmpeg = Find-Tool 'ffmpeg' $FfmpegPath
    $script:ffprobe = if ($script:ffmpeg) { Get-ProbeTool $script:ffmpeg } else { $null }
    if (-not $script:ffmpeg -or -not $script:ffprobe) {
        Write-Host ''
        Write-Host '  ffmpeg (including ffprobe) is required but was not found on this system.' -ForegroundColor Yellow
        Write-Host "  It can be downloaded as a portable copy into: $ToolsRoot" -ForegroundColor Gray
        Write-Host '  (nothing is installed system-wide, nothing goes to AppData)' -ForegroundColor DarkGray
        if (-not (Read-YesNo 'Do you want to download ffmpeg now?')) { throw 'ffmpeg is required. Aborting.' }
        if (-not (Install-Tool 'ffmpeg')) {
            throw 'ffmpeg could not be downloaded automatically. Download it manually (https://www.gyan.dev/ffmpeg/builds/), put ffmpeg.exe and ffprobe.exe into the tools folder or pass -FfmpegPath.'
        }
        $script:ffmpeg = Find-Tool 'ffmpeg'
        $script:ffprobe = if ($script:ffmpeg) { Get-ProbeTool $script:ffmpeg } else { $null }
        if (-not $script:ffmpeg -or -not $script:ffprobe) { throw 'ffmpeg was downloaded but could not be located in the tools folder.' }
        Write-Host "  ffmpeg ready: $($script:ffmpeg)" -ForegroundColor Green
    }
    $script:flac = Find-Tool 'flac' $FlacPath
}

function Confirm-FlacTool {
    # called before an analysis that contains FLAC files
    if ($script:flac -or $script:flacDeclined) { return }
    Write-Host ''
    Write-Host '  FLAC files were found, but the official "flac" tool (used for the integrity test "flac -t") is not available.' -ForegroundColor Yellow
    Write-Host "  It can be downloaded as a portable copy into: $ToolsRoot" -ForegroundColor Gray
    if (Read-YesNo 'Do you want to download flac now?') {
        if (Install-Tool 'flac') {
            $script:flac = Find-Tool 'flac'
            Write-Host "  flac ready: $($script:flac)" -ForegroundColor Green
        }
        else {
            $script:flacDeclined = $true
            Write-Host '  flac could not be downloaded automatically (https://xiph.org/flac/download.html). Continuing without it.' -ForegroundColor Yellow
        }
    }
    else {
        $script:flacDeclined = $true
        Write-Host '  Continuing without flac: FLAC integrity is checked via ffmpeg and the embedded MD5 only.' -ForegroundColor DarkGray
    }
}

# ========================================================================================
#  Analysis functions (these are copied into every worker runspace - keep them self-contained)
# ========================================================================================
function Add-Finding {
    param($List, [string]$Severity, [string]$Title, [string]$Detail, [int]$Points = 0)
    $List.Add([pscustomobject]@{ Severity = $Severity; Title = $Title; Detail = $Detail; Points = $Points })
}

function ConvertTo-Num {
    param($Value)
    $d = 0.0
    if ($null -ne $Value -and [double]::TryParse("$Value", [Globalization.NumberStyles]::Float, [cultureinfo]::InvariantCulture, [ref]$d)) { return $d }
    return $null
}

function Set-FileProgress {
    param([string]$Name, [string]$Status, [double]$Percent)
    if ($board) { $board.Update([int]$fileIndex, $Status, [Math]::Min(100.0, [Math]::Max(0.0, $Percent))) }
}

function Get-BandDb {
    # mean level (dBFS per FFT bin) in a frequency band
    param([double[]]$Power, [double]$BinHz, [double]$F1, [double]$F2)
    $i1 = [Math]::Max(1, [int][Math]::Floor($F1 / $BinHz))
    $i2 = [Math]::Min($Power.Length - 1, [int][Math]::Ceiling($F2 / $BinHz))
    if ($i2 -lt $i1) { return -200.0 }
    $sum = 0.0
    for ($i = $i1; $i -le $i2; $i++) { $sum += $Power[$i] }
    return 10.0 * [Math]::Log10($sum / ($i2 - $i1 + 1) + 1e-20)
}

function Find-SpectralCutoff {
    param([double[]]$Power, [int]$SampleRate, [int]$FftSize)
    $binHz = $SampleRate / $FftSize
    $nyq = $SampleRate / 2.0
    $bw = 250.0
    $win = 4                                  # 4 bands = 1 kHz on each side
    $nb = [int][Math]::Floor($nyq / $bw)
    $first = [int][Math]::Ceiling(6000 / $bw)
    $last = $nb - $win
    $none = [pscustomobject]@{ Sharp = $false; CutoffHz = $null; DropDb = 0.0; BelowDb = $null; AboveDb = $null }
    if ($last -le $first) { return $none }

    $lvl = [double[]]::new($nb)
    for ($b = 0; $b -lt $nb; $b++) {
        $lvl[$b] = Get-BandDb -Power $Power -BinHz $binHz -F1 ($b * $bw) -F2 (($b + 1) * $bw)
    }

    $best = -1; $bestDrop = -999.0; $bestBelow = 0.0; $bestAbove = 0.0
    for ($i = $first; $i -le $last; $i++) {
        $below = 0.0; $above = 0.0
        for ($k = 1; $k -le $win; $k++) { $below += $lvl[$i - $k]; $above += $lvl[$i + $k - 1] }
        $below /= $win; $above /= $win
        $drop = $below - $above
        if ($drop -gt $bestDrop) { $bestDrop = $drop; $best = $i; $bestBelow = $below; $bestAbove = $above }
    }
    if ($best -lt 0) { return $none }

    $mid = ($bestBelow + $bestAbove) / 2.0
    $edge = $best - 1
    for ($j = $best + $win - 1; $j -ge ($best - $win); $j--) {
        if ($lvl[$j] -ge $mid) { $edge = $j; break }
    }
    return [pscustomobject]@{
        Sharp    = ($bestDrop -ge 20.0)
        CutoffHz = ($edge + 1) * $bw
        DropDb   = [Math]::Round($bestDrop, 1)
        BelowDb  = [Math]::Round($bestBelow, 1)
        AboveDb  = [Math]::Round($bestAbove, 1)
    }
}

function Get-SourceEstimate {
    param([double]$Hz)
    if ($Hz -lt 11000) { return 'very low bitrate (<= 64 kbit/s), e.g. speech/web source' }
    elseif ($Hz -lt 15500) { return 'MP3/AAC <= approx. 96 kbit/s' }
    elseif ($Hz -lt 16500) { return 'MP3 approx. 128 kbit/s (typical 16 kHz low-pass)' }
    elseif ($Hz -lt 17500) { return 'MP3/AAC approx. 128-160 kbit/s (or Vorbis q4-q5)' }
    elseif ($Hz -lt 18500) { return 'MP3 approx. 160-192 kbit/s (LAME V3/V4) or AAC approx. 128-160 kbit/s' }
    elseif ($Hz -lt 19500) { return 'MP3 approx. 192-256 kbit/s (LAME V2/V1)' }
    elseif ($Hz -lt 20500) { return 'MP3 V0/256-320 kbit/s, AAC 256 kbit/s or Opus/YouTube (approx. 20 kHz)' }
    else { return 'cannot be determined reliably (very high bitrate or genuine material)' }
}

function Start-SpectrogramRun {
    param([string]$In, [string]$Out, [int]$Legend)
    $graph = "[0:a:0]showspectrumpic=s=1400x720:legend=${Legend}[v]"
    $ffArgs = [string[]]@('-hide_banner', '-nostdin', '-v', 'error', '-y', '-i', $In, '-filter_complex', $graph, '-map', '[v]', '-frames:v', '1', $Out)
    return [FlacTools.ProcRun]::Start($ffmpeg, $ffArgs)
}

function Get-AudioProbe {
    param([System.IO.FileInfo]$File)
    $json = (& $ffprobe -v error -select_streams a:0 -show_streams -show_format -of json $File.FullName 2>$null | Out-String)
    if ($LASTEXITCODE -ne 0 -or -not $json.Trim()) { return $null }
    try { $o = $json | ConvertFrom-Json } catch { return $null }
    if (-not $o.streams -or @($o.streams).Count -eq 0) { return $null }
    return $o
}

function Invoke-FileAnalysis {
    param([System.IO.FileInfo]$File)

    $fd = [System.Collections.Generic.List[object]]::new()
    $r = [ordered]@{
        File = $File.Name; Path = $File.FullName; Codec = $null; Verdict = ''; Score = 0
        SampleRate = $null; Bits = $null; EffectiveBits = $null; Channels = $null
        DurationSec = $null; BitrateKbps = $null; CutoffKHz = $null; EstimatedSource = $null
        IntegrityOk = $null; IntegrityMethod = ''; Md5Status = ''; PeakDb = $null; RmsDb = $null; CrestDb = $null; ClipRuns = $null; FrameCliffPct = $null
        Encoder = ''; Spectrogram = $null; Profile = @(); Findings = $fd
    }
    $name = $File.Name

    # --- 0. Probe --------------------------------------------------------------------------
    Set-FileProgress $name 'Reading stream information (ffprobe)...' 2
    $probe = Get-AudioProbe $File
    if (-not $probe) {
        Add-Finding $fd 'CRITICAL' 'Not a readable audio file' 'ffprobe could not read an audio stream. The file is corrupt, truncated, empty, or not audio at all (e.g. a renamed file).' 100
        $r.Verdict = 'DEFECTIVE'; $r.Score = 100
        return [pscustomobject]$r
    }
    $s = @($probe.streams)[0]
    $codec = "$($s.codec_name)".ToLowerInvariant()
    $r.Codec = $codec
    $sr = [int](ConvertTo-Num $s.sample_rate)
    $ch = [int](ConvertTo-Num $s.channels)
    $durSec = ConvertTo-Num $s.duration
    if ($null -eq $durSec) { $durSec = ConvertTo-Num $probe.format.duration }

    # tags (stream + container)
    $tags = [System.Collections.Generic.List[string]]::new()
    foreach ($src in @($s.tags, $probe.format.tags)) {
        if ($src) { foreach ($pr in $src.PSObject.Properties) { $tags.Add(("{0}={1}" -f $pr.Name.ToUpperInvariant(), $pr.Value)) } }
    }
    $r.SampleRate = $sr; $r.Channels = $ch; $r.DurationSec = $durSec
    if ($durSec -and $durSec -gt 0) { $r.BitrateKbps = [Math]::Round($File.Length * 8 / $durSec / 1000, 0) }

    # --- 1. Codec check --------------------------------------------------------------------
    $isLossy = ($codec -in $lossyCodecs) -or ($codec -match '^adpcm_') -or ($codec -match '^pcm_(alaw|mulaw)$')
    if ($isLossy) {
        Add-Finding $fd 'CRITICAL' "Lossy codec inside the file: $codec" ("The file '{0}' does not contain lossless audio at all - its codec is '{1}', which is lossy by design. The extension/container only pretends otherwise (typical: an MP3/AAC stream renamed to .flac/.wav, or an .m4a that holds AAC instead of ALAC)." -f $File.Extension, $codec) 100
        $r.Verdict = 'LOSSY CODEC'; $r.Score = 100; $r.IntegrityOk = $null
        return [pscustomobject]$r
    }
    if ($codec -match '^dsd') {
        Add-Finding $fd 'NOTE' 'DSD audio is not supported' 'DSD (1-bit) streams use a completely different representation; the PCM based checks of this script do not apply.' 0
        $r.Verdict = 'SKIPPED'; $r.Score = 0
        return [pscustomobject]$r
    }
    $isLosslessCodec = ($codec -in $losslessCodecs) -or ($codec -match '^pcm_')
    if (-not $isLosslessCodec) {
        Add-Finding $fd 'WARNING' "Codec '$codec' is not a known lossless codec" 'The codec could not be confirmed as lossless. The remaining checks are still performed, but treat the result with care.' 15
    }

    $isFloat = $codec -match '^pcm_f'
    $flacInfo = $null
    if ($codec -eq 'flac') {
        $flacInfo = [FlacTools.FlacMetaReader]::Read($File.FullName)
        if (-not $flacInfo.Valid) {
            Add-Finding $fd 'WARNING' 'FLAC header could not be parsed strictly' ("{0} ffmpeg can still read the stream, but the file structure is unusual (damaged or non-standard metadata)." -f $flacInfo.Error) 15
            $flacInfo = $null
        }
        else {
            $sr = $flacInfo.SampleRate; $ch = $flacInfo.Channels
            $r.SampleRate = $sr; $r.Channels = $ch
            $r.Encoder = $flacInfo.Vendor
        }
    }
    if (-not $r.Encoder) {
        $enc = $tags | Where-Object { $_ -like 'ENCODER=*' } | Select-Object -First 1
        if ($enc) { $r.Encoder = $enc.Substring(8) }
    }

    # declared bit depth
    $bits = 0
    if (-not $isFloat) {
        if ($flacInfo) { $bits = $flacInfo.BitsPerSample }
        else {
            $bits = [int](ConvertTo-Num $s.bits_per_raw_sample)
            if ($bits -le 0) { $bits = [int](ConvertTo-Num $s.bits_per_sample) }
            if ($bits -le 0) {
                $bits = switch -Regex ("$($s.sample_fmt)") { '^u8' { 8 } '^s16' { 16 } '^s32' { 32 } '^s64' { 32 } default { 0 } }
            }
            if ($bits -gt 32) { $bits = 32 }
        }
    }
    $r.Bits = $bits
    if (-not $sr -or -not $ch) {
        Add-Finding $fd 'CRITICAL' 'Missing stream parameters' 'Sample rate or channel count could not be determined; the file is damaged or has an invalid header.' 100
        $r.Verdict = 'DEFECTIVE'; $r.Score = 100
        return [pscustomobject]$r
    }

    $expected = 0L
    if ($flacInfo -and $flacInfo.TotalSamples -gt 0) { $expected = $flacInfo.TotalSamples }
    elseif ($durSec -and $durSec -gt 0) { $expected = [long][Math]::Round($durSec * $sr) }
    if ($flacInfo -and $flacInfo.TotalSamples -gt 0) {
        $r.DurationSec = $flacInfo.TotalSamples / $sr
        $r.BitrateKbps = [Math]::Round($File.Length * 8 / $r.DurationSec / 1000, 0)
    }

    # --- 2. Background helpers: flac -t and the spectrogram run in parallel to the analysis ----------
    $flacRun = $null
    if ($flac -and $codec -eq 'flac') {
        try { $flacRun = [FlacTools.ProcRun]::Start($flac, [string[]]@('-t', '-s', $File.FullName)) } catch { $flacRun = $null }
    }
    $specRun = $null; $specPng = $null
    if ($SpectrogramDir) {
        # stable path hash (String.GetHashCode changes with every start, which left a new PNG per run)
        $md5 = [Security.Cryptography.MD5]::Create()
        try { $pathHash = [BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($File.FullName)), 0, 4).Replace('-', '').ToLowerInvariant() }
        finally { $md5.Dispose() }
        $specPng = Join-Path $SpectrogramDir ('{0}_{1}.png' -f [IO.Path]::GetFileNameWithoutExtension($File.Name), $pathHash)
        try { $specRun = Start-SpectrogramRun $File.FullName $specPng 1 } catch { $specRun = $null }
    }

    # --- 2b. Decode + analysis (background task, progress polled) -------------------------------------
    $fftThr = if ($FftThreads) { [int]$FftThreads } else { 1 }
    $job = [FlacTools.AudioAnalyzer]::Start($ffmpeg, $File.FullName, $ch, $sr, $bits, $FftSize, $fftThr, $expected)
    while (-not $job.Completion.IsCompleted) {
        $done = $job.Done
        $bg = if (($flacRun -and -not $flacRun.Completion.IsCompleted) -or ($specRun -and -not $specRun.Completion.IsCompleted)) { ' (+ flac -t / spectrogram in background)' } else { '' }
        if ($expected -gt 0) {
            $frac = [Math]::Min(1.0, $done / [double]$expected)
            Set-FileProgress $name ('Decoding & analyzing audio... {0:N0}%{1}' -f ($frac * 100), $bg) (5.0 + $frac * 90.0)
        }
        else {
            Set-FileProgress $name ('Decoding & analyzing audio... {0} processed{1}' -f (Format-Time ($done / $sr)), $bg) 50
        }
        [void][Threading.Tasks.Task]::WaitAny([Threading.Tasks.Task[]]@($job.Completion), 120)   # returns at once when the analysis finishes
    }
    try { $st = $job.Completion.GetAwaiter().GetResult() }
    catch {
        Add-Finding $fd 'CRITICAL' 'Decoding failed' $_.Exception.Message 100
        $r.Verdict = 'DEFECTIVE'; $r.Score = 100; $r.IntegrityOk = $false
        return [pscustomobject]$r
    }

    # wait for the background helpers
    foreach ($run in $flacRun, $specRun) {
        while ($run -and [Threading.Tasks.Task]::WaitAny([Threading.Tasks.Task[]]@($run.Completion), 100) -lt 0) {
            Set-FileProgress $name 'Waiting for flac -t / spectrogram...' 96
        }
    }
    $flacOk = $null
    if ($flacRun) {
        try {
            $fr = $flacRun.Completion.GetAwaiter().GetResult()
            $flacOk = ($fr.ExitCode -eq 0)
            if (-not $flacOk) {
                $flacOut = ("$($fr.Error) $($fr.Output)").Trim()
                Add-Finding $fd 'CRITICAL' 'flac -t reports errors' ("The official FLAC decoder's integrity test failed: {0}. The file is damaged (transfer error, bad disk, interrupted download) and may contain clicks or dropouts." -f $flacOut) 100
            }
        }
        catch { $flacOk = $null }
    }
    if ($specRun) {
        $okSpec = $false
        try { $sres = $specRun.Completion.GetAwaiter().GetResult(); $okSpec = ($sres.ExitCode -eq 0) -and (Test-Path -LiteralPath $specPng) } catch { }
        if (-not $okSpec) {
            try { $retry = Start-SpectrogramRun $File.FullName $specPng 0; $s2 = $retry.Completion.GetAwaiter().GetResult(); $okSpec = ($s2.ExitCode -eq 0) -and (Test-Path -LiteralPath $specPng) } catch { }
        }
        if ($okSpec) { $r.Spectrogram = $specPng }
    }
    Set-FileProgress $name 'Evaluating results...' 97

    # --- 3. Integrity ----------------------------------------------------------------------
    $decErr = "$($st.FfmpegErrors)".Trim()
    if ($decErr) {
        $short = ($decErr -split "`n" | Select-Object -First 3) -join ' | '
        if ($flacOk -eq $true) {
            Add-Finding $fd 'WARNING' 'ffmpeg reports decoder messages' ("ffmpeg: {0}. flac -t, however, passes, so this is probably harmless (metadata quirk)." -f $short) 10
        }
        else {
            Add-Finding $fd 'CRITICAL' 'Decoder errors' ("ffmpeg reports errors while decoding: {0}. Typical for damaged frames/blocks (checksum errors)." -f $short) 100
        }
    }

    $countOk = $true
    if ($expected -gt 0 -and $st.Frames -ne $expected) {
        $diff = [Math]::Abs($st.Frames - $expected)
        if ($flacInfo) {
            $countOk = $false
            Add-Finding $fd 'CRITICAL' 'Sample count mismatch' ("STREAMINFO says {0} samples, {1} were decoded. The file is truncated or frames are missing/were discarded." -f $expected, $st.Frames) 100
        }
        elseif ($diff -gt [Math]::Max(2, $expected * 0.001)) {
            $countOk = $false
            Add-Finding $fd 'WARNING' 'Decoded length differs from the header' ("The header announces about {0} samples, {1} were decoded (difference {2}). The file may be truncated or its header is inconsistent." -f $expected, $st.Frames, $diff) 30
        }
    }
    elseif ($expected -eq 0 -and $flacInfo) {
        Add-Finding $fd 'NOTE' 'Total length not stored in STREAMINFO' 'The encoder did not store the sample count (e.g. streaming/pipe encoding). Length reporting and seeking are limited; the audio itself is fine.' 0
    }

    $md5Verified = $false
    if ($flacInfo) {
        $md5zero = ($flacInfo.Md5Hex -match '^0+$')
        if ($md5zero) {
            $r.Md5Status = 'not set'
            Add-Finding $fd 'NOTE' 'No MD5 checksum of the audio data' 'STREAMINFO contains no MD5 (all zeros). The encoder did not compute it (common with ffmpeg conversions or streaming encodes). Integrity can then only be checked via the frame CRCs, not via a whole-file checksum. Tip: re-encode with "flac -V".' 5
        }
        elseif ($st.Md5Hex -eq $flacInfo.Md5Hex) { $r.Md5Status = 'OK'; $md5Verified = $true }
        elseif ($flacOk -eq $true) {
            $r.Md5Status = 'own calculation differs (flac -t OK)'
            Add-Finding $fd 'NOTE' 'Own MD5 calculation differs' 'flac -t confirms the file as intact; the difference to the script''s own MD5 is probably caused by channel order/sample format (mainly multichannel) and is not meaningful.' 0
        }
        else {
            $r.Md5Status = 'MISMATCH'
            $sev = if ($ch -gt 2) { 'WARNING' } else { 'CRITICAL' }
            $pts = if ($ch -gt 2) { 20 } else { 100 }
            Add-Finding $fd $sev 'MD5 of the audio data does not match' ("The calculated MD5 ({0}) differs from the stored one ({1}). The audio was modified after encoding or is damaged. For multichannel files please cross-check with flac -t." -f $st.Md5Hex, $flacInfo.Md5Hex) $pts
        }
    }
    else { $r.Md5Status = 'n/a' }

    if ($null -ne $flacOk) {
        $r.IntegrityMethod = 'flac -t' + $(if ($md5Verified) { ' + MD5' } else { '' })
        $r.IntegrityOk = $flacOk -and $countOk
    }
    else {
        $r.IntegrityMethod = 'ffmpeg decode' + $(if ($md5Verified) { ' + MD5' } else { '' })
        $r.IntegrityOk = (-not $decErr) -and $countOk -and ($r.Md5Status -ne 'MISMATCH')
    }

    # --- 4. Level / signal -----------------------------------------------------------------
    $peak = ($st.ChPeak | Measure-Object -Maximum).Maximum
    $msq = 0.0; foreach ($x in $st.ChRms) { $msq += $x * $x }; $msq /= $ch
    $rms = [Math]::Sqrt($msq)
    $r.PeakDb = if ($peak -gt 0) { [Math]::Round(20 * [Math]::Log10($peak), 2) } else { $null }
    $r.RmsDb = if ($rms -gt 0) { [Math]::Round(20 * [Math]::Log10($rms), 2) } else { $null }
    if ($null -ne $r.PeakDb -and $null -ne $r.RmsDb) { $r.CrestDb = [Math]::Round($r.PeakDb - $r.RmsDb, 1) }
    $clipRuns = 0; foreach ($x in $st.ChClipRuns) { $clipRuns += $x }
    $r.ClipRuns = $clipRuns

    if ($st.AllSilent) {
        Add-Finding $fd 'WARNING' 'File contains only digital silence' 'All samples are 0. Either an empty track/placeholder or a failed rip/export.' 30
    }

    if ($clipRuns -ge 20) {
        $sev = if ($clipRuns -ge 500) { 'WARNING' } else { 'NOTE' }
        $pts = if ($clipRuns -ge 500) { 10 } else { 3 }
        Add-Finding $fd $sev "Clipping: $clipRuns overdriven passages" 'Several consecutive samples sit exactly at full scale. Causes: a very loud master (loudness war) or the decoding of a lossy file whose peaks exceeded 0 dBFS and were hard-limited. Heavy clipping alone is NOT proof of a lossy source, but it often goes along with one.' $pts
    }

    $dcMax = ($st.ChDc | ForEach-Object { [Math]::Abs($_) } | Measure-Object -Maximum).Maximum
    if ($dcMax -gt 0.005) {
        Add-Finding $fd 'NOTE' ('DC offset: {0:N2} % of full scale' -f ($dcMax * 100)) 'The signal is shifted by a constant component. This points to a poor A/D converter, a faulty recording chain or processing, and wastes headroom. Not lossy-specific, but a quality defect.' 3
    }

    if ($st.InternalZeroRuns -gt 0) {
        Add-Finding $fd 'NOTE' ("{0} digital-silence passages inside the track (longest {1:N0} ms)" -f $st.InternalZeroRuns, ($st.LongestInternalZero * 1000 / $sr)) 'Sections of exact zeros lie within the material. This can be intentional (pauses, edits) but may also indicate dropouts in rips - spot-check by listening.' 2
    }

    # --- 5. Bit depth ------------------------------------------------------------------------
    if ($bits -gt 0 -and -not $st.AllSilent) {
        $eff = $st.EffectiveBits
        $r.EffectiveBits = $eff
        if ($bits -gt 16 -and $eff -le 16) {
            Add-Finding $fd 'WARNING' "Fake $bits-bit: only $eff bit actually used" ("The file is declared as {0}-bit, but the lowest {1} bits are zero in ALL samples. The material comes from a 16-bit source (e.g. CD) and was merely placed into a larger container. It sounds identical to 16-bit - it is not real hi-res, and the file is needlessly large." -f $bits, ($bits - $eff)) 40
        }
        elseif ($eff -lt $bits) {
            Add-Finding $fd 'NOTE' "Unused bits: effectively $eff of $bits" ("The lowest {0} bit(s) are zero everywhere (so-called wasted bits). Typical after volume changes in the integer domain, conversion from a lower bit depth or special mastering. The real resolution is lower than declared." -f ($bits - $eff)) 8
        }

        # Grid test: 16-bit material that was scaled/dithered into 24 bit leaves a comb-like value distribution
        $totalSamples = [double]$st.Frames * $ch
        if ($bits -gt 16 -and $bits -le 24 -and $eff -gt 16 -and $totalSamples -ge 2000000) {
            $slots = [double]$st.OccSlots
            $occConclusive = ($slots -gt 0 -and $st.OccWindowSamples -ge 20 * $slots)
            $occRatio = if ($occConclusive) { $st.OccOccupied / $slots } else { $null }
            if ($st.DistinctValues -le 70000 -or ($occConclusive -and $occRatio -lt 0.15)) {
                $effRes = [int][Math]::Ceiling([Math]::Log([Math]::Max(2.0, [double]$st.DistinctValues), 2))
                $occTxt = if ($occConclusive) { ('In the quiet range around zero only {0:N1}% of the possible sample values are ever used. ' -f ($occRatio * 100)) } else { '' }
                Add-Finding $fd 'WARNING' "Fake $bits-bit: sample values form a coarse grid (resolution approx. $effRes bit)" (("Only {0:N0} distinct sample values occur in {1:N1} million samples. A genuine {2}-bit recording uses far more. " -f $st.DistinctValues, ($totalSamples / 1e6), $bits) + $occTxt + 'This is typical for 16-bit material that was converted to a larger bit depth after a gain change or with dither: the original 16-bit grid is still visible. The file is not real hi-res.') 40
            }
            elseif ($occConclusive -and $occRatio -ge 0.6) {
                Add-Finding $fd 'OK' 'Full bit-depth resolution confirmed' ('The sample values fill {0:N0}% of the possible values around zero, i.e. the file really uses its {1}-bit resolution.' -f ($occRatio * 100), $bits) 0
            }
        }
    }

    # --- 6. Stereo ---------------------------------------------------------------------------
    if ($ch -ge 2 -and $st.Frames -gt 0) {
        $identRatio = $st.IdenticalFrames / $st.Frames
        if ($identRatio -ge 0.9999 -and -not $st.AllSilent) {
            Add-Finding $fd 'NOTE' 'Dual mono: left and right channel are identical' 'The file is stereo but contains the same signal twice. Normal for mono recordings (old records, audio dramas); on stereo albums it hints at a mono source or mono downmix. Space-saving tip: store as true mono.' 10
        }
        elseif (-not [double]::IsNaN($st.Corr) -and $st.Corr -le -0.95) {
            Add-Finding $fd 'WARNING' ('Channels out of phase (correlation {0:N3})' -f $st.Corr) 'Left and right are almost in anti-phase, which cancels out when played back in mono. Usually a wiring or conversion error.' 5
        }
        $rmsDb = $st.ChRms | ForEach-Object { if ($_ -gt 0) { 20 * [Math]::Log10($_) } else { -200 } }
        $lo = ($rmsDb | Measure-Object -Minimum).Minimum; $hi = ($rmsDb | Measure-Object -Maximum).Maximum
        if ($hi -gt -60 -and $lo -lt -90) {
            Add-Finding $fd 'WARNING' 'One channel is (almost) silent' ('One channel sits at {0:N0} dBFS RMS, the loudest at {1:N0} dBFS. Damaged recording/conversion or intentionally single-channel content.' -f $lo, $hi) 10
        }
    }

    # --- 7. Spectrum / lossy detection / upsampling --------------------------------------------
    $globalFlagged = $false
    if ($st.AvgPower -and -not $st.AllSilent) {
        $nyq = $sr / 2.0
        $binHz = $sr / $FftSize
        $step = if ($nyq -gt 30000) { 4000 } else { 2000 }
        $prof = [System.Collections.Generic.List[string]]::new()
        for ($f0 = 0; $f0 -lt $nyq; $f0 += $step) {
            $f1 = [Math]::Min($f0 + $step, $nyq)
            $db = Get-BandDb -Power $st.AvgPower -BinHz $binHz -F1 $f0 -F2 $f1
            $barLen = [int][Math]::Max(0, [Math]::Min(40, ($db + 140) / 2.5))
            $prof.Add(('{0,5:N1}-{1,5:N1} kHz {2,7:N1} dB  {3}' -f ($f0 / 1000), ($f1 / 1000), $db, ('█' * $barLen)))
        }
        $r.Profile = $prof

        $cut = Find-SpectralCutoff -Power $st.AvgPower -SampleRate $sr -FftSize $FftSize
        if ($cut.Sharp) {
            $cHz = $cut.CutoffHz
            $cK = $cHz / 1000
            $r.CutoffKHz = [Math]::Round($cK, 2)
            $est = Get-SourceEstimate $cHz
            $r.EstimatedSource = $est
            $common = ('The spectrum collapses at approx. {0:N1} kHz by {1:N0} dB (level below approx. {2:N0} dB, above approx. {3:N0} dB per bin). ' -f $cK, $cut.DropDb, $cut.BelowDb, $cut.AboveDb)
            $lossyText = $common + 'Lossy codecs (MP3, AAC, Vorbis, Opus) remove high frequencies with a fixed low-pass to save bitrate. When such a file is converted to a lossless format the gap stays forever - a lossless container does not turn lossy into lossless. Estimated source: ' + $est + '. Caution: old analog/tape recordings and some remasters have a natural low-pass - when in doubt, look at the spectrogram.'

            if ($cHz -lt 20000) {
                $globalFlagged = $true
                if ($cHz -lt 16500) { $sev = 'CRITICAL'; $pts = 80 }
                elseif ($cHz -lt 18500) { $sev = 'CRITICAL'; $pts = 65 }
                elseif ($cHz -lt 19500) { $sev = 'WARNING'; $pts = 50 }
                else { $sev = 'WARNING'; $pts = 35 }
                Add-Finding $fd $sev ('Hard frequency cutoff at approx. {0:N1} kHz (lossy suspicion)' -f $cK) $lossyText $pts
                if ($sr -gt 48000) {
                    Add-Finding $fd 'WARNING' "Hi-res container ($sr Hz) without hi-res content" ("The sample rate is {0} Hz (Nyquist {1:N1} kHz), but usable content ends at approx. {2:N1} kHz. The file was upsampled and contains no additional information." -f $sr, ($nyq / 1000), $cK) 20
                }
            }
            elseif ($sr -le 48000) {
                if ($cHz -lt 20600) {
                    Add-Finding $fd 'NOTE' ('Low-pass at approx. {0:N1} kHz' -f $cK) ($common + 'This is the zone where both high-bitrate lossy files (MP3 V0/320, AAC 256) and perfectly normal CD masters (anti-aliasing filters, sample-rate conversion) end. Nothing reliable can be derived from it alone. Check the spectrogram: lossy files often show additional holes/stripes in the treble.') 15
                }
            }
            else {
                if ($cHz -le 22700) {
                    Add-Finding $fd 'WARNING' ('Upsampled from 44.1 kHz: content ends at approx. {0:N1} kHz' -f $cK) ($common + "The file is $sr Hz, but the content ends exactly where a 44.1 kHz (CD) source would end (22.05 kHz Nyquist). The file was upsampled from CD quality - not real hi-res, just bigger.") 45
                }
                elseif ($cHz -le 24800) {
                    Add-Finding $fd 'WARNING' ('Upsampled from 48 kHz: content ends at approx. {0:N1} kHz' -f $cK) ($common + "The file is $sr Hz, but the content ends at approx. 24 kHz (Nyquist of a 48 kHz source). Probably upsampled from 44.1/48 kHz.") 45
                }
                elseif ($sr -ge 176400 -and $cHz -le 48800) {
                    Add-Finding $fd 'WARNING' ('Upsampled from 88.2/96 kHz: content ends at approx. {0:N1} kHz' -f $cK) ($common + "The file is $sr Hz, but the content ends at approx. 48 kHz. Probably upsampled from 88.2/96 kHz.") 40
                }
            }
        }
        else {
            Add-Finding $fd 'OK' 'No hard frequency cutoff detected' ('The spectrum does not drop abruptly (largest step between 1 kHz windows: {0:N0} dB). This is the expected picture of a genuine lossless source - but it proves nothing for very high lossy bitrates.' -f $cut.DropDb) 0
        }
    }
    elseif (-not $st.AllSilent) {
        Add-Finding $fd 'NOTE' 'Spectral analysis not possible' 'The file is too short for the FFT or contains no analyzable data.' 0
    }

    # --- 7b. Time-resolved low-pass analysis (every FFT frame) ------------------------------------
    if ($st.TFramesValid -ge 20 -and -not $st.AllSilent) {
        $ratio = $st.TFramesCliff / [double]$st.TFramesValid
        $r.FrameCliffPct = [int][Math]::Round($ratio * 100)
        if ($st.TFramesCliff -ge 20 -and $ratio -ge 0.8 -and $st.TMedianHz -lt 20600) {
            $modeK = $st.TModeHz / 1000
            $spread = $st.TP90Hz - $st.TP10Hz
            if ($st.TModeShare -ge 0.6) {
                $txt = ('{0:N0}% of the analyzed frames show a razor-sharp spectral cliff, and {1:N0}% of those sit at the same frequency (approx. {2:N1} kHz). A fixed low-pass in practically every frame is the signature of a lossy encoder (CBR/ABR). Genuine lossless music rarely cuts its treble this uniformly.' -f ($ratio * 100), ($st.TModeShare * 100), $modeK)
                if ($globalFlagged) {
                    Add-Finding $fd 'NOTE' ('Per-frame analysis confirms the cutoff at approx. {0:N1} kHz' -f $modeK) $txt 10
                }
                else {
                    $estT = Get-SourceEstimate $st.TModeHz
                    if (-not $r.CutoffKHz) { $r.CutoffKHz = [Math]::Round($modeK, 2); $r.EstimatedSource = $estT }
                    Add-Finding $fd 'WARNING' ('Fixed low-pass in nearly every frame (approx. {0:N1} kHz)' -f $modeK) ($txt + ' Estimated source: ' + $estT + '. Caution: some mastering chains apply a fixed 20 kHz filter - check the spectrogram.') 30
                }
            }
            elseif ($spread -ge 1000 -and $st.TMedianHz -lt 19500) {
                Add-Finding $fd 'WARNING' ('Variable low-pass: the cliff wanders between {0:N1} and {1:N1} kHz' -f ($st.TP10Hz / 1000), ($st.TP90Hz / 1000)) ('{0:N0}% of the frames contain a sharp cliff, but its position changes from frame to frame (10th-90th percentile {1:N1}-{2:N1} kHz, median {3:N1} kHz). Adaptive/VBR lossy encoders (MP3, AAC, Vorbis) decide per frame how much treble to keep, which smears the cutoff in the averaged spectrum - the average may look smooth although every single frame is clearly band-limited. Genuine recordings seldom behave like this.' -f ($ratio * 100), ($st.TP10Hz / 1000), ($st.TP90Hz / 1000), ($st.TMedianHz / 1000)) 40
            }
        }
    }

    # --- 8. Metadata -----------------------------------------------------------------------------
    if ("$($r.Encoder)" -match '(?i)lavf|lavc|ffmpeg') {
        Add-Finding $fd 'NOTE' "Written with ffmpeg ($($r.Encoder))" 'The file was written by ffmpeg. That is common for conversions (WAV/ALAC/MP3 -> FLAC) and no defect by itself, but it says nothing about where the audio came from.' 0
    }
    $scanKeys = 'COMMENT', 'DESCRIPTION', 'ENCODER', 'ENCODED-BY', 'ENCODEDBY', 'ENCODED_BY', 'ENCODING', 'ENCODING_TOOL', 'ENCODERSETTINGS',
                'SOURCE', 'SOURCEMEDIA', 'SOFTWARE', 'SETTINGS', 'COMPRESSION', 'RIPPER', 'ISFT'
    $hits = [System.Collections.Generic.List[string]]::new()
    foreach ($t in $tags) {
        $i = $t.IndexOf('=')
        if ($i -lt 1) { continue }
        $key = $t.Substring(0, $i)
        if ($key -notin $scanKeys) { continue }
        $m = [regex]::Matches($t.Substring($i + 1), '(?i)\b(mp3|lame|aac|m4a|vorbis|ogg|opus|wma|atrac|lossy|transcod\w*|upsampl\w*|upconver\w*|youtube|\d{2,3}\s?kbps)\b')
        foreach ($x in $m) { $hits.Add("$key=$($x.Value)") }
    }
    if ($hits.Count -gt 0) {
        Add-Finding $fd 'WARNING' 'Suspicious terms in the metadata' ("The tags contain hints of a lossy origin: {0}. Check whether the file was created from MP3/AAC/Vorbis." -f (($hits | Select-Object -Unique) -join ', ')) 30
    }
    if ($flacInfo -and $flacInfo.Id3Bytes -gt 0) {
        Add-Finding $fd 'NOTE' 'ID3v2 tag in front of the FLAC header' 'An ID3v2 tag (typical for MP3) precedes the "fLaC" signature. That is not standard-conform for FLAC, some players cannot read the file, and it occasionally shows up with hastily renamed/rebuilt files.' 3
    }

    # --- Verdict -----------------------------------------------------------------------------
    $score = 0; foreach ($x in $fd) { $score += $x.Points }
    $score = [Math]::Min(100, $score)
    $r.Score = $score
    $r.Verdict = if ($r.IntegrityOk -eq $false) { 'DEFECTIVE' }
                 elseif ($score -ge 60) { 'LIKELY FAKE (lossy source)' }
                 elseif ($score -ge 30) { 'SUSPICIOUS' }
                 elseif ($score -ge 10) { 'CLEAN (with notes)' }
                 else { 'CLEAN' }
    if ($r.IntegrityOk -eq $false) { $r.Score = 100 }

    return [pscustomobject]$r
}

# Text of all worker functions - re-created inside every parallel runspace
$workerFunctions = 'Add-Finding', 'ConvertTo-Num', 'Set-FileProgress', 'Get-BandDb', 'Find-SpectralCutoff',
                   'Get-SourceEstimate', 'Format-Time', 'Start-SpectrogramRun', 'Get-AudioProbe', 'Invoke-FileAnalysis'
$fnText = ($workerFunctions | ForEach-Object {
        'function {0} {{{1}{2}{1}}}' -f $_, [Environment]::NewLine, (Get-Item "function:$_").ScriptBlock.ToString()
    }) -join [Environment]::NewLine

$losslessCodecs = @('flac', 'alac', 'ape', 'wavpack', 'tta', 'tak', 'wmalossless', 'truehd', 'mlp', 'shorten', 'mp4als')
$lossyCodecs = @('mp1', 'mp2', 'mp3', 'aac', 'aac_latm', 'vorbis', 'opus', 'speex', 'wmav1', 'wmav2', 'wmavoice', 'ac3', 'eac3',
                 'atrac1', 'atrac3', 'atrac3p', 'atrac9', 'amr_nb', 'amr_wb', 'cook', 'qdm2', 'musepack7', 'musepack8', 'sipr', 'ra_144', 'ra_288')

# ========================================================================================
#  Live dashboard (multi-worker progress display)
# ========================================================================================
function Get-DashboardLines {
    param($Board, [int]$Workers, [datetime]$Started, [int]$Frame, [int]$Budget)
    $w = Get-ConsoleWidth
    $P = $PSStyle
    $total = $Board.Files.Length
    $done = $Board.DoneCount
    $pct = $Board.AveragePercent()
    $elapsed = ((Get-Date) - $Started).TotalSeconds
    $etaTxt = if ($pct -ge 2 -and $pct -lt 100) { Format-Time ($elapsed * (100 - $pct) / $pct) } else { '--:--' }
    $spin = '|/-\'[$Frame % 4]

    $lines = [System.Collections.Generic.List[string]]::new()
    $head = " $spin Overall  $(Format-Bar $pct 26) {0,3:N0}%  {1}/{2} files  elapsed {3}  ETA {4}  {5} workers / {6} threads" -f $pct, $done, $total, (Format-Time $elapsed), $etaTxt, $Workers, $Budget
    $lines.Add($P.Bold + $P.Foreground.BrightCyan + (Limit-Text $head $w) + $P.Reset)
    $lines.Add($P.Foreground.BrightBlack + ' ' + ('─' * ($w - 2)) + $P.Reset)

    $running = $Board.GetRunning($Workers)
    $statusW = [Math]::Max(10, $w - 62)
    for ($i = 0; $i -lt $Workers; $i++) {
        if ($i -lt $running.Count) {
            $f = $running[$i]
            $txt = '  ► {0} {1} {2,3:N0}%  {3}' -f (Limit-Text $f.Name 30), (Format-Bar $f.Percent 16), $f.Percent, (Limit-Text $f.Status $statusW)
            $lines.Add($P.Foreground.BrightGreen + (Limit-Text $txt $w) + $P.Reset)
        }
        else { $lines.Add((Limit-Text '' $w)) }
    }
    $lines.Add($P.Foreground.BrightBlack + (Limit-Text '  Ctrl+C aborts the analysis' $w) + $P.Reset)
    return $lines
}

# ========================================================================================
#  Report rendering
# ========================================================================================
$sevColor = @{ CRITICAL = 'Red'; WARNING = 'Yellow'; NOTE = 'Cyan'; OK = 'Green' }
$sevIcon = @{ CRITICAL = '×'; WARNING = '▲'; NOTE = '●'; OK = '√' }

function Write-FileReport {
    param($R)
    $w = Get-ConsoleWidth
    $col = Get-VerdictColor $R.Verdict
    $icon = Get-VerdictIcon $R.Verdict
    $inner = $w - 4
    $right = " $($R.Verdict) · $($R.Score)/100 "
    $left = Limit-Text " $icon $($R.File)" ([Math]::Max(10, $inner - $right.Length))
    Write-Host ''
    Write-Host (' ┌' + ('─' * $inner) + '┐') -ForegroundColor $col
    Write-Host (' │' + $left + $right + '│') -ForegroundColor $col
    Write-Host (' └' + ('─' * $inner) + '┘') -ForegroundColor $col

    if ($null -ne $R.SampleRate) {
        $bitTxt = if ($R.Bits) { "$($R.Bits)-bit" + $(if ($null -ne $R.EffectiveBits) { " (effective $($R.EffectiveBits))" } else { '' }) } else { 'float/unknown bit depth' }
        Write-Host ('   {0,-11} {1}' -f 'Format', ('{0} · {1} Hz · {2} · {3} ch · {4} · ~{5} kbit/s' -f "$($R.Codec)".ToUpperInvariant(), $R.SampleRate, $bitTxt, $R.Channels, (Format-Time $R.DurationSec), $R.BitrateKbps))
        if ($R.Encoder) { Write-Host ('   {0,-11} {1}' -f 'Encoder', $R.Encoder) }
        if ($null -ne $R.PeakDb) { Write-Host ('   {0,-11} {1}' -f 'Levels', ('Peak {0:N1} dBFS · RMS {1:N1} dBFS · Crest {2:N1} dB · Clipping passages {3}' -f $R.PeakDb, $R.RmsDb, $R.CrestDb, $R.ClipRuns)) }
        $int = switch ($R.IntegrityOk) { $true { 'OK' } $false { 'FAILED' } default { 'unknown' } }
        $intCol = switch ($R.IntegrityOk) { $true { 'Green' } $false { 'Red' } default { 'Gray' } }
        Write-Host ('   {0,-11} ' -f 'Integrity') -NoNewline
        Write-Host ('{0} ({1}) · MD5: {2}' -f $int, $R.IntegrityMethod, $R.Md5Status) -ForegroundColor $intCol
        if ($R.CutoffKHz) { Write-Host ('   {0,-11} {1}' -f 'Cutoff', ('approx. {0:N1} kHz → {1}' -f $R.CutoffKHz, $R.EstimatedSource)) -ForegroundColor Yellow }
        if ($null -ne $R.FrameCliffPct) { Write-Host ('   {0,-11} {1}' -f 'Frame cliffs', ('{0}% of the analyzed frames show a sharp low-pass cliff' -f $R.FrameCliffPct)) -ForegroundColor DarkGray }
        if ($R.Seconds) { Write-Host ('   {0,-11} {1}' -f 'Analysis', ('{0:N1} s' -f $R.Seconds)) -ForegroundColor DarkGray }
    }
    Write-Host ''
    Write-Host '   Findings' -ForegroundColor White
    $shown = 0
    foreach ($x in $R.Findings) {
        $shown++
        $pts = if ($x.Points -gt 0) { " (+$($x.Points))" } else { '' }
        Write-Host ('   {0} {1,-8} {2}{3}' -f $sevIcon[$x.Severity], $x.Severity, $x.Title, $pts) -ForegroundColor $sevColor[$x.Severity]
        foreach ($l in (Format-Wrapped $x.Detail ($w - 14) '              ')) { Write-Host $l -ForegroundColor Gray }
    }
    if ($shown -eq 0) { Write-Host '   √ No findings.' -ForegroundColor Green }

    if ($R.Profile -and $R.Profile.Count -gt 0) {
        Write-Host ''
        Write-Host '   Spectrum profile (mean level per FFT bin - higher = more energy)' -ForegroundColor DarkGray
        foreach ($p in $R.Profile) { Write-Host ("     $p") -ForegroundColor DarkGray }
    }
    if ($R.Spectrogram) { Write-Host ('   Spectrogram  {0}' -f $R.Spectrogram) -ForegroundColor DarkGray }
    Write-Host ''
    Write-Host ('   Suspicion  [{0}] {1}/100  →  {2}' -f (Format-Bar $R.Score 24), $R.Score, $R.Verdict) -ForegroundColor $col
}

function Show-Summary {
    param($Results, [double]$Elapsed, [int]$Workers)
    $w = Get-ConsoleWidth
    Write-Host ''
    Write-Rule 'SUMMARY' 'Cyan'
    $groups = $Results | Group-Object { Get-VerdictShort $_.Verdict } | Sort-Object { ($_.Group | Measure-Object Score -Average).Average } -Descending
    Write-Host '  ' -NoNewline
    foreach ($g in $groups) {
        $v = $g.Group[0].Verdict
        Write-Host (' {0} {1}: {2} ' -f (Get-VerdictIcon $v), $g.Name, $g.Count) -ForegroundColor (Get-VerdictColor $v) -NoNewline
        Write-Host ' ' -NoNewline
    }
    Write-Host ''
    Write-Host ''
    $nameW = [Math]::Max(18, $w - 66)
    Write-Host ('   {0} {1,-13} {2,5}  {3} {4,-17} {5,8} {6,6}' -f ' ', 'VERDICT', 'SCORE', (Limit-Text 'FILE' $nameW), 'FORMAT', 'CUTOFF', 'TIME') -ForegroundColor DarkGray
    foreach ($r in ($Results | Sort-Object @{e = { $_.Score }; Descending = $true }, Index)) {
        $fmt = if ($r.SampleRate) { '{0} {1:0.#}k/{2}' -f "$($r.Codec)".ToUpperInvariant(), ($r.SampleRate / 1000), $(if ($r.Bits) { $r.Bits } else { 'f' }) } else { '-' }
        $cut = if ($r.CutoffKHz) { '{0:N1} kHz' -f $r.CutoffKHz } else { '-' }
        $tm = if ($r.Seconds) { '{0:N1}s' -f $r.Seconds } else { '-' }
        $line = '   {0} {1,-13} {2,5}  {3} {4,-17} {5,8} {6,6}' -f (Get-VerdictIcon $r.Verdict), (Get-VerdictShort $r.Verdict), $r.Score, (Limit-Text $r.File $nameW), (Limit-Text $fmt 17), $cut, $tm
        Write-Host $line -ForegroundColor (Get-VerdictColor $r.Verdict)
    }
    Write-Host ''
    Write-Host ('  Completed {0} file(s) in {1} using {2} worker(s).' -f $Results.Count, (Format-Time $Elapsed), $Workers) -ForegroundColor DarkGray
    Write-Host '  Results are indications, not proof. For SUSPICIOUS / LIKELY FAKE files check the spectrogram.' -ForegroundColor DarkGray
}

# ========================================================================================
#  Batch engine
# ========================================================================================
function Start-Analysis {
    param([string[]]$Targets)

    # --- collect files ---
    $extSet = @($Extensions | ForEach-Object { $_.ToLowerInvariant() })
    $rec = [bool]$S.Recurse
    $files = foreach ($p in $Targets) {
        if (Test-Path -LiteralPath $p -PathType Container) {
            Get-ChildItem -LiteralPath $p -File -Recurse:$rec | Where-Object { $extSet -contains $_.Extension.ToLowerInvariant() }
        }
        elseif (Test-Path -LiteralPath $p -PathType Leaf) { Get-Item -LiteralPath $p }
        else { Get-ChildItem -Path $p -File -ErrorAction SilentlyContinue }
    }
    $files = @($files | Sort-Object FullName -Unique)
    if ($files.Count -eq 0) {
        Write-Host ''
        Write-Host '  No supported audio files found at the given location(s).' -ForegroundColor Yellow
        return
    }

    if (@($files | Where-Object { $_.Extension -ieq '.flac' }).Count -gt 0) { Confirm-FlacTool }

    # --- C# engine (Add-Type compiles without optimizations by default; -optimize+ makes the FFT about 4x faster) ---
    if (-not ('FlacTools.AudioAnalyzer' -as [type])) { Add-Type -TypeDefinition $csharp -Language CSharp -CompilerOptions '-optimize+' }

    # --- workers ---
    if (-not $script:Sys) { $script:Sys = Get-SystemInfo }
    $plan = Get-WorkPlan $script:Sys $files.Count
    $workers = $plan.Workers
    $mode = if ($plan.Auto) { 'auto' } else { 'manual' }

    # --- output locations ---
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $specDir = $null
    if ($S.Spectrograms) {
        $specDir = if ($SpectrogramDir) { $SpectrogramDir } else { Join-Path $S.OutputDir 'Spectrograms' }
        New-Item -ItemType Directory -Path $specDir -Force | Out-Null
    }

    Write-Host ''
    Write-Rule 'ANALYSIS' 'Cyan'
    Write-Host ("  {0} file(s) · {1} worker(s) [{2}] · {3} FFT thread(s) per file · CPU: {4} ({5} cores / {6} threads, using {7})" -f $files.Count, $workers, $mode, $plan.FftThreads, $script:Sys.CpuName, $script:Sys.Physical, $script:Sys.Logical, $plan.Budget) -ForegroundColor Gray
    Write-Host ''

    $board = [FlacTools.ProgressBoard]::new([string[]]@($files | ForEach-Object { $_.Name }))
    $work = for ($i = 0; $i -lt $files.Count; $i++) { [pscustomobject]@{ Index = $i; Path = $files[$i].FullName } }

    $ffmpegExe = $script:ffmpeg; $ffprobeExe = $script:ffprobe; $flacExe = $script:flac
    $fftSz = [int]$S.FftSize; $specOut = $specDir; $fftThr = [int]$plan.FftThreads
    $lossless = $losslessCodecs; $lossy = $lossyCodecs; $fnSrc = $fnText

    $started = Get-Date
    $useVT = (-not [Console]::IsOutputRedirected) -and $Host.UI.SupportsVirtualTerminal
    $collected = [System.Collections.Generic.List[object]]::new()

    $job = $work | ForEach-Object -Parallel {
        $ErrorActionPreference = 'Stop'
        $item = $_
        $ffmpeg = $using:ffmpegExe; $ffprobe = $using:ffprobeExe; $flac = $using:flacExe
        $FftSize = $using:fftSz; $SpectrogramDir = $using:specOut; $FftThreads = $using:fftThr
        $losslessCodecs = $using:lossless; $lossyCodecs = $using:lossy
        $board = $using:board; $fileIndex = $item.Index
        . ([scriptblock]::Create($using:fnSrc))

        $sw = [Diagnostics.Stopwatch]::StartNew()
        $board.Start($fileIndex)
        try { $res = Invoke-FileAnalysis -File ([System.IO.FileInfo]::new($item.Path)) }
        catch {
            $res = [pscustomobject]@{
                File = [IO.Path]::GetFileName($item.Path); Path = $item.Path; Codec = $null; Verdict = 'ERROR DURING ANALYSIS'; Score = 100
                SampleRate = $null; Bits = $null; Profile = @()
                Findings = @([pscustomobject]@{ Severity = 'CRITICAL'; Title = 'Unexpected error'; Detail = $_.Exception.Message; Points = 0 })
            }
        }
        $res | Add-Member -NotePropertyName Index -NotePropertyValue $item.Index -Force
        $res | Add-Member -NotePropertyName Seconds -NotePropertyValue ([Math]::Round($sw.Elapsed.TotalSeconds, 1)) -Force
        $board.Finish($fileIndex, [string]$res.Verdict, [int]$res.Score)
        $res
    } -ThrottleLimit $workers -AsJob

    $lineCount = $workers + 3
    $frame = 0; $first = $true; $lastDone = -1
    try {
        if ($useVT) { [Console]::Write("$esc[?25l") }
        while ($job.State -notin 'Completed', 'Failed', 'Stopped') {
            foreach ($o in @(Receive-Job $job -ErrorAction SilentlyContinue)) { $collected.Add($o) }
            if ($useVT) {
                $lines = Get-DashboardLines $board $workers $started $frame $plan.Budget
                if (-not $first) { [Console]::Write("$esc[$($lines.Count)A") }
                foreach ($l in $lines) { [Console]::Write("$esc[2K$l`n") }
                $first = $false
            }
            elseif ($board.DoneCount -ne $lastDone) {
                $lastDone = $board.DoneCount
                Write-Host ("  [{0}/{1}] files completed..." -f $lastDone, $files.Count)
            }
            $frame++
            Start-Sleep -Milliseconds 120
        }
        foreach ($o in @(Receive-Job $job -ErrorAction SilentlyContinue)) { $collected.Add($o) }
    }
    finally {
        if ($job.State -eq 'Running') { Stop-Job $job -ErrorAction SilentlyContinue }
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        if ($useVT) {
            if (-not $first) { [Console]::Write("$esc[${lineCount}A$esc[0J") }
            [Console]::Write("$esc[?25h")
        }
    }
    $elapsed = ((Get-Date) - $started).TotalSeconds

    # files without a result (worker crashed) -> error entries
    $have = @{}; foreach ($o in $collected) { $have[[int]$o.Index] = $true }
    for ($i = 0; $i -lt $files.Count; $i++) {
        if (-not $have.ContainsKey($i)) {
            $collected.Add([pscustomobject]@{
                    File = $files[$i].Name; Path = $files[$i].FullName; Codec = $null; Verdict = 'ERROR DURING ANALYSIS'; Score = 100
                    SampleRate = $null; Bits = $null; Profile = @(); Index = $i; Seconds = $null
                    Findings = @([pscustomobject]@{ Severity = 'CRITICAL'; Title = 'No result'; Detail = 'The worker did not return a result for this file.'; Points = 0 })
                })
        }
    }
    $results = @($collected | Sort-Object Index)

    # --- detailed reports ---
    $detailMode = $S.Detail
    if ($detailMode -eq 'Auto') { $detailMode = if ($results.Count -le 3) { 'Full' } else { 'Issues' } }
    if ($detailMode -ne 'Brief') {
        foreach ($r in $results) {
            $isClean = $r.Verdict -in @('CLEAN', 'CLEAN (with notes)', 'SKIPPED')
            if ($detailMode -eq 'Full' -or -not $isClean) { Write-FileReport $r }
        }
    }
    Show-Summary $results $elapsed $workers

    # --- report files ---
    $csvPath = $null; $jsonPath = $null
    if ($S.Csv -or $S.Json) { New-Item -ItemType Directory -Path $S.OutputDir -Force | Out-Null }
    if ($S.Csv) {
        $csvPath = if ($ReportCsv) { $ReportCsv } else { Join-Path $S.OutputDir "lossless-report_$stamp.csv" }
        $results | Select-Object File, Path, Codec, Verdict, Score, SampleRate, Bits, EffectiveBits, Channels, DurationSec, BitrateKbps,
            CutoffKHz, EstimatedSource, IntegrityOk, IntegrityMethod, Md5Status, PeakDb, RmsDb, CrestDb, ClipRuns, FrameCliffPct, Encoder, Spectrogram, Seconds,
            @{n = 'Findings'; e = { ($_.Findings | ForEach-Object { "[{0}] {1}" -f $_.Severity, $_.Title }) -join ' | ' } } |
            Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding utf8 -Delimiter ';'
        Write-Host "  CSV report   : $csvPath" -ForegroundColor DarkGray
    }
    if ($S.Json) {
        $jsonPath = if ($ReportJson) { $ReportJson } else { Join-Path $S.OutputDir "lossless-report_$stamp.json" }
        $results | Select-Object * -ExcludeProperty Profile | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $jsonPath -Encoding utf8
        Write-Host "  JSON report  : $jsonPath" -ForegroundColor DarkGray
    }
    if ($specDir) { Write-Host "  Spectrograms : $specDir" -ForegroundColor DarkGray }

    foreach ($r in $results) { $script:AllResults.Add($r) }
}

# ========================================================================================
#  Built-in help
# ========================================================================================
function Get-HelpTopics {
    $t = [ordered]@{}

    $t['Quick start'] = @'
# What this tool does
It analyzes lossless audio files and tells you whether they really are lossless - or whether a lossy
file (MP3, AAC, ...) was merely converted into FLAC/WAV/ALAC (so-called "fake lossless").
# Using it
* Pick [1] Analyze in the main menu, then type a path or drag & drop files/folders into the window.
* Several paths can be entered at once; use "quotes" around paths that contain spaces.
* Folders are scanned for audio files (sub folders too - see Settings).
* A live dashboard shows every worker thread while the files are analyzed in parallel.
* Afterwards you get a verdict per file and a summary table. Press any key to return to the main menu.
# First run
* If ffmpeg is missing the tool asks whether it should download it (Yes/No) - as a PORTABLE copy into the
  'tools' folder next to the script. Nothing is installed system-wide and nothing goes to AppData.
* If you analyze FLAC files and "flac" is missing it asks the same - flac enables the official "flac -t" test.
! Results are indications, not proof. See "Limitations & troubleshooting".
'@

    $t['What gets checked'] = @'
# 1. Codec
Is the codec really lossless? An .m4a containing AAC or a .flac containing MP3 is flagged immediately.
# 2. Integrity
* FLAC: official "flac -t" (if available), the MD5 stored in the file, sample count.
* All formats: decoder errors from ffmpeg and the decoded length compared with the header.
# 3. Frequency cutoff of the average spectrum (the key test)
Lossy codecs low-pass the audio (e.g. MP3 128 kbit/s ends near 16 kHz). The tool computes the average
spectrum (FFT) and searches for an abrupt drop. Typical cutoffs: 16 kHz ~ MP3 128, 17-18 kHz ~ 160-192,
19 kHz ~ V2/V1, 20 kHz ~ V0/256-320 or AAC/Opus.
# 4. Time-resolved low-pass analysis (per frame)
Every single FFT frame is examined for a sharp spectral cliff. Lossy encoders cut the treble in (nearly)
every frame - at a fixed frequency (CBR/ABR) or at a frame-by-frame varying one (VBR/adaptive encoders).
A sharp cliff in 80 % or more of the frames is a strong lossy signature - even when the averaged spectrum
looks smooth because the cutoff wanders, and it helps with high-bitrate sources that end near 20 kHz.
# 5. Upsampling
A "96 kHz" file whose content ends at 22 kHz was upsampled from CD quality - no extra information.
# 6. Bit depth (fake hi-res)
Detected in three ways:
* unused low bits (a "24-bit" file in which only 16 bits are ever used)
* a coarse sample-value grid: only ~65,000 distinct values in millions of samples
* a comb-like value distribution around zero (16-bit material converted after a gain change or with dither)
# 7. Stereo
Dual mono (L = R), inverted phase, a silent channel.
# 8. Signal
Clipping, DC offset, peak/RMS/crest factor, digital-silence dropouts inside the track.
# 9. Metadata
Encoder/vendor string and tags that mention mp3, lame, aac, vorbis, opus, "320kbps", "transcoded" ...
'@

    $t['Verdict & score'] = @'
# Verdicts
* CLEAN              no relevant findings (score 0-9)
* CLEAN (with notes) only minor notes (score 10-29)
* SUSPICIOUS         warning signs, check the spectrogram (score 30-59)
* LIKELY FAKE        very probably a lossy source (score 60-100)
* LOSSY CODEC        the file natively contains a lossy codec (MP3/AAC/...) in a lossless-looking wrapper
* DEFECTIVE          integrity check failed (damaged / truncated file)
* SKIPPED            not analyzable (e.g. DSD)
# Score
Every finding adds suspicion points; the sum (max. 100) decides the verdict. Examples: hard cutoff below
16.5 kHz +80, fake 24-bit +40, upsampling +45, lossy hints in tags +30, dual mono +10.
# Severity levels
× CRITICAL  ▲ WARNING  ● NOTE  √ OK
'@

    $t['Reading a spectrogram'] = @'
# What you see
Time runs left to right, frequency bottom to top (0 Hz at the bottom, Nyquist at the top). Brighter = louder.
# Genuine lossless
* Energy fades out smoothly towards the top, usually reaching 20-22 kHz.
* No sharp horizontal "ceiling" below ~20 kHz.
# Fake lossless (lossy source)
* A razor-sharp horizontal ceiling, e.g. at 16 kHz (MP3 128) or 19-20 kHz (higher bitrates).
* Above the ceiling: black (digital silence) or only very faint noise.
* Lossy files often show "holes" or stripes in the treble that flicker over time.
# Upsampled hi-res
A 96 kHz file with a ceiling at 22 kHz: the whole upper half of the picture is empty.
! Old analog/tape recordings can have a natural ceiling too - compare with what you know about the source.
Enable spectrograms in Settings [4]; PNGs are written to the Output\Spectrograms folder.
'@

    $t['Supported formats'] = @'
# Lossless formats
FLAC, WAV (PCM), AIFF/AIFC, ALAC (.m4a/.alac), Monkey's Audio (APE), WavPack, TTA, TAK, Shorten, MLP/TrueHD,
CAF, W64, MKA (checked by the codec inside).
# Format specific checks
* FLAC: flac -t, embedded MD5, STREAMINFO sample count, header structure, ID3 prefix.
* All others: decoder errors and decoded length vs. header. The spectral/bit-depth/stereo tests apply to all.
# Not supported
DSD (1-bit) is skipped. Natively lossy codecs are reported as LOSSY CODEC.
'@

    $t['Performance & multithreading'] = @'
# Uses all CPU cores by default
Auto mode uses every detected logical CPU thread (see [4] System & tool info):
* many files  -> one worker per CPU thread, every worker analyzes one file
* few files   -> fewer workers; the remaining threads run a parallel FFT inside each file
* one file    -> a single worker, but the FFT work is spread over all cores
workers = min(CPU threads, free RAM / 400 MB, number of files, 64)
FFT threads per file = CPU threads / workers
# Overlapped stages
For every file, "flac -t" and the spectrogram rendering run in the background while the audio is decoded and
analyzed, so the slowest stage decides the time instead of the sum of all stages.
# Manual control
* Settings [1]  parallel files (workers), 0 = automatic
* Settings [2]  CPU thread budget, 0 = all detected threads (lower it to keep the PC responsive)
# Tips
* SSD / NVMe: automatic is fine.
* Hard disk or network share: set workers to 1-2 - many parallel readers slow a spinning disk down.
* Very large hi-res files need more RAM per worker; lower the worker count if memory gets tight.
* FFT size 16384 gives finer frequency resolution but costs more CPU time.
'@

    $t['Settings reference'] = @'
# Menu [2] Settings
* [1] Parallel files (workers)   0 = automatic, otherwise 1-64
* [2] CPU thread budget          0 = all detected threads, otherwise 1-256
* [3] FFT size                   2048 / 4096 / 8192 / 16384 (default 8192)
* [4] Report detail              Auto, Full, Issues, Brief
      Full = full report for every file, Issues = full report only for files with findings,
      Brief = summary table only, Auto = Full for up to 3 files, otherwise Issues
* [5] Spectrograms               write a spectrogram PNG for each file
* [6] CSV report                 write a CSV file with all results
* [7] JSON report                write a JSON file with all results incl. findings
* [8] Include sub folders        when a folder is analyzed
* [9] Output folder              where reports and spectrograms are stored (default: .\Output next to the script)
* [R] Reset to defaults
# Saved automatically
Every change is saved to LosslessAnalyzer.settings.json next to the script and loaded at the next start.
Command-line parameters override the saved values for that run only. [R] deletes the saved file.
'@

    $t['Command line usage'] = @'
# Examples
> Lossless-Analyzer.bat                                   interactive menu
> Lossless-Analyzer.bat -Path 'D:\Music' -Recurse         analyze, then back to the menu
> Lossless-Analyzer.bat -Path .\a.flac, .\b.wav -NoMenu   analyze and exit
> Lossless-Analyzer.bat -Help                             print this help and exit
* Parameters use PowerShell syntax. Put quotes around paths that contain spaces - "double quotes" when the
  path also contains characters such as & that cmd treats specially.
# Parameters
* -Path <paths>        files and/or folders
* -Recurse             include sub folders
* -Threads <0-64>      parallel files (workers), 0 = automatic
* -CpuThreads <0-256>  CPU thread budget, 0 = all detected threads
* -FftSize <n>         2048 | 4096 | 8192 | 16384
* -Detail <mode>       Auto | Full | Issues | Brief
* -SpectrogramDir <d>  write spectrograms to this folder
* -ReportCsv <file>    -ReportJson <file>    write report files
* -OutputDir <dir>     base folder for menu-created output
* -FfmpegPath / -FlacPath   explicit tool locations
* -ToolsDir <dir>      folder for the portable tools (default: .\tools next to the script)
* -Yes                 download missing tools without asking
* -NoMenu              exit after the analysis
* -PassThru            return result objects (use with -NoMenu)
'@

    $t['Limitations & troubleshooting'] = @'
# Limitations
! No script can prove a file is truly lossless - these are indications.
* High-bitrate lossy sources (MP3 V0/320, AAC 256) end near 20 kHz, just like many genuine CD masters.
  The per-frame analysis helps here, but a fixed 20 kHz filter in a mastering chain looks the same - so
  such cases are rated SUSPICIOUS at most, never LIKELY FAKE on this evidence alone.
* Old analog/tape/vinyl transfers may have a natural low-pass and look "suspicious".
* A file that was lossy -> lossless AND mastered further can hide its traces.
* Fake 24-bit detection needs a few minutes of material; very short or very quiet files are inconclusive.
  Heavy noise-shaped dither can hide the 16-bit grid.
* Mono and dual-mono recordings are legitimate; the tool only notes them.
# Troubleshooting
* "ffmpeg not found": answer Yes to the download prompt, or copy ffmpeg.exe + ffprobe.exe into the tools folder.
* Download fails (firewall/proxy/offline): download ffmpeg manually (gyan.dev "release essentials") and put
  ffmpeg.exe and ffprobe.exe into the tools folder, or pass -FfmpegPath.
* Tool lookup order: the 'tools' folder next to the script first, then programs available in PATH.
* Moving the folder to another PC: just copy the whole folder - the tools folder travels with it.
* No colors/bars: use Windows Terminal or a recent console; the tool falls back to simple output.
* PC becomes sluggish during big batches: lower the CPU thread budget in Settings [2].
* Slow on a hard disk or network share: reduce the worker count in Settings [1].
* flac -t reports errors: the file is damaged - re-rip or re-download it.
'@
    return $t
}

function Write-HelpText {
    param([string]$Text)
    foreach ($line in ($Text -split "`r?`n")) {
        switch -Regex ($line) {
            '^# ' { Write-Host ''; Write-Host ('  ' + $line.Substring(2)) -ForegroundColor Cyan }
            '^! ' { Write-Host ('  ▲ ' + $line.Substring(2)) -ForegroundColor Yellow }
            '^> ' { Write-Host ('    ' + $line.Substring(2)) -ForegroundColor Green }
            '^\* ' { Write-Host ('   • ' + $line.Substring(2)) -ForegroundColor Gray }
            default { Write-Host ('    ' + $line.TrimStart()) -ForegroundColor Gray }
        }
    }
}

function Show-AllHelp {
    $topics = Get-HelpTopics
    foreach ($k in $topics.Keys) {
        Write-Host ''
        Write-Rule $k 'Cyan'
        Write-HelpText $topics[$k]
    }
    Write-Host ''
}

function Show-HelpMenu {
    $topics = Get-HelpTopics
    $keys = @($topics.Keys)
    while ($true) {
        Write-Banner 'Help'
        Write-Host ''
        for ($i = 0; $i -lt $keys.Count; $i++) { Write-Host ('   [{0}] {1}' -f ($i + 1), $keys[$i]) -ForegroundColor White }
        Write-Host ''
        Write-Host '   [A] Show everything     [B] Back to main menu' -ForegroundColor DarkCyan
        $k = Read-MenuKey
        if ($k -eq 'B' -or $k -eq 'Q') { return }
        if ($k -eq 'A') { Write-Banner 'Help · everything'; Show-AllHelp; Wait-AnyKey '  Press any key to go back to the help menu...'; continue }
        if ($k -match '^[1-9]$' -and [int]$k -le $keys.Count) {
            $key = $keys[[int]$k - 1]
            Write-Banner "Help · $key"
            Write-HelpText $topics[$key]
            Wait-AnyKey '  Press any key to go back to the help menu...'
        }
    }
}

# ========================================================================================
#  Menus
# ========================================================================================
function Show-SystemInfo {
    Write-Banner 'System & tool info'
    if (-not $script:Sys) { $script:Sys = Get-SystemInfo }
    $sys = $script:Sys
    Write-Host ''
    Write-Rule 'Hardware' 'Cyan'
    Write-Host ('   CPU            {0}' -f $sys.CpuName)
    Write-Host ('   Cores/Threads  {0} physical / {1} logical' -f $sys.Physical, $sys.Logical)
    $ram = if ($sys.RamTotalGB) { '{0} GB total' -f $sys.RamTotalGB + $(if ($sys.RamFreeGB) { ', {0} GB free' -f $sys.RamFreeGB } else { '' }) } else { 'unknown' }
    Write-Host ('   Memory         {0}' -f $ram)
    Write-Host ('   OS             {0}' -f $sys.OS)
    Write-Host ('   PowerShell     {0}' -f $PSVersionTable.PSVersion)
    Write-Host ''
    Write-Rule 'Parallelism' 'Cyan'
    $planBig = Get-WorkPlan $sys 1000
    $planOne = Get-WorkPlan $sys 1
    Write-Host ('   CPU thread budget : {0} of {1} {2}' -f $planBig.Budget, $sys.Logical, $(if ($S.CpuThreads -gt 0) { '(manual)' } else { '(auto = all detected threads)' })) -ForegroundColor Green
    Write-Host ('   Large batch       : {0} workers x {1} FFT thread(s)' -f $planBig.Workers, $planBig.FftThreads)
    Write-Host ('   Single file       : {0} worker x {1} FFT threads' -f $planOne.Workers, $planOne.FftThreads)
    Write-Host ''
    Write-Rule 'Tools' 'Cyan'
    Write-Host ('   Tools folder  {0}' -f $ToolsRoot) -ForegroundColor DarkGray
    Write-Host ('   ffmpeg   {0}' -f $(if ($script:ffmpeg) { "√ $(Get-ToolVersion $script:ffmpeg @('-version'))" } else { '× not found' }))
    Write-Host ('            {0}{1}' -f $script:ffmpeg, $(if ($script:ffmpeg -and $script:ffmpeg.StartsWith($ToolsRoot)) { '   [portable]' } else { '   [system]' })) -ForegroundColor DarkGray
    Write-Host ('   ffprobe  {0}' -f $(if ($script:ffprobe) { "√ $($script:ffprobe)" } else { '× not found' }))
    Write-Host ('   flac     {0}' -f $(if ($script:flac) { "√ $(Get-ToolVersion $script:flac @('--version'))" } else { '× not available (optional - offered as a portable download when FLAC files are analyzed)' }))
    Wait-AnyKey '  Press any key to return to the main menu...'
}

function Show-SettingsMenu {
    if (-not $script:Sys) { $script:Sys = Get-SystemInfo }
    while ($true) {
        Write-Banner 'Settings'
        $onoff = { param($b) if ($b) { 'ON ' } else { 'OFF' } }
        $lg = $script:Sys.Logical
        Write-Host ''
        Write-Host ('   [1] Parallel files (workers) : {0}' -f $(if ($S.Threads -gt 0) { "$($S.Threads) (manual)" } else { 'auto' })) -ForegroundColor White
        Write-Host ('   [2] CPU thread budget        : {0}' -f $(if ($S.CpuThreads -gt 0) { "$($S.CpuThreads) of $lg (manual)" } else { "all $lg detected threads (auto)" })) -ForegroundColor White
        Write-Host ('   [3] FFT size                 : {0}' -f $S.FftSize) -ForegroundColor White
        Write-Host ('   [4] Report detail            : {0}' -f $S.Detail) -ForegroundColor White
        Write-Host ('   [5] Spectrograms             : {0}' -f (& $onoff $S.Spectrograms)) -ForegroundColor White
        Write-Host ('   [6] CSV report               : {0}' -f (& $onoff $S.Csv)) -ForegroundColor White
        Write-Host ('   [7] JSON report              : {0}' -f (& $onoff $S.Json)) -ForegroundColor White
        Write-Host ('   [8] Include subfolders       : {0}' -f (& $onoff $S.Recurse)) -ForegroundColor White
        Write-Host ('   [9] Output folder            : {0}' -f $S.OutputDir) -ForegroundColor White
        Write-Host ''
        Write-Host '   [R] Reset to defaults     [B] Back to main menu' -ForegroundColor DarkCyan
        Write-Host '   Changes are saved automatically.' -ForegroundColor DarkGray
        $k = Read-MenuKey
        $save = $true
        switch ($k) {
            '1' {
                $v = Read-Host '  Number of parallel files / workers (0 = auto, 1-64)'
                if ($v -match '^\d+$' -and [int]$v -le 64) { $S.Threads = [int]$v }
            }
            '2' {
                $v = Read-Host "  CPU thread budget (0 = all $lg detected threads)"
                if ($v -match '^\d+$' -and [int]$v -le 256) { $S.CpuThreads = [int]$v }
            }
            '3' { $o = 2048, 4096, 8192, 16384; $S.FftSize = $o[([array]::IndexOf($o, [int]$S.FftSize) + 1) % $o.Count] }
            '4' { $o = 'Auto', 'Full', 'Issues', 'Brief'; $S.Detail = $o[([array]::IndexOf($o, $S.Detail) + 1) % $o.Count] }
            '5' { $S.Spectrograms = -not $S.Spectrograms }
            '6' { $S.Csv = -not $S.Csv }
            '7' { $S.Json = -not $S.Json }
            '8' { $S.Recurse = -not $S.Recurse }
            '9' { $v = Read-Host '  Output folder'; if ($v.Trim()) { $S.OutputDir = $v.Trim().Trim('"') } }
            'R' {
                $d = Get-DefaultSettings
                foreach ($key in @($d.Keys)) { $S[$key] = $d[$key] }
                Remove-Item -LiteralPath $settingsFile -ErrorAction SilentlyContinue
                $save = $false
            }
            'B' { return }
        }
        if ($save) { Export-Settings }
    }
}

function ConvertTo-PathList {
    param([string]$Text)
    $t = $Text.Trim()
    if (-not $t) { return @() }
    $whole = $t.Trim('"').Trim("'")
    if (Test-Path -LiteralPath $whole) { return , $whole }
    $out = foreach ($m in [regex]::Matches($t, '"([^"]+)"|''([^'']+)''|(\S+)')) {
        ($m.Groups[1].Value, $m.Groups[2].Value, $m.Groups[3].Value | Where-Object { $_ })[0]
    }
    return @($out)
}

function Invoke-AnalyzePrompt {
    Write-Banner 'Analyze files or folders'
    Write-Host ''
    Write-Host '   Enter one or more files/folders, or drag & drop them into this window.' -ForegroundColor Gray
    Write-Host '   Use "quotes" around paths with spaces. Leave empty to go back.' -ForegroundColor DarkGray
    Write-Host ''
    $in = Read-Host '  Path(s) »'
    $paths = ConvertTo-PathList $in
    if ($paths.Count -eq 0) { return }
    Start-Analysis -Targets $paths
    Wait-AnyKey
}

function Show-MainMenu {
    Write-Banner
    if (-not $script:Sys) { $script:Sys = Get-SystemInfo }
    $sys = $script:Sys
    $planMenu = Get-WorkPlan $sys 1000
    $thr = if ($S.Threads -gt 0 -or $S.CpuThreads -gt 0) { "manual ($($planMenu.Workers) workers, $($planMenu.Budget) threads)" } else { "auto - all $($sys.Logical) threads" }
    Write-Host ''
    Write-Host ('   {0}' -f $sys.CpuName) -ForegroundColor DarkGray
    Write-Host ('   {0} cores / {1} threads · CPU use: {2} · FFT {3}' -f $sys.Physical, $sys.Logical, $thr, $S.FftSize) -ForegroundColor DarkGray
    Write-Host ('   ffmpeg {0}   flac {1}' -f $(if ($script:ffmpeg) { '√' } else { '×' }), $(if ($script:flac) { '√' } else { '–' })) -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '   [1]  Analyze files or folders' -ForegroundColor White
    Write-Host '   [2]  Settings' -ForegroundColor White
    Write-Host '   [3]  Help' -ForegroundColor White
    Write-Host '   [4]  System & tool info' -ForegroundColor White
    Write-Host '   [Q]  Quit' -ForegroundColor DarkCyan
}

# ========================================================================================
#  Entry point
# ========================================================================================
# ----------------------------------------------------------------------------------------
#  Settings: defaults -> saved file -> command-line parameters
# ----------------------------------------------------------------------------------------
$settingsFile = Join-Path $scriptDir 'LosslessAnalyzer.settings.json'

function Get-DefaultSettings {
    return [ordered]@{
        Threads      = 0
        CpuThreads   = 0
        FftSize      = 8192
        Detail       = 'Auto'
        Spectrograms = $false
        Csv          = $false
        Json         = $false
        Recurse      = $true
        OutputDir    = (Join-Path $scriptDir 'Output')
    }
}

function Import-Settings {
    $d = Get-DefaultSettings
    if (Test-Path -LiteralPath $settingsFile) {
        try {
            $j = Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json
            foreach ($k in @($d.Keys)) { if ($null -ne $j.$k) { $d[$k] = $j.$k } }
            $d.Threads = [Math]::Min(64, [Math]::Max(0, [int]$d.Threads))
            $d.CpuThreads = [Math]::Min(256, [Math]::Max(0, [int]$d.CpuThreads))
            if ([int]$d.FftSize -notin 2048, 4096, 8192, 16384) { $d.FftSize = 8192 }
            $d.FftSize = [int]$d.FftSize
            if ($d.Detail -notin 'Auto', 'Full', 'Issues', 'Brief') { $d.Detail = 'Auto' }
            foreach ($k in 'Spectrograms', 'Csv', 'Json', 'Recurse') { $d[$k] = [bool]$d[$k] }
            if (-not "$($d.OutputDir)".Trim()) { $d.OutputDir = Join-Path $scriptDir 'Output' }
        }
        catch { $d = Get-DefaultSettings }
    }
    return $d
}

function Export-Settings {
    try { $S | ConvertTo-Json | Set-Content -LiteralPath $settingsFile -Encoding utf8 } catch { }
}

$S = Import-Settings
if ($PSBoundParameters.ContainsKey('Threads')) { $S.Threads = $Threads }
if ($PSBoundParameters.ContainsKey('CpuThreads')) { $S.CpuThreads = $CpuThreads }
if ($PSBoundParameters.ContainsKey('FftSize')) { $S.FftSize = $FftSize }
if ($PSBoundParameters.ContainsKey('Detail')) { $S.Detail = $Detail }
if ($SpectrogramDir) { $S.Spectrograms = $true }
if ($ReportCsv) { $S.Csv = $true }
if ($ReportJson) { $S.Json = $true }
if ($OutputDir) { $S.OutputDir = $OutputDir }
if ($Path) { $S.Recurse = $Recurse.IsPresent }

if ($Help) { Show-AllHelp; return }

Set-ConsoleSize
Write-Banner
try { Initialize-Tools }
catch {
    Write-Host ''
    Write-Host ('  × ' + $_.Exception.Message) -ForegroundColor Red
    Wait-AnyKey '  Press any key to exit...'
    return
}

if ($Path) {
    Start-Analysis -Targets $Path
    if ($NoMenu) { if ($PassThru) { $script:AllResults }; return }
    Wait-AnyKey
}
elseif ($NoMenu) {
    Write-Warning 'Nothing to do: -NoMenu was given without -Path.'
    return
}

while ($true) {
    Show-MainMenu
    switch (Read-MenuKey) {
        '1' { Invoke-AnalyzePrompt }
        '2' { Show-SettingsMenu }
        '3' { Show-HelpMenu }
        'H' { Show-HelpMenu }
        '4' { Show-SystemInfo }
        'Q' { Write-Host ''; Write-Host '  Goodbye!' -ForegroundColor Cyan; if ($PassThru) { $script:AllResults }; return }
    }
}
