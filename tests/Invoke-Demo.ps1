<#
.SYNOPSIS
    Runs the toolkit end to end against an in-memory fake AD and M365 tenant. No domain needed.

.DESCRIPTION
    Logs, reports, snapshots and home folders are written to a temp folder.

.EXAMPLE
    ./tests/Invoke-Demo.ps1
#>
[CmdletBinding()]
param(
    [ValidateSet('Group', 'Direct')][string]$LicenseMode = 'Group'
)

$repoRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'Fakes/FakeEnvironment.ps1')
Initialize-FakeDirectory

$workDir = Join-Path ([System.IO.Path]::GetTempPath()) ("lifecycle-demo-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
[void][System.IO.Directory]::CreateDirectory($workDir)
$config = New-FakeConfig -Directory $workDir -LicenseMode $LicenseMode

function Show-Step([string]$Title) {
    Write-Host ''
    Write-Host ('=' * 100) -ForegroundColor DarkGray
    Write-Host "  $Title" -ForegroundColor White
    Write-Host ('=' * 100) -ForegroundColor DarkGray
}

Show-Step '1. Onboarding preview (-WhatIf)'
& (Join-Path $repoRoot 'Invoke-Onboarding.ps1') -CsvPath (Join-Path $repoRoot 'samples/new-starters.csv') -ConfigPath $config -WhatIf
Write-Host "Changes made: $($FakeEnv.Changes.Count)" -ForegroundColor Magenta

Show-Step '2. Onboarding for real'
& (Join-Path $repoRoot 'Invoke-Onboarding.ps1') -CsvPath (Join-Path $repoRoot 'samples/new-starters.csv') -ConfigPath $config

Show-Step '3. Re-running the same CSV (idempotent: nothing to do)'
$FakeEnv.Changes.Clear()
& (Join-Path $repoRoot 'Invoke-Onboarding.ps1') -CsvPath (Join-Path $repoRoot 'samples/new-starters.csv') -ConfigPath $config
Write-Host "Changes made: $($FakeEnv.Changes.Count)" -ForegroundColor Magenta

Show-Step '4. Offboarding preview (-WhatIf)'
& (Join-Path $repoRoot 'Invoke-Offboarding.ps1') -CsvPath (Join-Path $repoRoot 'samples/leavers.csv') -ConfigPath $config -WhatIf

Show-Step '5. Offboarding for real (priya.patel has a future leave date, so is only scheduled)'
$FakeEnv.Changes.Clear()
& (Join-Path $repoRoot 'Invoke-Offboarding.ps1') -CsvPath (Join-Path $repoRoot 'samples/leavers.csv') -ConfigPath $config
Write-Host ''
Write-Host 'Order of changes made by offboarding:' -ForegroundColor Magenta
$FakeEnv.Changes | ForEach-Object { Write-Host "  $_" }

Show-Step '6. Restoring a leaver from their snapshot (e.g. they come back)'
& (Join-Path $repoRoot 'Invoke-UserRestore.ps1') -Identity 'tom.baker' -Ticket 'INC0042200' -ConfigPath $config

Show-Step 'Output files'
Get-ChildItem $workDir -Recurse -File -Include *.log, *.csv, *.json | ForEach-Object { Write-Host "  $($_.FullName)" }
