<#
.SYNOPSIS
    Diagnostic: registers three throwaway context-menu entries via three
    different mechanisms, so we can see which one Explorer actually honours.
    Run with -Remove to clean them all up.
#>
param([switch] $Remove)

$ErrorActionPreference = 'Stop'

$probes = @(
    @{ Key = 'HKCU:\Software\Classes\SystemFileAssociations\video\shell\ZZProbeA'; Label = 'PROBE A - perceived type (video)' },
    @{ Key = 'HKCU:\Software\Classes\SystemFileAssociations\.mp4\shell\ZZProbeB';  Label = 'PROBE B - per extension (.mp4)' },
    @{ Key = 'HKCU:\Software\Classes\*\shell\ZZProbeC';                            Label = 'PROBE C - all files (*)' }
)

foreach ($p in $probes) {
    if (Test-Path $p.Key) { Remove-Item $p.Key -Recurse -Force }
    if ($Remove) { continue }

    New-Item -Path $p.Key -Force | Out-Null
    New-ItemProperty -Path $p.Key -Name '(default)' -Value $p.Label -PropertyType String -Force | Out-Null

    $cmdKey = Join-Path $p.Key 'command'
    New-Item -Path $cmdKey -Force | Out-Null
    New-ItemProperty -Path $cmdKey -Name '(default)' `
        -Value "cmd.exe /c echo $($p.Label) && pause" -PropertyType String -Force | Out-Null
}

if ($Remove) {
    Write-Host "  Probes removed." -ForegroundColor Green
} else {
    Write-Host "  3 probes registered. Right-click an .mp4 and note which appear." -ForegroundColor Cyan
}
