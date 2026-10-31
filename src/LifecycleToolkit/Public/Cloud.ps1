[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'ShouldProcess is called via Invoke-LtChange -Cmdlet $PSCmdlet.')]
param()

$script:LtSkuCache = $null

function Connect-LtCloud {
    <#
    .SYNOPSIS
        Connects to Microsoft Graph and/or Exchange Online, unless already connected.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$M365Config,
        [switch]$Graph,
        [switch]$Exchange
    )
    $appOnly = $M365Config.ClientId -and $M365Config.CertificateThumbprint

    if ($Graph) {
        Assert-LtCommand -Name 'Connect-MgGraph', 'Get-MgUser', 'Set-MgUserLicense' -Module 'Microsoft.Graph' `
            -InstallHint 'Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Users, Microsoft.Graph.Users.Actions, Microsoft.Graph.Identity.DirectoryManagement'
        $context = Get-MgContext
        if ($context -and $context.TenantId -eq $M365Config.TenantId) {
            Write-LtLog "Already connected to Microsoft Graph as $($context.Account)$($context.AppName)"
        }
        else {
            $params = @{ TenantId = $M365Config.TenantId; NoWelcome = $true }
            if ($appOnly) {
                $params.ClientId = $M365Config.ClientId
                $params.CertificateThumbprint = $M365Config.CertificateThumbprint
            }
            else {
                $params.Scopes = @('User.ReadWrite.All', 'Organization.Read.All', 'User.RevokeSessions.All')
            }
            Connect-MgGraph @params | Out-Null
            Write-LtLog "Connected to Microsoft Graph (tenant $($M365Config.TenantId), $(if ($appOnly) { 'app-only' } else { 'delegated' }))"
        }
    }

    if ($Exchange) {
        Assert-LtCommand -Name 'Connect-ExchangeOnline', 'Get-EXOMailbox', 'Set-Mailbox' -Module 'ExchangeOnlineManagement' `
            -InstallHint 'Install-Module ExchangeOnlineManagement'
        $existing = Get-ConnectionInformation | Where-Object { $_.State -eq 'Connected' } | Select-Object -First 1
        if ($existing) {
            Write-LtLog "Already connected to Exchange Online ($($existing.Organization))"
        }
        else {
            $params = @{ ShowBanner = $false }
            if ($appOnly) {
                $params.AppId = $M365Config.ClientId
                $params.CertificateThumbprint = $M365Config.CertificateThumbprint
                $params.Organization = $M365Config.Organization
            }
            Connect-ExchangeOnline @params
            Write-LtLog "Connected to Exchange Online ($($M365Config.Organization))"
        }
    }
}

function Start-LtDirectorySync {
    <#
    .SYNOPSIS
        Triggers an Entra Connect delta sync on the sync server so changes reach the cloud sooner.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Server)

    try {
        Invoke-LtChange -Cmdlet $PSCmdlet -Target $Server -Action 'Start Entra Connect delta sync' -ScriptBlock {
            Invoke-Command -ComputerName $Server -ErrorAction Stop -ScriptBlock {
                Import-Module ADSync
                Start-ADSyncSyncCycle -PolicyType Delta
            } | Out-Null
        }
    }
    catch {
        if ($_.Exception.Message -match 'busy|in progress') {
            Write-LtLog "A sync cycle is already running on $Server; changes will go out with it or the next one" -Level WARN
        }
        else {
            Write-LtLog "Could not trigger delta sync on ${Server}: $($_.Exception.Message). Changes will go out on the next scheduled cycle (30 min)." -Level WARN
        }
    }
}

function Get-LtCloudUser {
    <#
    .SYNOPSIS
        Returns the Entra ID user for a UPN, or $null if it hasn't synced yet.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$UserPrincipalName)
    $upn = $UserPrincipalName.Replace("'", "''")
    Get-MgUser -Filter "userPrincipalName eq '$upn'" -Property 'id,userPrincipalName,usageLocation,assignedLicenses,licenseAssignmentStates,accountEnabled' |
        Select-Object -First 1
}

function Wait-LtCloudUser {
    <#
    .SYNOPSIS
        Polls Entra ID until a newly created AD user has synced, or the timeout is reached.
    .OUTPUTS
        The Graph user, or $null on timeout.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$UserPrincipalName,
        [int]$TimeoutSeconds = 900,
        [int]$PollIntervalSeconds = 30
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $user = Get-LtCloudUser -UserPrincipalName $UserPrincipalName
        if ($user) { return $user }
        Write-LtLog "Waiting for $UserPrincipalName to sync to Entra ID (up to $TimeoutSeconds s)..." -Subject $UserPrincipalName
        Start-Sleep -Seconds $PollIntervalSeconds
    } while ((Get-Date) -lt $deadline)
    $null
}

function Resolve-LtLicenseSku {
    <#
    .SYNOPSIS
        Looks up a subscribed SKU by SkuPartNumber (e.g. SPE_E3) and checks there are free licences.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SkuPartNumber,
        [switch]$Refresh
    )
    if ($Refresh -or -not $script:LtSkuCache) {
        $script:LtSkuCache = @(Get-MgSubscribedSku -All)
    }
    $sku = $script:LtSkuCache | Where-Object { $_.SkuPartNumber -eq $SkuPartNumber } | Select-Object -First 1
    if (-not $sku) {
        $known = ($script:LtSkuCache.SkuPartNumber | Sort-Object) -join ', '
        throw "Licence SKU '$SkuPartNumber' is not subscribed in this tenant. Available: $known"
    }
    $free = [int]$sku.PrepaidUnits.Enabled - [int]$sku.ConsumedUnits
    [pscustomobject]@{
        SkuId         = $sku.SkuId
        SkuPartNumber = $sku.SkuPartNumber
        Available     = $free
    }
}

function Set-LtM365License {
    <#
    .SYNOPSIS
        Sets usageLocation (required before licensing) and directly assigns a licence SKU.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]$CloudUser,
        [Parameter(Mandatory)][string]$SkuPartNumber,
        [Parameter(Mandatory)][ValidatePattern('^[A-Z]{2}$')][string]$UsageLocation
    )
    $upn = $CloudUser.UserPrincipalName

    if ($CloudUser.UsageLocation -ne $UsageLocation) {
        Invoke-LtChange -Cmdlet $PSCmdlet -Subject $upn -Target $upn -Action "Set usage location $UsageLocation" -ScriptBlock {
            Update-MgUser -UserId $CloudUser.Id -UsageLocation $UsageLocation
        }
    }

    $sku = Resolve-LtLicenseSku -SkuPartNumber $SkuPartNumber
    if (@($CloudUser.AssignedLicenses.SkuId) -contains $sku.SkuId) {
        Write-LtLog "Licence $SkuPartNumber already assigned" -Subject $upn
        return
    }
    if ($sku.Available -lt 1) {
        throw "No free $SkuPartNumber licences (0 available). Buy more or free one up, then re-run."
    }
    Invoke-LtChange -Cmdlet $PSCmdlet -Subject $upn -Target $upn -Action "Assign licence $SkuPartNumber" -ScriptBlock {
        Set-MgUserLicense -UserId $CloudUser.Id -AddLicenses @(@{ SkuId = $sku.SkuId }) -RemoveLicenses @() | Out-Null
    }
}

function Remove-LtM365License {
    <#
    .SYNOPSIS
        Removes directly assigned licences. Group-assigned ones go when the user leaves the group.
    .OUTPUTS
        The SKU IDs that were (or would be) removed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$CloudUser)

    $upn = $CloudUser.UserPrincipalName
    $direct = @($CloudUser.LicenseAssignmentStates |
            Where-Object { -not $_.AssignedByGroup } |
            Select-Object -ExpandProperty SkuId -Unique)
    if (-not $direct) {
        Write-LtLog 'No directly assigned licences to remove' -Subject $upn
        return
    }
    Invoke-LtChange -Cmdlet $PSCmdlet -Subject $upn -Target $upn -Action "Remove $($direct.Count) direct licence(s)" -ScriptBlock {
        Set-MgUserLicense -UserId $CloudUser.Id -AddLicenses @() -RemoveLicenses $direct | Out-Null
    }
    $direct
}

function Revoke-LtSignInSession {
    <#
    .SYNOPSIS
        Invalidates all refresh tokens so the leaver is signed out everywhere now, not at next sync.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$CloudUser)
    $upn = $CloudUser.UserPrincipalName
    Invoke-LtChange -Cmdlet $PSCmdlet -Subject $upn -Target $upn -Action 'Revoke all sign-in sessions' -ScriptBlock {
        Revoke-MgUserSignInSession -UserId $CloudUser.Id | Out-Null
    }
}

function ConvertFrom-LtSizeString {
    <#
    .SYNOPSIS
        Turns an EXO size string such as '1.2 GB (1,288,490,188 bytes)' into bytes.
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Size)
    if ($Size -match '\(([\d,\.\s]+) bytes\)') { return [long]($Matches[1] -replace '[^\d]', '') }
    0
}

function Get-LtMailboxInfo {
    <#
    .SYNOPSIS
        Returns mailbox type, size and hold state, or $null if the user has no EXO mailbox.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$UserPrincipalName)
    $mailbox = Get-EXOMailbox -Identity $UserPrincipalName -Properties RecipientTypeDetails, LitigationHoldEnabled, InPlaceHolds, ArchiveStatus -ErrorAction SilentlyContinue
    if (-not $mailbox) { return $null }
    $stats = Get-EXOMailboxStatistics -Identity $UserPrincipalName -ErrorAction SilentlyContinue
    $bytes = if ($stats) { ConvertFrom-LtSizeString ([string]$stats.TotalItemSize) } else { 0 }
    [pscustomobject]@{
        Identity              = $UserPrincipalName
        RecipientTypeDetails  = [string]$mailbox.RecipientTypeDetails
        SizeBytes             = $bytes
        SizeGB                = [math]::Round($bytes / 1GB, 2)
        LitigationHoldEnabled = [bool]$mailbox.LitigationHoldEnabled
        HasInPlaceHold        = [bool]@($mailbox.InPlaceHolds).Where({ $_ }).Count
        ArchiveEnabled        = [string]$mailbox.ArchiveStatus -eq 'Active'
    }
}

function Convert-LtMailboxToShared {
    <#
    .SYNOPSIS
        Converts a leaver's mailbox to shared, grants the delegate Full Access and sets an auto-reply.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]$MailboxInfo,
        [string]$Delegate,
        [string]$AutoReplyMessage
    )
    $id = $MailboxInfo.Identity

    if ($MailboxInfo.RecipientTypeDetails -eq 'SharedMailbox') {
        Write-LtLog 'Mailbox is already shared' -Subject $id
    }
    else {
        Invoke-LtChange -Cmdlet $PSCmdlet -Subject $id -Target $id -Action 'Convert mailbox to shared' -ScriptBlock {
            Set-Mailbox -Identity $id -Type Shared -Confirm:$false
        }
    }

    if ($Delegate) {
        $hasAccess = Get-EXOMailboxPermission -Identity $id -User $Delegate -ErrorAction SilentlyContinue |
            Where-Object { $_.AccessRights -contains 'FullAccess' }
        if ($hasAccess) {
            Write-LtLog "$Delegate already has Full Access" -Subject $id
        }
        else {
            Invoke-LtChange -Cmdlet $PSCmdlet -Subject $id -Target $id -Action "Grant Full Access to $Delegate" -ScriptBlock {
                Add-MailboxPermission -Identity $id -User $Delegate -AccessRights FullAccess -InheritanceType All -AutoMapping $true -Confirm:$false | Out-Null
            }
        }
    }

    if ($AutoReplyMessage) {
        Invoke-LtChange -Cmdlet $PSCmdlet -Subject $id -Target $id -Action 'Set auto-reply' -ScriptBlock {
            Set-MailboxAutoReplyConfiguration -Identity $id -AutoReplyState Enabled `
                -InternalMessage $AutoReplyMessage -ExternalMessage $AutoReplyMessage -ExternalAudience All -Confirm:$false
        }
    }
}

function Add-LtM365License {
    <#
    .SYNOPSIS
        Assigns licences by SKU ID (used when restoring a leaver's direct licences from a snapshot).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]$CloudUser,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$SkuId
    )
    $upn = $CloudUser.UserPrincipalName
    $missing = @($SkuId | Where-Object { $_ -and @($CloudUser.AssignedLicenses.SkuId) -notcontains $_ })
    if (-not $missing) {
        Write-LtLog 'No direct licences to restore' -Subject $upn
        return
    }
    Invoke-LtChange -Cmdlet $PSCmdlet -Subject $upn -Target $upn -Action "Restore $($missing.Count) direct licence(s)" -ScriptBlock {
        Set-MgUserLicense -UserId $CloudUser.Id -AddLicenses @($missing | ForEach-Object { @{ SkuId = $_ } }) -RemoveLicenses @() | Out-Null
    }
}

function Convert-LtMailboxToRegular {
    <#
    .SYNOPSIS
        Converts a restored leaver's shared mailbox back to a user mailbox and turns off the auto-reply.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$MailboxInfo)
    $id = $MailboxInfo.Identity

    if ($MailboxInfo.RecipientTypeDetails -eq 'UserMailbox') {
        Write-LtLog 'Mailbox is already a user mailbox' -Subject $id
    }
    else {
        Invoke-LtChange -Cmdlet $PSCmdlet -Subject $id -Target $id -Action 'Convert mailbox back to user mailbox' -ScriptBlock {
            Set-Mailbox -Identity $id -Type Regular -Confirm:$false
        }
    }
    Invoke-LtChange -Cmdlet $PSCmdlet -Subject $id -Target $id -Action 'Turn off auto-reply' -ScriptBlock {
        Set-MailboxAutoReplyConfiguration -Identity $id -AutoReplyState Disabled -Confirm:$false
    }
}
