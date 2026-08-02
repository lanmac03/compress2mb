<#
.SYNOPSIS
    Removes Compress2MB for the current Windows user.
#>
[CmdletBinding()]
param(
    [switch] $KeepFiles,
    [switch] $NoExplorerRestart,
    [string] $InstallDirectory = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'

$extensions = @(
    '.mp4', '.mkv', '.mov', '.avi', '.webm', '.m4v', '.wmv', '.flv',
    '.mpg', '.mpeg', '.ts', '.m2ts', '.mts', '.3gp', '.ogv'
)

Write-Host ''
Write-Host ' Uninstalling Compress2MB' -ForegroundColor White
Write-Host ' =========================' -ForegroundColor DarkGray

foreach ($extension in $extensions) {
    $shellKey = "HKCU:\Software\Classes\SystemFileAssociations\$extension\shell"
    Get-ChildItem -Path $shellKey -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -like 'Compress2MB*' } |
        Remove-Item -Recurse -Force
}

$uninstallRegistryKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Compress2MB'
if (Test-Path $uninstallRegistryKey) {
    Remove-Item $uninstallRegistryKey -Recurse -Force
}
Write-Host '  Context menu: removed' -ForegroundColor Green

if (-not $KeepFiles -and (Test-Path -LiteralPath $InstallDirectory)) {
    $resolvedInstallDirectory = [IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\')
    $resolvedLocalAppData = [IO.Path]::GetFullPath($env:LOCALAPPDATA).TrimEnd('\')
    if (-not $resolvedInstallDirectory.StartsWith("$resolvedLocalAppData\", [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove files outside LocalAppData: $resolvedInstallDirectory"
    }

    Remove-Item -LiteralPath $resolvedInstallDirectory -Recurse -Force
    Write-Host "  Files: removed $resolvedInstallDirectory" -ForegroundColor Green
}

if (-not $NoExplorerRestart) {
    Write-Host '  Explorer: restarting to refresh the context menu...' -ForegroundColor Cyan
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
        Start-Process explorer.exe
    }
}

Write-Host ''
Write-Host ' Uninstall complete.' -ForegroundColor White
Write-Host ''
