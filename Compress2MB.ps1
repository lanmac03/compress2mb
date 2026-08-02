<#
.SYNOPSIS
    Compress a video to fit under a target file size.

.DESCRIPTION
    Computes the exact bitrate needed to hit the target size, then picks the
    highest resolution and frame-rate combination that still has enough bits
    per pixel to look acceptable. Encodes two-pass x264 and AAC into a
    fast-start MP4 for broad playback compatibility.

.EXAMPLE
    .\Compress2MB.ps1 -Path "C:\clips\raid.mkv"
    .\Compress2MB.ps1 -Path "C:\clips\raid.mkv" -TargetMB 50
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string] $Path,

    # Target size in megabytes.
    [ValidateRange(1, 2000)]
    [double] $TargetMB = 10,

    # Ask for the target size interactively. Used by the custom context-menu entry.
    [switch] $PromptForTarget,

    # x264 speed/efficiency tradeoff. slower = smaller/better, more time.
    [ValidateSet('ultrafast','superfast','veryfast','faster','fast','medium','slow','slower','veryslow')]
    [string] $Preset = 'medium',

    # Minimum bits per pixel per frame we are willing to accept before
    # stepping down the resolution/fps ladder. Lower = sharper but blockier.
    [double] $MinBpp = 0.045,

    # Hold the window open at the end (used by the right-click entries).
    [switch] $Pause
)

$ErrorActionPreference = 'Stop'

# Console output

function Write-Step { param([string] $Message) Write-Host "  $Message" -ForegroundColor Cyan }
function Write-Info { param([string] $Message) Write-Host "  $Message" -ForegroundColor Gray }
function Write-Good { param([string] $Message) Write-Host "  $Message" -ForegroundColor Green }
function Write-Bad  { param([string] $Message) Write-Host "  $Message" -ForegroundColor Red }

function Resolve-Tool {
    param([string] $Name)

    $local = Join-Path $PSScriptRoot "bin\$Name.exe"
    if (Test-Path $local) { return $local }

    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    return $null
}

function Get-FpsFromRatio {
    param([string] $Ratio)
    if ([string]::IsNullOrWhiteSpace($Ratio)) { return 0 }
    $parts = $Ratio -split '/'
    if ($parts.Count -ne 2) { return 0 }
    $den = [double]$parts[1]
    if ($den -eq 0) { return 0 }
    return [double]$parts[0] / $den
}

function Format-Size {
    param([double] $Bytes)
    return ('{0:N2} MB' -f ($Bytes / 1MB))
}

function Read-TargetSize {
    while ($true) {
        $response = Read-Host ' Target size in MB (1-2000, blank to cancel)'
        if ([string]::IsNullOrWhiteSpace($response)) {
            return $null
        }

        $parsedTarget = 0.0
        if ([double]::TryParse($response, [ref]$parsedTarget) -and
            $parsedTarget -ge 1 -and $parsedTarget -le 2000) {
            return $parsedTarget
        }

        Write-Bad 'Enter a number from 1 to 2000.'
    }
}

# Setup

Write-Host ""
Write-Host " Compress2MB" -ForegroundColor White
Write-Host " ===========" -ForegroundColor DarkGray

$exitCode = 0

try {
    if ($PromptForTarget) {
        $selectedTarget = Read-TargetSize
        if ($null -eq $selectedTarget) {
            Write-Info 'Cancelled.'
            return
        }
        $TargetMB = $selectedTarget
    }

    $ffmpeg  = Resolve-Tool 'ffmpeg'
    $ffprobe = Resolve-Tool 'ffprobe'

    if (-not $ffmpeg -or -not $ffprobe) {
        throw 'FFmpeg was not found. Re-run Install.cmd to repair the installation.'
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "File not found: $Path"
    }

    $src = Get-Item -LiteralPath $Path
    $targetBytes = [long]($TargetMB * 1MB)

    Write-Info "Input : $($src.Name)"
    Write-Info "Size  : $(Format-Size $src.Length)  ->  target under $TargetMB MB"

    if ($src.Length -le $targetBytes) {
        Write-Good "Already under $TargetMB MB. Nothing to do."
        return
    }

    # Probe input

    $probeJson = & $ffprobe -v quiet -print_format json -show_format -show_streams -- "$($src.FullName)"
    if ($LASTEXITCODE -ne 0 -or -not $probeJson) {
        throw "ffprobe could not read this file. Is it a video?"
    }

    $probe = ($probeJson -join "`n") | ConvertFrom-Json

    $vStream = $probe.streams | Where-Object { $_.codec_type -eq 'video' } | Select-Object -First 1
    $aStream = $probe.streams | Where-Object { $_.codec_type -eq 'audio' } | Select-Object -First 1

    if (-not $vStream) { throw "No video stream found in this file." }

    $duration = 0.0
    if ($probe.format.duration) { $duration = [double]$probe.format.duration }
    if ($duration -le 0 -and $vStream.duration) { $duration = [double]$vStream.duration }
    if ($duration -le 0) { throw "Could not determine duration." }

    $srcW = [int]$vStream.width
    $srcH = [int]$vStream.height

    $srcFps = Get-FpsFromRatio $vStream.avg_frame_rate
    if ($srcFps -le 0) { $srcFps = Get-FpsFromRatio $vStream.r_frame_rate }
    if ($srcFps -le 0) { $srcFps = 30 }

    $hasAudio = [bool]$aStream

    Write-Info ("Source: {0}x{1} @ {2:N0} fps, {3:N1}s{4}" -f $srcW, $srcH, $srcFps, $duration, $(if ($hasAudio) { ", audio" } else { ", no audio" }))

    # Calculate the bitrate budget

    # 4% headroom for the MP4 container overhead and rate-control overshoot.
    $totalKbps = ($targetBytes * 8 / 1000) / $duration * 0.96

    $audioKbps = 0
    $audioMono = $false
    if ($hasAudio) {
        if     ($totalKbps -gt 900) { $audioKbps = 128 }
        elseif ($totalKbps -gt 500) { $audioKbps = 96 }
        elseif ($totalKbps -gt 250) { $audioKbps = 64 }
        else                        { $audioKbps = 48; $audioMono = $true }
    }

    $videoKbps = [math]::Floor($totalKbps - $audioKbps)
    if ($videoKbps -lt 60) {
        throw ("Video is too long for {0} MB ({1:N0}s needs more than the budget allows). Trim it first." -f $TargetMB, $duration)
    }

    # Never spend more bits than the source actually has.
    $srcKbps = 0
    if ($probe.format.bit_rate) { $srcKbps = [double]$probe.format.bit_rate / 1000 }
    if ($srcKbps -gt 0 -and $videoKbps -gt $srcKbps) {
        $videoKbps = [math]::Floor($srcKbps)
        Write-Info "Budget exceeds source bitrate; capping (result will be well under target)."
    }

    # Choose a resolution and frame rate

    # Ordered best-to-worst. Heights refer to the SHORT side, so portrait
    # video steps down correctly too. Resolution is protected before fps
    # drops below 30, then 24 fps is the last resort.
    $ladder = @(
        @{ H = $srcH; Fps = $srcFps },
        @{ H = $srcH; Fps = 30 },
        @{ H = 1440;  Fps = 30 },
        @{ H = 1080;  Fps = 30 },
        @{ H = 900;   Fps = 30 },
        @{ H = 720;   Fps = 30 },
        @{ H = 540;   Fps = 30 },
        @{ H = 480;   Fps = 30 },
        @{ H = 360;   Fps = 30 },
        @{ H = 360;   Fps = 24 }
    )

    $shortSide = [math]::Min($srcW, $srcH)
    $aspect    = [double]$srcW / [double]$srcH

    $chosen = $null
    foreach ($rung in $ladder) {
        $h = [math]::Min([int]$rung.H, $shortSide)
        $f = [math]::Min([double]$rung.Fps, $srcFps)

        # Pixel count at this rung, respecting orientation.
        if ($srcW -ge $srcH) { $w = $h * $aspect } else { $w = $h / $aspect }
        $pixels = $w * $h

        $bpp = ($videoKbps * 1000) / ($pixels * $f)
        if ($bpp -ge $MinBpp) {
            $chosen = @{ H = $h; Fps = $f; Bpp = $bpp }
            break
        }
    }

    if (-not $chosen) {
        # Nothing met the quality floor - take the bottom rung anyway.
        $h = [math]::Min(360, $shortSide)
        $f = [math]::Min(24, $srcFps)
        $chosen = @{ H = $h; Fps = $f; Bpp = 0 }
        Write-Info "Very tight budget - falling back to the lowest ladder rung."
    }

    $scaleChanged = $chosen.H -lt $shortSide
    $fpsChanged   = $chosen.Fps -lt ($srcFps - 0.5)

    $plan = "{0}p" -f $chosen.H
    if (-not $scaleChanged) { $plan = "{0}p (unchanged)" -f $chosen.H }
    Write-Step ("Plan  : {0}, {1:N0} fps, {2:N0} kbps video{3}" -f $plan, $chosen.Fps, $videoKbps, $(if ($hasAudio) { ", $audioKbps kbps audio" } else { "" }))

    # Build FFmpeg arguments

    $filters = @()
    if ($fpsChanged)   { $filters += ("fps={0}" -f [math]::Round($chosen.Fps, 3)) }
    if ($scaleChanged) {
        if ($srcW -ge $srcH) { $filters += ("scale=-2:{0}:flags=lanczos" -f $chosen.H) }
        else                 { $filters += ("scale={0}:-2:flags=lanczos" -f $chosen.H) }
    }
    # Guarantee even dimensions even when we did not rescale.
    $filters += 'scale=trunc(iw/2)*2:trunc(ih/2)*2'

    $vf = $filters -join ','

    $outDir  = $src.DirectoryName
    $outBase = "{0}-{1}MB" -f [IO.Path]::GetFileNameWithoutExtension($src.Name), $TargetMB
    $outPath = Join-Path $outDir "$outBase.mp4"
    $n = 2
    while (Test-Path -LiteralPath $outPath) {
        $outPath = Join-Path $outDir ("{0}-{1}.mp4" -f $outBase, $n)
        $n++
    }

    $logBase = Join-Path ([IO.Path]::GetTempPath()) ("v10_" + [Guid]::NewGuid().ToString('N'))

    $commonIn = @('-hide_banner', '-loglevel', 'error', '-stats', '-y', '-i', $src.FullName)
    $commonV  = @('-map', '0:v:0', '-vf', $vf, '-c:v', 'libx264', '-preset', $Preset,
                  '-profile:v', 'high', '-level', '4.1', '-pix_fmt', 'yuv420p')

    # Encode

    Write-Step "Pass 1 of 2 (analysing)..."
    $p1 = $commonIn + $commonV + @('-b:v', "$([int]$videoKbps)k", '-pass', '1',
                                   '-passlogfile', $logBase, '-an', '-f', 'null', 'NUL')
    & $ffmpeg @p1
    if ($LASTEXITCODE -ne 0) { throw "ffmpeg failed during pass 1." }

    $attempt = 0
    $bitrate = [int]$videoKbps

    while ($true) {
        $attempt++
        if ($attempt -eq 1) { Write-Step "Pass 2 of 2 (encoding)..." }
        else                { Write-Step "Overshot the target - re-encoding at $bitrate kbps (attempt $attempt)..." }

        $p2 = $commonIn + $commonV + @('-b:v', "${bitrate}k", '-pass', '2', '-passlogfile', $logBase)
        if ($hasAudio) {
            $p2 += @('-map', '0:a:0', '-c:a', 'aac', '-b:a', "${audioKbps}k")
            if ($audioMono) { $p2 += @('-ac', '1') }
        } else {
            $p2 += '-an'
        }
        $p2 += @('-movflags', '+faststart', $outPath)

        & $ffmpeg @p2
        if ($LASTEXITCODE -ne 0) { throw "ffmpeg failed during pass 2." }

        $actual = (Get-Item -LiteralPath $outPath).Length
        if ($actual -le $targetBytes) { break }

        if ($attempt -ge 3) {
            Write-Bad ("Could not get under {0} MB after {1} attempts (landed at {2})." -f $TargetMB, $attempt, (Format-Size $actual))
            break
        }

        # Scale the bitrate by how far we overshot, plus a little extra margin.
        $bitrate = [int][math]::Floor($bitrate * ($targetBytes / $actual) * 0.96)
        if ($bitrate -lt 50) { $bitrate = 50 }
    }

    # Report the result

    $final = Get-Item -LiteralPath $outPath
    $pct = 100 - ($final.Length / $src.Length * 100)

    Write-Host ""
    Write-Good "Done: $($final.Name)"
    Write-Good ("{0}  ->  {1}   ({2:N0}% smaller)" -f (Format-Size $src.Length), (Format-Size $final.Length), $pct)
    Write-Host ""
}
catch {
    Write-Host ""
    Write-Bad "Failed: $($_.Exception.Message)"
    Write-Host ""
    $exitCode = 1
}
finally {
    if ($logBase) {
        Get-ChildItem -Path ([IO.Path]::GetTempPath()) -Filter ((Split-Path $logBase -Leaf) + '*') -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    if ($Pause) {
        if ($exitCode -eq 0) {
            Write-Host " Closing in 5 seconds..." -ForegroundColor DarkGray
            Start-Sleep -Seconds 5
        } else {
            Read-Host " Press Enter to close"
        }
    }
}

exit $exitCode
