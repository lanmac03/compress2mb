<#
.SYNOPSIS
    Installs Discord Video Compressor for the current Windows user.

.DESCRIPTION
    Copies the application to a stable LocalAppData folder, downloads FFmpeg
    when needed, and registers Windows Explorer context-menu entries. No
    administrator rights are required.
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 2000)]
    [double[]] $Sizes = @(10, 50, 500),
    [switch] $NoCustomSize,
    [switch] $NoDownload,
    [switch] $NoExplorerRestart,
    [string] $InstallDirectory = (Join-Path $env:LOCALAPPDATA 'Programs\DiscordVideoCompressor')
)

$ErrorActionPreference = 'Stop'

$applicationName = 'Discord Video Compressor'
$applicationVersion = '1.0.0'
$registryVerbPrefix = 'DiscordVideoCompressor'
$installedScript = Join-Path $InstallDirectory 'VideoTo10mb.ps1'
$installedBinDirectory = Join-Path $InstallDirectory 'bin'
$extensions = @(
    '.mp4', '.mkv', '.mov', '.avi', '.webm', '.m4v', '.wmv', '.flv',
    '.mpg', '.mpeg', '.ts', '.m2ts', '.mts', '.3gp', '.ogv'
)

function Copy-ApplicationFile {
    param([Parameter(Mandatory = $true)][string] $Name)

    $sourcePath = Join-Path $PSScriptRoot $Name
    $destinationPath = Join-Path $InstallDirectory $Name
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        throw "$Name is missing from the release folder."
    }

    if ([IO.Path]::GetFullPath($sourcePath) -ne [IO.Path]::GetFullPath($destinationPath)) {
        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
    }
}

function Test-FfmpegPresent {
    $localFfmpeg = Join-Path $installedBinDirectory 'ffmpeg.exe'
    $localFfprobe = Join-Path $installedBinDirectory 'ffprobe.exe'
    if ((Test-Path -LiteralPath $localFfmpeg) -and (Test-Path -LiteralPath $localFfprobe)) {
        return $true
    }

    $ffmpegCommand = Get-Command ffmpeg -ErrorAction SilentlyContinue
    $ffprobeCommand = Get-Command ffprobe -ErrorAction SilentlyContinue
    return [bool]($ffmpegCommand -and $ffprobeCommand)
}

function Test-SourceFfmpegPresent {
    $sourceBinDirectory = Join-Path $PSScriptRoot 'bin'
    return (
        (Test-Path -LiteralPath (Join-Path $sourceBinDirectory 'ffmpeg.exe')) -and
        (Test-Path -LiteralPath (Join-Path $sourceBinDirectory 'ffprobe.exe'))
    )
}

function Remove-ExistingContextMenuEntries {
    foreach ($extension in $extensions) {
        $shellKey = "HKCU:\Software\Classes\SystemFileAssociations\$extension\shell"
        Get-ChildItem -Path $shellKey -ErrorAction SilentlyContinue |
            Where-Object {
                $_.PSChildName -like "$registryVerbPrefix*" -or
                $_.PSChildName -like 'VideoTo10mb*'
            } |
            Remove-Item -Recurse -Force
    }

    foreach ($staleKey in @(
        'HKCU:\Software\Classes\VideoTo10mb.Menu',
        'HKCU:\Software\Classes\SystemFileAssociations\video\shell\VideoTo10mb',
        'HKCU:\Software\Classes\SystemFileAssociations\video\ContextMenus\VideoTo10mb'
    )) {
        if (Test-Path $staleKey) {
            Remove-Item $staleKey -Recurse -Force
        }
    }
}

Write-Host ''
Write-Host " Installing $applicationName" -ForegroundColor White
Write-Host ' ==============================' -ForegroundColor DarkGray

New-Item -ItemType Directory -Path $InstallDirectory -Force | Out-Null
foreach ($applicationFile in @('VideoTo10mb.ps1', 'Uninstall.ps1', 'Uninstall.cmd')) {
    Copy-ApplicationFile $applicationFile
}
Write-Host "  Files:  $InstallDirectory" -ForegroundColor Green

if (Test-FfmpegPresent) {
    Write-Host '  FFmpeg: found' -ForegroundColor Green
}
elseif (Test-SourceFfmpegPresent) {
    New-Item -ItemType Directory -Path $installedBinDirectory -Force | Out-Null
    foreach ($executableName in @('ffmpeg.exe', 'ffprobe.exe')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot "bin\$executableName") -Destination $installedBinDirectory -Force
    }
    Write-Host '  FFmpeg: copied from the release folder' -ForegroundColor Green
}
elseif ($NoDownload) {
    Write-Host '  FFmpeg: missing (-NoDownload set)' -ForegroundColor Yellow
}
else {
    Write-Host '  FFmpeg: downloading the current essentials build...' -ForegroundColor Cyan

    $downloadUrl = 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip'
    $temporaryName = 'discord-video-compressor-' + [Guid]::NewGuid().ToString('N')
    $temporaryZip = Join-Path ([IO.Path]::GetTempPath()) "$temporaryName.zip"
    $temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) $temporaryName

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $downloadUrl -OutFile $temporaryZip -UseBasicParsing

        Write-Host '  FFmpeg: extracting...' -ForegroundColor Cyan
        Expand-Archive -LiteralPath $temporaryZip -DestinationPath $temporaryDirectory -Force
        New-Item -ItemType Directory -Path $installedBinDirectory -Force | Out-Null

        foreach ($executableName in @('ffmpeg.exe', 'ffprobe.exe')) {
            $executable = Get-ChildItem -Path $temporaryDirectory -Recurse -Filter $executableName |
                Select-Object -First 1
            if (-not $executable) {
                throw "$executableName was not found in the downloaded archive."
            }
            Copy-Item -LiteralPath $executable.FullName -Destination $installedBinDirectory -Force
        }

        if (-not (Test-FfmpegPresent)) {
            throw 'FFmpeg extraction completed, but the required executables are missing.'
        }
        Write-Host '  FFmpeg: installed' -ForegroundColor Green
    }
    finally {
        Remove-Item -LiteralPath $temporaryZip -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Remove-ExistingContextMenuEntries

$presetLabels = @{
    10 = 'Compress to 10 MB (Discord Free)'
    50 = 'Compress to 50 MB (Nitro Basic)'
    500 = 'Compress to 500 MB (Nitro)'
}
foreach ($extension in $extensions) {
    $shellKey = "HKCU:\Software\Classes\SystemFileAssociations\$extension\shell"
    $verbIndex = 0

    foreach ($size in $Sizes) {
        $verbIndex++
        $label = "Compress to $size MB"
        $integerSize = [int]$size
        if ($size -eq $integerSize -and $presetLabels.ContainsKey($integerSize)) {
            $label = $presetLabels[$integerSize]
        }

        $verbKey = "$shellKey\$registryVerbPrefix{0:D2}" -f $verbIndex
        New-Item -Path $verbKey -Force | Out-Null
        New-ItemProperty -Path $verbKey -Name '(default)' -Value $label -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $verbKey -Name 'Icon' -Value "$env:SystemRoot\System32\shell32.dll,115" -PropertyType String -Force | Out-Null

        $commandKey = "$verbKey\command"
        New-Item -Path $commandKey -Force | Out-Null
        $command = "`"$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe`" -NoProfile -ExecutionPolicy Bypass -File `"$installedScript`" -TargetMB $size -Pause -Path `"%1`""
        New-ItemProperty -Path $commandKey -Name '(default)' -Value $command -PropertyType String -Force | Out-Null
    }

    if (-not $NoCustomSize) {
        $verbIndex++
        $verbKey = "$shellKey\$registryVerbPrefix{0:D2}" -f $verbIndex
        New-Item -Path $verbKey -Force | Out-Null
        New-ItemProperty -Path $verbKey -Name '(default)' -Value 'Compress to custom size...' -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $verbKey -Name 'Icon' -Value "$env:SystemRoot\System32\shell32.dll,115" -PropertyType String -Force | Out-Null

        $commandKey = "$verbKey\command"
        New-Item -Path $commandKey -Force | Out-Null
        $command = "`"$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe`" -NoProfile -ExecutionPolicy Bypass -File `"$installedScript`" -PromptForTarget -Pause -Path `"%1`""
        New-ItemProperty -Path $commandKey -Name '(default)' -Value $command -PropertyType String -Force | Out-Null
    }
}

$uninstallRegistryKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\DiscordVideoCompressor'
New-Item -Path $uninstallRegistryKey -Force | Out-Null
New-ItemProperty -Path $uninstallRegistryKey -Name 'DisplayName' -Value $applicationName -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallRegistryKey -Name 'DisplayVersion' -Value $applicationVersion -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallRegistryKey -Name 'Publisher' -Value 'lanmac03' -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallRegistryKey -Name 'InstallLocation' -Value $InstallDirectory -PropertyType String -Force | Out-Null
$uninstallCommand = '"{0}"' -f (Join-Path $InstallDirectory 'Uninstall.cmd')
New-ItemProperty -Path $uninstallRegistryKey -Name 'UninstallString' -Value $uninstallCommand -PropertyType String -Force | Out-Null
New-ItemProperty -Path $uninstallRegistryKey -Name 'NoModify' -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $uninstallRegistryKey -Name 'NoRepair' -Value 1 -PropertyType DWord -Force | Out-Null

$entryCount = $Sizes.Count + $(if ($NoCustomSize) { 0 } else { 1 })
Write-Host "  Menu:   $entryCount entries on $($extensions.Count) video types" -ForegroundColor Green

if (-not $NoExplorerRestart) {
    Write-Host '  Explorer: restarting to refresh the context menu...' -ForegroundColor Cyan
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
        Start-Process explorer.exe
    }
}

Write-Host ''
Write-Host ' Installation complete.' -ForegroundColor White
Write-Host ' Right-click a video and choose Show more options.' -ForegroundColor White
Write-Host ''
