# Compress2MB

Right-click a video in Windows Explorer and create an MP4 that fits under any
target file size. Everything runs locally; videos are never uploaded to a
third-party service.

The default menu stays simple:

- Compress to 10 MB
- Compress to custom size - any target from 1 to 2000 MB

## Install

1. Choose **Code** -> **Download ZIP** on GitHub, then extract it.
2. Double-click `Install.cmd`.
3. Wait for FFmpeg to download on the first installation.
4. Right-click a video and choose **Show more options**.

No administrator rights are required. The installer copies the application to:

```text
%LOCALAPPDATA%\Programs\Compress2MB
```

The downloaded ZIP can be deleted after installation. Running a newer
`Install.cmd` upgrades the existing installation in place.

PowerShell users can customize the preset sizes:

```powershell
.\Install.ps1 -Sizes 10,25,100
```

Use `-NoCustomSize` to omit the custom-size entry or `-NoExplorerRestart` to
leave Explorer running until your next sign-in.

## Uninstall

Remove **Compress2MB** from Windows Settings under **Installed
apps**, or run:

```text
%LOCALAPPDATA%\Programs\Compress2MB\Uninstall.cmd
```

Uninstalling removes the context-menu entries, downloaded FFmpeg binaries, and
installed application files.

## Command line

After installation:

```powershell
& "$env:LOCALAPPDATA\Programs\Compress2MB\Compress2MB.ps1" -Path "C:\clips\raid.mkv"
& "$env:LOCALAPPDATA\Programs\Compress2MB\Compress2MB.ps1" -Path "C:\clips\raid.mkv" -TargetMB 50
```

Output is written beside the input as `<name>-10MB.mp4`. The original file is
never modified.

| Parameter | Default | Purpose |
|---|---:|---|
| `TargetMB` | `10` | Maximum output size in MB. |
| `PromptForTarget` | off | Ask for a target size in the console. |
| `Preset` | `medium` | x264 speed and efficiency preset. |
| `MinBpp` | `0.045` | Quality floor used by the resolution ladder. |
| `Pause` | off | Keep the console visible for context-menu use. |

## How it works

The script calculates a bitrate budget from the target size and video duration,
then selects the highest resolution and frame rate that fit its quality floor.
It uses two-pass x264 encoding with AAC audio and writes a fast-start MP4 for
broad playback compatibility.

If the first encode exceeds the target, the second pass is repeated at a
corrected bitrate up to two more times. Short clips can retain their source
resolution; long clips step down through a resolution and frame-rate ladder.

## Supported input types

The Explorer menu is registered for MP4, MKV, MOV, AVI, WebM, M4V, WMV, FLV,
MPG, MPEG, TS, M2TS, MTS, 3GP, and OGV files. FFmpeg may support additional
formats from the command line.

## Known limits

- Windows 11 places third-party entries under **Show more options**. A modern
  top-level entry requires a packaged `IExplorerCommand` shell extension.
- Selecting several files launches one console window per file.
- Very long videos can look rough at small targets; the available bitrate is
  the limiting factor.
- The installer restarts Explorer so the new entries appear immediately. Use
  `-NoExplorerRestart` if you have Explorer windows you do not want closed.

## FFmpeg

FFmpeg is not stored in this repository. During installation, the current
essentials build is downloaded from [gyan.dev](https://www.gyan.dev/ffmpeg/builds/).
That build is distributed under GPLv3. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)
for details.

## License

The PowerShell and command scripts in this repository are available under the
[MIT License](LICENSE). FFmpeg is a separate program under its own license.
