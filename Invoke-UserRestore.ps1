#Requires -Version 5.1
<#
.SYNOPSIS
    Restores an offboarded user from their offboarding snapshot (e.g. a leaver who comes back, or a mistake).

.DESCRIPTION
    Uses the JSON snapshot written by Invoke-Offboarding.ps1 to put the account back as it was:
      1. Move the account back to its original OU.
      2. Restore its group memberships (including any licence group).
      3. Restore the description and GAL visibility, and clear any account expiry.
      4. Set a new random password (must change at next logon) and enable the account.
      5. Restore direct licences, then convert the shared mailbox back to a user mailbox and
         turn off the auto-reply.

    The new password is shown once on screen and never written to the log or report.
    Mailbox delegates added at offboarding keep their access; remove them by hand if needed.
    Archived home folders are not moved back.

.PARAMETER Identity
    sAMAccountName of the user. The earliest snapshot for them in Offboarding.SnapshotPath is
    used, because that is the one taken before the first offboarding run.

.PARAMETER SnapshotPath
    Use a specific snapshot file instead.

.PARAMETER Ticket
    Change or incident reference, recorded in the log.

.PARAMETER ConfigPath
    Toolkit config file. Defaults to config\toolkit.config.psd1 next to this script.

.PARAMETER SkipCloud
    Only restore the on-prem AD account. Licences and the mailbox are left as they are.

.PARAMETER PassThru
    Output the result object (InitialPassword is a SecureString). The script then returns
    normally and sets $LASTEXITCODE instead of calling exit.

.EXAMPLE
    .\Invoke-UserRestore.ps1 -Identity tom.baker -Ticket INC0042200 -WhatIf

.EXAMPLE
    .\Invoke-UserRestore.ps1 -SnapshotPath .\output\snapshots\tom.baker_20261103-083002.json -Ticket INC0042200

.NOTES
    Exit codes: 0 = restored, 1 = failed or partly restored, 2 = the config or snapshot could not be loaded.
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Identity')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Identity')][string]$Identity,
    [Parameter(Mandatory, ParameterSetName = 'Path')][string]$SnapshotPath,
    [Parameter(Mandatory)][string]$Ticket,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config\toolkit.config.psd1'),
    [switch]$SkipCloud,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src\LifecycleToolkit\LifecycleToolkit.psd1') -Force

# Preference variables don't flow into script-module functions, so forward -WhatIf/-Confirm explicitly.
$sp = @{}
foreach ($name in 'WhatIf', 'Confirm') {
    if ($PSBoundParameters.ContainsKey($name)) { $sp[$name] = $PSBoundParameters[$name] }
}
$isPreview = [bool]$WhatIfPreference

# ---- Setup -----------------------------------------------------------------------------------
try {
    $config = Import-LtConfig -Path $ConfigPath -RootPath $PSScriptRoot
    $logFile = Initialize-LtLog -Directory $config.Logging.Path -Operation 'Restore' -RetentionDays $config.Logging.RetentionDays
    Write-LtLog ("Restore run {0} started by {1}\{2} on {3}{4}" -f (Get-LtLogState).RunId, [Environment]::UserDomainName, [Environment]::UserName, [Environment]::MachineName, $(if ($isPreview) { ' [WHATIF - no changes will be made]' }))
    Write-LtLog "Config: $ConfigPath | Ticket: $Ticket | Log: $logFile"

    Assert-LtCommand -Name 'Get-ADUser', 'Enable-ADAccount', 'Add-ADGroupMember' -Module 'ActiveDirectory' `
        -InstallHint 'Install RSAT: Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0'

    $snapshot = if ($PSCmdlet.ParameterSetName -eq 'Path') {
        Get-LtUserSnapshot -Path $SnapshotPath
    }
    else {
        Get-LtUserSnapshot -Directory $config.Offboarding.SnapshotPath -SamAccountName $Identity
    }
    Write-LtLog "Using snapshot $($snapshot.SourcePath) (taken $($snapshot.TakenAt) for ticket $($snapshot.Ticket))"

    $ad = $config.ActiveDirectory
    $m365 = $config.M365
    $useCloud = $m365.Enabled -and -not $SkipCloud
    if ($useCloud) { Connect-LtCloud -M365Config $m365 -Graph -Exchange }
}
catch {
    if ((Get-LtLogState).File) { Write-LtLog "Setup failed: $($_.Exception.Message)" -Level ERROR }
    else { Write-Error "Setup failed: $($_.Exception.Message)" -ErrorAction Continue }
    exit 2
}

# ---- Restore ---------------------------------------------------------------------------------
$result = New-LtResult -Name $snapshot.SamAccountName -Row 1
$enabled = $false
try {
    # Look up by GUID: the account was moved (new DN) and could have been renamed since.
    $user = Find-LtADUser -Identity $snapshot.ObjectGUID -Server $ad.Server
    if (-not $user) { throw "The account in the snapshot (GUID $($snapshot.ObjectGUID)) no longer exists in AD" }
    $sam = $user.SamAccountName
    $result.SamAccountName = $sam
    $result.UserPrincipalName = $user.UserPrincipalName
    Write-LtLog "Restoring $($user.DisplayName) <$($user.UserPrincipalName)>" -Subject $sam

    # 1. Original OU ---------------------------------------------------------------------------
    $originalOU = ($snapshot.DistinguishedName -split '(?<!\\),', 2)[1]
    Move-LtADUserToOU @sp -User $user -TargetOU $originalOU -Server $ad.Server
    Add-LtResultMessage $result Action "Moved back to $originalOU" -Preview:$isPreview

    # 2. Groups --------------------------------------------------------------------------------
    $groups = @($snapshot.MemberOf | Where-Object { $_ })
    $groupOutcome = Add-LtGroupMembership @sp -SamAccountName $sam -Group $groups -User $user -Server $ad.Server
    if ($groupOutcome.Added.Count) {
        Add-LtResultMessage $result Action "Added back to $($groupOutcome.Added.Count) group(s)" -Preview:$isPreview
    }
    foreach ($g in $groupOutcome.Failed) { Add-LtResultMessage $result Error "Group '$g' could not be restored (deleted since?)" -NoLog }

    # 3 + 4. Attributes, password, enable -----------------------------------------------------
    $result.InitialPassword = New-LtPassword -Length $ad.PasswordLength
    Enable-LtADUser @sp -User $user -Password $result.InitialPassword -Description $snapshot.Description `
        -HiddenFromGal ([bool]$snapshot.HiddenFromGal) -Server $ad.Server
    $enabled = -not $isPreview
    Add-LtResultMessage $result Action 'Description restored, new password set, account enabled' -Preview:$isPreview

    # 5. Cloud ---------------------------------------------------------------------------------
    if ($useCloud) {
        $cloudUser = Get-LtCloudUser -UserPrincipalName $user.UserPrincipalName
        if (-not $cloudUser) {
            Add-LtResultMessage $result Warning 'No matching Entra ID user; licences and mailbox not restored'
        }
        else {
            $skus = @($snapshot.DirectLicenseSkuIds | Where-Object { $_ })
            if ($skus) {
                Add-LtM365License @sp -CloudUser $cloudUser -SkuId $skus
                Add-LtResultMessage $result Action "Direct licences restored: $($skus.Count)" -Preview:$isPreview
            }
            $mailbox = Get-LtMailboxInfo -UserPrincipalName $user.UserPrincipalName
            if ($mailbox -and $snapshot.MailboxType -ne 'SharedMailbox') {
                Convert-LtMailboxToRegular @sp -MailboxInfo $mailbox
                Add-LtResultMessage $result Action 'Mailbox converted back to a user mailbox, auto-reply off' -Preview:$isPreview
            }
            elseif (-not $mailbox) {
                Add-LtResultMessage $result Warning 'No Exchange Online mailbox found'
            }
            if (-not $skus -and -not $groupOutcome.Added.Count) {
                Add-LtResultMessage $result Warning 'No licence restored by this run; check the user is licensed within 30 days or the mailbox is disconnected'
            }
        }
        if ($m365.DirSync.Enabled -and $m365.DirSync.Server) {
            Start-LtDirectorySync @sp -Server $m365.DirSync.Server
        }
    }
}
catch {
    Add-LtResultMessage $result Error $_.Exception.Message
    $result.Status = if ($enabled) { 'Partial' } else { 'Failed' }
}

if ($result.Status -eq 'Pending') {
    $result.Status = if ($result.Errors.Count) { if ($isPreview) { 'Failed' } else { 'Partial' } } elseif ($isPreview) { 'WhatIf' } else { 'Success' }
}

# ---- Report and summary ----------------------------------------------------------------------
$reportPath = Export-LtReport -Results @($result) -Directory $config.Logging.ReportPath -Operation 'Restore'
Write-LtLog "Finished. $($result.SamAccountName): $($result.Status)" -Level $(if ($result.Status -match 'Failed|Partial') { 'WARN' } else { 'SUCCESS' })
Write-LtLog "Report: $reportPath"
Write-LtLog "Log:    $logFile"

if ($result.Status -in 'Success', 'Partial' -and $result.InitialPassword) {
    # Deliberately shown on screen only: not logged, not in the report.
    Write-Host ''
    Write-Host 'New password (shown once; user must change at first logon). Hand over securely:' -ForegroundColor Yellow
    Write-Host ("  {0}  {1}" -f $result.SamAccountName, (ConvertFrom-LtSecureString $result.InitialPassword))
    Write-Host ''
}

$exitCode = if ($result.Status -match 'Failed|Partial') { 1 } else { 0 }
if ($PassThru) {
    # 'exit' would cut off a downstream pipeline (| Format-List), so return normally instead.
    $global:LASTEXITCODE = $exitCode
    return $result
}
exit $exitCode
