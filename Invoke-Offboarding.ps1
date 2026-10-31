#Requires -Version 5.1
<#
.SYNOPSIS
    Offboards leavers: disables the account, keeps the mailbox as shared, strips access and logs everything.

.DESCRIPTION
    For each leaver, in this order:
      1. Save a JSON snapshot of the account and its groups (for audit or restore).
      2. Reset the password, disable the account, stamp the description, hide from the GAL.
      3. Revoke all Entra ID sign-in sessions (cuts access now instead of at the next sync).
      4. Convert the mailbox to shared, grant the manager (or delegate) Full Access, set an auto-reply.
      5. Remove all group memberships except protected groups.
      6. Remove directly assigned licences (skipped if the mailbox is over the size limit or on hold).
      7. Archive the home folder (if configured).
      8. Move the account to the Disabled Users OU.

    Steps 5 and 6 only run once the mailbox is safely shared. Removing a licence (directly, or by
    removing the licence group) from a user mailbox starts its deletion countdown, so if
    conversion fails those steps are skipped and the leaver is reported as Partial.

    Leavers with a LeaveDate in the future are not offboarded yet. Their account is set to expire
    at the end of that day (so access stops on time even if nobody runs the script) and they are
    reported as Scheduled. Run the same CSV daily, e.g. from Task Scheduler, and each leaver is
    fully offboarded on the first run on or after their leave date.

    Run with -WhatIf first to preview every change.

.PARAMETER CsvPath
    CSV of leavers. Required columns: Identity (sAMAccountName or UPN), Ticket.
    Optional columns: LeaveDate (yyyy-MM-dd), Delegate (who gets mailbox access instead of the
    manager), AutoReplyMessage.

.PARAMETER Identity
    Offboard a single user (sAMAccountName or UPN) instead of a CSV.

.PARAMETER Ticket
    Change or incident reference, stamped on the account description and in the log.

.PARAMETER LeaveDate
    Single-user mode: last working day. If it's in the future the leaver is scheduled, not offboarded.

.PARAMETER Delegate
    Single-user mode: who gets Full Access to the shared mailbox. Defaults to the manager.

.PARAMETER AutoReplyMessage
    Single-user mode: overrides the auto-reply template from the config.

.PARAMETER ConfigPath
    Toolkit config file. Defaults to config\toolkit.config.psd1 next to this script.

.PARAMETER SkipCloud
    Only do the on-prem AD and file server steps. Group stripping is also skipped, because a
    licence group may be among them and the mailbox has not been converted.

.PARAMETER PassThru
    Output the per-leaver result objects. The script then returns normally and sets
    $LASTEXITCODE instead of calling exit.

.EXAMPLE
    .\Invoke-Offboarding.ps1 -Identity tom.baker -Ticket INC0042117 -WhatIf

.EXAMPLE
    .\Invoke-Offboarding.ps1 -CsvPath .\samples\leavers.csv

.EXAMPLE
    .\Invoke-Offboarding.ps1 -Identity priya.patel -Ticket CHG0012001 -LeaveDate 2026-12-18

    Sets the account to expire at the end of 18 December. Re-run on or after that date to offboard.

.NOTES
    Exit codes: 0 = all succeeded or scheduled, 1 = at least one leaver failed or partly failed,
    2 = the config or CSV could not be loaded.
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Csv')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Csv')][string]$CsvPath,
    [Parameter(Mandatory, ParameterSetName = 'Single')][string]$Identity,
    [Parameter(Mandatory, ParameterSetName = 'Single')][string]$Ticket,
    [Parameter(ParameterSetName = 'Single')][datetime]$LeaveDate,
    [Parameter(ParameterSetName = 'Single')][string]$Delegate,
    [Parameter(ParameterSetName = 'Single')][string]$AutoReplyMessage,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config\toolkit.config.psd1'),
    [switch]$SkipCloud,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src\LifecycleToolkit\LifecycleToolkit.psd1') -Force

$sp = @{}
foreach ($name in 'WhatIf', 'Confirm') {
    if ($PSBoundParameters.ContainsKey($name)) { $sp[$name] = $PSBoundParameters[$name] }
}
$isPreview = [bool]$WhatIfPreference

try {
    $config = Import-LtConfig -Path $ConfigPath -RootPath $PSScriptRoot
    $logFile = Initialize-LtLog -Directory $config.Logging.Path -Operation 'Offboarding' -RetentionDays $config.Logging.RetentionDays
    Write-LtLog ("Offboarding run {0} started by {1}\{2} on {3}{4}" -f (Get-LtLogState).RunId, [Environment]::UserDomainName, [Environment]::UserName, [Environment]::MachineName, $(if ($isPreview) { ' [WHATIF - no changes will be made]' }))
    Write-LtLog "Config: $ConfigPath | Log: $logFile"

    Assert-LtCommand -Name 'Get-ADUser', 'Disable-ADAccount', 'Remove-ADGroupMember' -Module 'ActiveDirectory' `
        -InstallHint 'Install RSAT: Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0'

    if ($PSCmdlet.ParameterSetName -eq 'Single') {
        $rows = @([pscustomobject]@{
                Identity         = $Identity
                Ticket           = $Ticket
                LeaveDate        = $(if ($PSBoundParameters.ContainsKey('LeaveDate')) { $LeaveDate.ToString('yyyy-MM-dd') })
                Delegate         = $Delegate
                AutoReplyMessage = $AutoReplyMessage
            })
    }
    else {
        $rows = @(Import-LtCsv -Path $CsvPath -RequiredColumns 'Identity', 'Ticket')
        Write-LtLog "Loaded $($rows.Count) leaver(s) from $CsvPath"
    }

    $ad = $config.ActiveDirectory
    $m365 = $config.M365
    $off = $config.Offboarding
    $useCloud = $m365.Enabled -and -not $SkipCloud
    if ($useCloud) { Connect-LtCloud -M365Config $m365 -Graph -Exchange }
}
catch {
    if ((Get-LtLogState).File) { Write-LtLog "Setup failed: $($_.Exception.Message)" -Level ERROR }
    else { Write-Error "Setup failed: $($_.Exception.Message)" -ErrorAction Continue }
    exit 2
}

$results = New-Object System.Collections.Generic.List[object]
$rowNumber = if ($PSCmdlet.ParameterSetName -eq 'Single') { 0 } else { 1 }

foreach ($row in $rows) {
    $rowNumber++
    $id = Get-LtCsvValue $row 'Identity'
    $ticketRef = Get-LtCsvValue $row 'Ticket'
    $result = New-LtResult -Name $(if ($id) { $id } else { "(row $rowNumber)" }) -Row $rowNumber
    $results.Add($result)
    $disabled = $false

    try {
        if (-not $id) { throw 'Identity is empty' }
        if (-not $ticketRef) { throw 'Ticket is empty; every leaver needs a change/incident reference' }
        $leaveText = Get-LtCsvValue $row 'LeaveDate'
        $leaveDay = $null
        if ($leaveText) {
            $parsed = [datetime]::MinValue
            if (-not [datetime]::TryParseExact($leaveText, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) {
                throw "LeaveDate '$leaveText' is not a valid date in yyyy-MM-dd format"
            }
            $leaveDay = $parsed
        }

        $user = Find-LtADUser -Identity $id -Server $ad.Server
        if (-not $user) { throw "No AD user found with sAMAccountName/UPN '$id'" }
        $sam = $user.SamAccountName
        $result.SamAccountName = $sam
        $result.UserPrincipalName = $user.UserPrincipalName

        if ($leaveDay -and $leaveDay.Date -gt (Get-Date).Date) {
            Write-LtLog "Leave date $($leaveDay.ToString('yyyy-MM-dd')) is in the future; scheduling only" -Subject $sam
            Set-LtAccountExpiration @sp -User $user -LeaveDate $leaveDay -Server $ad.Server
            Add-LtResultMessage $result Action "Account set to expire at end of $($leaveDay.ToString('yyyy-MM-dd')); full offboarding on or after that date" -Preview:$isPreview
            $result.Status = 'Scheduled'
            continue
        }
        Write-LtLog "Offboarding $($user.DisplayName) <$($user.UserPrincipalName)> ticket $ticketRef" -Subject $sam

        $manager = if ($user.Manager) { Find-LtADUser -Identity $user.Manager -Server $ad.Server } else { $null }
        $cloudUser = $null
        $mailbox = $null
        if ($useCloud) {
            $cloudUser = Get-LtCloudUser -UserPrincipalName $user.UserPrincipalName
            if (-not $cloudUser) { Add-LtResultMessage $result Warning 'No matching Entra ID user (not synced?); cloud steps skipped' }
            $mailbox = Get-LtMailboxInfo -UserPrincipalName $user.UserPrincipalName
            if ($mailbox) {
                Write-LtLog ("Mailbox: {0}, {1} GB, litigation hold {2}" -f $mailbox.RecipientTypeDetails, $mailbox.SizeGB, $mailbox.LitigationHoldEnabled) -Subject $sam
            }
            else { Add-LtResultMessage $result Warning 'No Exchange Online mailbox found' }
        }

        $snapshot = Save-LtUserSnapshot @sp -User $user -Directory $off.SnapshotPath -Ticket $ticketRef -CloudUser $cloudUser -MailboxInfo $mailbox
        Add-LtResultMessage $result Action "Snapshot $snapshot" -Preview:$isPreview

        $description = 'Leaver {0} - {1} - by {2}' -f (Get-Date -Format 'yyyy-MM-dd'), $ticketRef, [Environment]::UserName
        Disable-LtADUser @sp -User $user -Description $description -HideFromGal:([bool]$ad.HideFromGalOnLeave) -Server $ad.Server
        $disabled = $true
        Add-LtResultMessage $result Action 'Password reset, account disabled, description set' -Preview:$isPreview

        if ($cloudUser -and $off.RevokeSessions) {
            Revoke-LtSignInSession @sp -CloudUser $cloudUser
            Add-LtResultMessage $result Action 'Sign-in sessions revoked' -Preview:$isPreview
        }

        $mailboxSafe = -not $mailbox -or -not $off.ConvertMailboxToShared
        if ($mailbox -and $off.ConvertMailboxToShared) {
            $delegateName = Get-LtCsvValue $row 'Delegate'
            if (-not $delegateName -and $off.GrantManagerMailboxAccess -and $manager) { $delegateName = $manager.UserPrincipalName }
            if (-not $delegateName -and $off.GrantManagerMailboxAccess) { Add-LtResultMessage $result Warning 'No manager or delegate; nobody granted mailbox access' }

            $reply = $null
            if ($off.SetAutoReply) {
                $reply = Get-LtCsvValue $row 'AutoReplyMessage'
                if (-not $reply) {
                    $reply = Expand-LtTemplate $off.AutoReplyMessage @{
                        DisplayName  = $user.DisplayName
                        Organisation = $config.Organisation.Name
                        ManagerName  = $(if ($manager) { $manager.DisplayName } else { 'the service desk' })
                        ManagerEmail = $(if ($manager -and $manager.mail) { $manager.mail } else { "servicedesk@$($config.Organisation.UpnSuffix)" })
                    }
                }
            }
            try {
                Convert-LtMailboxToShared @sp -MailboxInfo $mailbox -Delegate $delegateName -AutoReplyMessage $reply
                $mailboxSafe = $true
                Add-LtResultMessage $result Action ('Converted mailbox to shared' + $(if ($delegateName) { ", Full Access for $delegateName" })) -Preview:$isPreview
            }
            catch {
                Add-LtResultMessage $result Error "Mailbox conversion failed: $($_.Exception.Message). Groups and licences left in place to protect the mailbox; fix and re-run."
            }
        }

        if ($SkipCloud -and $m365.Enabled) {
            Add-LtResultMessage $result Warning 'Groups not removed: -SkipCloud means the mailbox was not converted, and a licence group may be among them'
        }
        elseif ($mailboxSafe) {
            $groupOutcome = Remove-LtGroupMembership @sp -User $user -ProtectedGroup $config.Groups.ProtectedOnLeave -Server $ad.Server
            if ($groupOutcome.Removed.Count) {
                Add-LtResultMessage $result Action "Removed from $($groupOutcome.Removed.Count) group(s): $($groupOutcome.Removed -join ', ')" -Preview:$isPreview
            }
            foreach ($g in $groupOutcome.Failed) { Add-LtResultMessage $result Error "Could not remove from group '$g'" -NoLog }
        }

        if ($cloudUser -and $off.RemoveLicenses -and $mailboxSafe) {
            $limitBytes = [long]$off.SharedMailboxSizeLimitGB * 1GB
            if ($mailbox -and ($mailbox.SizeBytes -ge $limitBytes -or $mailbox.LitigationHoldEnabled -or $mailbox.HasInPlaceHold)) {
                Add-LtResultMessage $result Warning ("Licences kept: shared mailbox is {0} GB / on hold - it still needs a licence" -f $mailbox.SizeGB)
            }
            else {
                $removedSkus = Remove-LtM365License @sp -CloudUser $cloudUser
                if ($removedSkus) { Add-LtResultMessage $result Action "Direct licences removed: $(@($removedSkus).Count)" -Preview:$isPreview }
            }
        }

        if ($config.HomeFolder.Enabled -and $config.HomeFolder.LeaverAction -eq 'Archive' -and $user.HomeDirectory) {
            try {
                Move-LtHomeFolder @sp -Path $user.HomeDirectory -ArchiveRoot $config.HomeFolder.ArchivePath -Subject $sam
                Add-LtResultMessage $result Action "Home folder archived to $($config.HomeFolder.ArchivePath)" -Preview:$isPreview
            }
            catch { Add-LtResultMessage $result Error "Home folder archive: $($_.Exception.Message)" }
        }

        Move-LtADUserToOU @sp -User $user -TargetOU $ad.DisabledUsersOU -Server $ad.Server
        Add-LtResultMessage $result Action "Moved to $($ad.DisabledUsersOU)" -Preview:$isPreview
    }
    catch {
        Add-LtResultMessage $result Error $_.Exception.Message
        $result.Status = if ($disabled) { 'Partial' } else { 'Failed' }
    }
}

if ($useCloud -and $m365.DirSync.Enabled -and $m365.DirSync.Server -and ($results | Where-Object { $_.Status -notin 'Failed', 'Scheduled' })) {
    Start-LtDirectorySync @sp -Server $m365.DirSync.Server
}

foreach ($r in $results) {
    if ($r.Status -ne 'Pending') { continue }
    $r.Status = if ($r.Errors.Count) { if ($isPreview) { 'Failed' } else { 'Partial' } } elseif ($isPreview) { 'WhatIf' } else { 'Success' }
}

$reportPath = Export-LtReport -Results $results -Directory $config.Logging.ReportPath -Operation 'Offboarding'
$byStatus = $results | Group-Object Status | ForEach-Object { "$($_.Name)=$($_.Count)" }
Write-LtLog ("Finished. {0} leaver(s): {1}" -f $results.Count, ($byStatus -join ', ')) -Level $(if ($results.Status -match 'Failed|Partial') { 'WARN' } else { 'SUCCESS' })
Write-LtLog "Report: $reportPath"
Write-LtLog "Log:    $logFile"

$exitCode = if ($results.Status -match 'Failed|Partial') { 1 } else { 0 }
if ($PassThru) {
    $global:LASTEXITCODE = $exitCode
    return $results
}
exit $exitCode
