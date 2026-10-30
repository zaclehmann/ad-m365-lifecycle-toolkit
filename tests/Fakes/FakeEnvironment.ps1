<#
.SYNOPSIS
    In-memory stand-ins for the ActiveDirectory, Microsoft.Graph and ExchangeOnlineManagement cmdlets.

.DESCRIPTION
    Dot-source this file to run the toolkit end to end with no domain, tenant or file server.
    Global functions take precedence over (and stand in for) missing cmdlets, so the real
    entry scripts and module run unchanged. Every state change is appended to $FakeEnv.Changes,
    which tests use to check that -WhatIf changes nothing and that steps run in the right order.

    Only the parts of each cmdlet that the toolkit uses are implemented.
#>

$global:FakeIsWindows = $PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows

function global:Reset-FakeEnvironment {
    $global:FakeEnv = @{
        Users        = New-Object System.Collections.Generic.List[object]
        Groups       = @{}       # name -> @{ DN; Members = HashSet of ObjectGUID }
        CloudUsers   = @{}       # UPN -> object
        Mailboxes    = @{}       # UPN -> object
        Permissions  = New-Object System.Collections.Generic.List[object]
        AutoReplies  = @{}
        Skus         = @(
            [pscustomobject]@{ SkuId = '05e9a617-0261-4cee-bb44-138d3ef5d965'; SkuPartNumber = 'SPE_E3'; ConsumedUnits = 10; PrepaidUnits = [pscustomobject]@{ Enabled = 20 } },
            [pscustomobject]@{ SkuId = '06ebc4ee-1bb5-47dd-8120-11324bc54e06'; SkuPartNumber = 'SPE_E5'; ConsumedUnits = 5; PrepaidUnits = [pscustomobject]@{ Enabled = 5 } }
        )
        Changes      = New-Object System.Collections.Generic.List[string]
        GraphContext = $null
        ExoConnected = $false
        SyncOnDemand = $true     # a delta sync copies AD users to the cloud straight away
        FailMailboxConversion = $false
        NextRid      = 1100
    }
}

function global:Add-FakeChange([string]$Text) { $global:FakeEnv.Changes.Add($Text) }

function global:Add-FakeGroup {
    param([string]$Name, [string]$OU = 'OU=Groups,OU=Contoso,DC=contoso,DC=local')
    $global:FakeEnv.Groups[$Name] = @{ Name = $Name; DN = "CN=$Name,$OU"; Members = New-Object 'System.Collections.Generic.HashSet[string]' }
}

function global:Add-FakeUser {
    param(
        [string]$Sam, [string]$GivenName, [string]$Surname, [string]$EmployeeId,
        [string]$OU = 'OU=Users,OU=Contoso,DC=contoso,DC=local',
        [string]$ManagerSam, [string[]]$Groups = @(), [switch]$WithMailbox, [double]$MailboxGB = 2,
        [string]$UpnSuffix = 'contoso.com', [switch]$Synced
    )
    $global:FakeEnv.NextRid++
    $name = "$GivenName $Surname"
    $user = [pscustomobject]@{
        SamAccountName             = $Sam
        UserPrincipalName          = "$Sam@$UpnSuffix"
        Name                       = $name
        GivenName                  = $GivenName
        Surname                    = $Surname
        DisplayName                = $name
        mail                       = "$Sam@$UpnSuffix"
        EmployeeID                 = $EmployeeId
        Department                 = $null
        Title                      = $null
        Office                     = $null
        Manager                    = $null
        HomeDirectory              = $null
        HomeDrive                  = $null
        Description                = $null
        Enabled                    = $true
        DistinguishedName          = "CN=$name,$OU"
        ObjectGUID                 = [guid]::NewGuid()
        SID                        = $(if ($global:FakeIsWindows) { "S-1-5-21-1111111111-2222222222-3333333333-$($global:FakeEnv.NextRid)" } else { $null })
        msExchHideFromAddressLists = $null
        AccountExpirationDate      = $null
        ChangePasswordAtLogon      = $false
    }
    if ($ManagerSam) { $user.Manager = (Get-FakeUserRecord $ManagerSam).DistinguishedName }
    $global:FakeEnv.Users.Add($user)
    foreach ($g in $Groups) { [void]$global:FakeEnv.Groups[$g].Members.Add([string]$user.ObjectGUID) }
    if ($Synced -or $WithMailbox) { Sync-FakeUser $user }
    if ($WithMailbox) {
        $bytes = [long]($MailboxGB * 1GB)
        $global:FakeEnv.Mailboxes[$user.UserPrincipalName] = [pscustomobject]@{
            UserPrincipalName     = $user.UserPrincipalName
            RecipientTypeDetails  = 'UserMailbox'
            LitigationHoldEnabled = $false
            InPlaceHolds          = @()
            ArchiveStatus         = 'None'
            TotalItemSize         = '{0:N1} GB ({1:N0} bytes)' -f $MailboxGB, $bytes
        }
    }
    $user
}

function global:Sync-FakeUser($User) {
    if (-not $global:FakeEnv.CloudUsers.ContainsKey($User.UserPrincipalName)) {
        $global:FakeEnv.CloudUsers[$User.UserPrincipalName] = [pscustomobject]@{
            Id                      = [guid]::NewGuid().ToString()
            UserPrincipalName       = $User.UserPrincipalName
            UsageLocation           = $null
            AssignedLicenses        = @()
            LicenseAssignmentStates = @()
            AccountEnabled          = $User.Enabled
        }
    }
}

function global:Get-FakeUserRecord([string]$Identity) {
    $global:FakeEnv.Users | Where-Object {
        $_.SamAccountName -eq $Identity -or [string]$_.ObjectGUID -eq $Identity -or $_.DistinguishedName -eq $Identity -or $_.UserPrincipalName -eq $Identity
    } | Select-Object -First 1
}

function global:ConvertTo-FakeADUser($Record) {
    # Return a copy with MemberOf calculated, like a fresh LDAP read.
    $copy = $Record.PSObject.Copy()
    $memberOf = @($global:FakeEnv.Groups.Values | Where-Object { $_.Members.Contains([string]$Record.ObjectGUID) } | ForEach-Object { $_.DN })
    $copy | Add-Member -NotePropertyName MemberOf -NotePropertyValue $memberOf -Force
    $copy
}

function global:Test-FakeFilter($Object, [string]$Filter) {
    $clauses = [regex]::Matches($Filter, "(\w+)\s+-eq\s+'((?:[^']|'')*)'")
    foreach ($c in $clauses) {
        $prop = $c.Groups[1].Value
        $value = $c.Groups[2].Value.Replace("''", "'")
        if ([string]$Object.$prop -eq $value) { return $true }   # all toolkit filters are -eq joined by -or
    }
    $false
}

# ---- ActiveDirectory --------------------------------------------------------------------------

function global:Get-ADUser {
    param($Identity, [string]$Filter, $Properties, [string]$Server, [string]$SearchBase, [string]$SearchScope)
    if ($Identity) {
        $r = Get-FakeUserRecord ([string]$Identity)
        if (-not $r) { throw "Cannot find an object with identity: '$Identity'" }
        return ConvertTo-FakeADUser $r
    }
    foreach ($u in $global:FakeEnv.Users.ToArray()) {
        if ($SearchBase -and ($u.DistinguishedName -split '(?<!\\),', 2)[1] -ne $SearchBase) { continue }
        if (Test-FakeFilter $u $Filter) { ConvertTo-FakeADUser $u }
    }
}

function global:New-ADUser {
    param($Name, $SamAccountName, $UserPrincipalName, $GivenName, $Surname, $DisplayName, $EmailAddress, $EmployeeID,
        $Path, $AccountPassword, $ChangePasswordAtLogon, $Enabled, $Department, $Title, $Description, $Office, $Manager,
        [switch]$PassThru, $Server, [switch]$Confirm)
    if (Get-FakeUserRecord $SamAccountName) { throw "The specified account already exists" }
    if ($global:FakeEnv.Users | Where-Object { $_.DistinguishedName -eq "CN=$Name,$Path" }) { throw "An attempt was made to add an object to the directory with a name that is already in use" }
    $u = Add-FakeUser -Sam $SamAccountName -GivenName $GivenName -Surname $Surname -EmployeeId $EmployeeID -OU $Path -UpnSuffix ($UserPrincipalName -split '@')[1]
    $u.Name = $Name; $u.DistinguishedName = "CN=$Name,$Path"
    $u.Department = $Department; $u.Title = $Title; $u.Description = $Description; $u.Office = $Office; $u.Manager = $Manager
    Add-FakeChange "New-ADUser $SamAccountName"
    if ($PassThru) { ConvertTo-FakeADUser $u }
}

function global:Set-ADUser {
    param($Identity, $HomeDirectory, $HomeDrive, $Description, [hashtable]$Replace, [string[]]$Clear,
        $AccountExpirationDate, $ChangePasswordAtLogon, $Server, [switch]$Confirm)
    $u = Get-FakeUserRecord ([string]$Identity)
    foreach ($p in 'HomeDirectory', 'HomeDrive', 'Description', 'AccountExpirationDate', 'ChangePasswordAtLogon') {
        if ($PSBoundParameters.ContainsKey($p)) { $u.$p = $PSBoundParameters[$p] }
    }
    if ($Replace) { foreach ($k in $Replace.Keys) { $u.$k = $Replace[$k] } }
    foreach ($k in $Clear) { $u.$k = $null }
    Add-FakeChange "Set-ADUser $($u.SamAccountName)"
}

function global:Get-ADGroup {
    param([string]$Filter, $Server)
    foreach ($g in $global:FakeEnv.Groups.Values) {
        $obj = [pscustomobject]@{ Name = $g.Name; SamAccountName = $g.Name; DistinguishedName = $g.DN }
        if (Test-FakeFilter $obj $Filter) { $obj }
    }
}

function global:Find-FakeGroup($Identity) {
    $id = if ($Identity.DistinguishedName) { $Identity.DistinguishedName } else { [string]$Identity }
    $global:FakeEnv.Groups.Values | Where-Object { $_.DN -eq $id -or $_.Name -eq $id } | Select-Object -First 1
}

function global:Add-ADGroupMember {
    param($Identity, $Members, $Server, [switch]$Confirm)
    $g = Find-FakeGroup $Identity
    $u = Get-FakeUserRecord ([string]$Members)
    [void]$g.Members.Add([string]$u.ObjectGUID)
    Add-FakeChange "Add-ADGroupMember $($g.Name) $($u.SamAccountName)"
}

function global:Remove-ADGroupMember {
    param($Identity, $Members, $Server, [switch]$Confirm)
    $g = Find-FakeGroup $Identity
    $u = Get-FakeUserRecord ([string]$Members)
    [void]$g.Members.Remove([string]$u.ObjectGUID)
    Add-FakeChange "Remove-ADGroupMember $($g.Name) $($u.SamAccountName)"
}

function global:Set-ADAccountPassword {
    param($Identity, [switch]$Reset, $NewPassword, $Server, [switch]$Confirm)
    Add-FakeChange "Set-ADAccountPassword $((Get-FakeUserRecord ([string]$Identity)).SamAccountName)"
}

function global:Disable-ADAccount {
    param($Identity, $Server, [switch]$Confirm)
    $u = Get-FakeUserRecord ([string]$Identity)
    $u.Enabled = $false
    Add-FakeChange "Disable-ADAccount $($u.SamAccountName)"
}

function global:Enable-ADAccount {
    param($Identity, $Server, [switch]$Confirm)
    $u = Get-FakeUserRecord ([string]$Identity)
    $u.Enabled = $true
    Add-FakeChange "Enable-ADAccount $($u.SamAccountName)"
}

function global:Move-ADObject {
    param($Identity, $TargetPath, $Server, [switch]$Confirm)
    $u = Get-FakeUserRecord ([string]$Identity)
    $u.DistinguishedName = "CN=$($u.Name),$TargetPath"
    Add-FakeChange "Move-ADObject $($u.SamAccountName)"
}

# ---- Entra Connect (Invoke-Command to the sync server) ----------------------------------------

function global:Invoke-Command {
    param($ComputerName, $ScriptBlock, $ErrorAction)
    Add-FakeChange "DeltaSync $ComputerName"
    if ($global:FakeEnv.SyncOnDemand) { foreach ($u in $global:FakeEnv.Users) { Sync-FakeUser $u } }
}

# ---- Microsoft Graph --------------------------------------------------------------------------

function global:Get-MgContext { $global:FakeEnv.GraphContext }
function global:Connect-MgGraph {
    param($TenantId, $ClientId, $CertificateThumbprint, $Scopes, [switch]$NoWelcome)
    $global:FakeEnv.GraphContext = [pscustomobject]@{ TenantId = $TenantId; Account = 'fake@contoso.com'; AppName = $null }
}

function global:Get-MgUser {
    param([string]$Filter, $Property, $UserId)
    if ($Filter -match "userPrincipalName eq '(.+)'") { $global:FakeEnv.CloudUsers[$Matches[1].Replace("''", "'")] }
}

function global:Find-FakeCloudUser($Id) { $global:FakeEnv.CloudUsers.Values | Where-Object Id -eq $Id | Select-Object -First 1 }

function global:Update-MgUser {
    param($UserId, $UsageLocation)
    $u = Find-FakeCloudUser $UserId
    $u.UsageLocation = $UsageLocation
    Add-FakeChange "Update-MgUser $($u.UserPrincipalName) UsageLocation=$UsageLocation"
}

function global:Get-MgSubscribedSku { param([switch]$All) $global:FakeEnv.Skus }

function global:Set-MgUserLicense {
    param($UserId, $AddLicenses, $RemoveLicenses)
    $u = Find-FakeCloudUser $UserId
    foreach ($a in $AddLicenses) {
        $u.AssignedLicenses = @($u.AssignedLicenses) + [pscustomobject]@{ SkuId = $a.SkuId }
        $u.LicenseAssignmentStates = @($u.LicenseAssignmentStates) + [pscustomobject]@{ SkuId = $a.SkuId; AssignedByGroup = $null }
    }
    foreach ($r in $RemoveLicenses) {
        $u.AssignedLicenses = @($u.AssignedLicenses | Where-Object SkuId -ne $r)
        $u.LicenseAssignmentStates = @($u.LicenseAssignmentStates | Where-Object SkuId -ne $r)
    }
    Add-FakeChange "Set-MgUserLicense $($u.UserPrincipalName) +$(@($AddLicenses).Count) -$(@($RemoveLicenses).Count)"
}

function global:Revoke-MgUserSignInSession {
    param($UserId)
    Add-FakeChange "Revoke-MgUserSignInSession $((Find-FakeCloudUser $UserId).UserPrincipalName)"
}

# ---- Exchange Online --------------------------------------------------------------------------

function global:Get-ConnectionInformation { if ($global:FakeEnv.ExoConnected) { [pscustomobject]@{ State = 'Connected'; Organization = 'contoso.onmicrosoft.com' } } }
function global:Connect-ExchangeOnline { param($AppId, $CertificateThumbprint, $Organization, $ShowBanner) $global:FakeEnv.ExoConnected = $true }

function global:Get-EXOMailbox {
    param($Identity, $Properties, $ErrorAction)
    $global:FakeEnv.Mailboxes[[string]$Identity]
}

function global:Get-EXOMailboxStatistics {
    param($Identity, $ErrorAction)
    $m = $global:FakeEnv.Mailboxes[[string]$Identity]
    if ($m) { [pscustomobject]@{ TotalItemSize = $m.TotalItemSize } }
}

function global:Set-Mailbox {
    param($Identity, $Type, [switch]$Confirm)
    if ($global:FakeEnv.FailMailboxConversion) { throw "The operation couldn't be performed because object '$Identity' couldn't be found" }
    $global:FakeEnv.Mailboxes[[string]$Identity].RecipientTypeDetails = $(if ($Type -eq 'Regular') { 'UserMailbox' } else { "${Type}Mailbox" })
    Add-FakeChange "Set-Mailbox $Identity Type=$Type"
}

function global:Get-EXOMailboxPermission {
    param($Identity, $User, $ErrorAction)
    $global:FakeEnv.Permissions | Where-Object { $_.Identity -eq $Identity -and $_.User -eq $User }
}

function global:Add-MailboxPermission {
    param($Identity, $User, $AccessRights, $InheritanceType, $AutoMapping, [switch]$Confirm)
    $global:FakeEnv.Permissions.Add([pscustomobject]@{ Identity = $Identity; User = $User; AccessRights = @($AccessRights) })
    Add-FakeChange "Add-MailboxPermission $Identity $User"
}

function global:Set-MailboxAutoReplyConfiguration {
    param($Identity, $AutoReplyState, $InternalMessage, $ExternalMessage, $ExternalAudience, [switch]$Confirm)
    $global:FakeEnv.AutoReplies[[string]$Identity] = $(if ($AutoReplyState -eq 'Disabled') { $null } else { $InternalMessage })
    Add-FakeChange "Set-MailboxAutoReplyConfiguration $Identity"
}

# ---- File system ACLs (Windows-only APIs) -----------------------------------------------------
if (-not $global:FakeIsWindows) {
    function global:Get-Acl { param($LiteralPath) $null }
}

# ---- Test config ------------------------------------------------------------------------------

function global:New-FakeConfig {
    <#
        Writes a copy of the shipped config with paths pointed at a temp folder. Returns the path.
    #>
    param(
        [Parameter(Mandatory)][string]$Directory,
        [string]$LicenseMode = 'Group',
        [string]$HomeLeaverAction = 'Keep'
    )
    $source = Join-Path $PSScriptRoot '..\..\config\toolkit.config.psd1'
    $text = Get-Content -LiteralPath $source -Raw
    $homeRoot = Join-Path $Directory 'home'
    [void][System.IO.Directory]::CreateDirectory($homeRoot)
    $text = $text.Replace("'\\FS01\Home$'", "'$homeRoot'")
    $text = $text.Replace("'\\FS01\HomeArchive$'", "'$(Join-Path $Directory 'archive')'")
    $text = $text.Replace("LicenseMode           = 'Group'", "LicenseMode           = '$LicenseMode'")
    $text = $text.Replace("LeaverAction = 'Keep'", "LeaverAction = '$HomeLeaverAction'")
    $text = $text.Replace("WaitTimeoutSeconds  = 900", 'WaitTimeoutSeconds  = 2').Replace('PollIntervalSeconds = 30', 'PollIntervalSeconds = 1')
    $text = $text.Replace("Path          = 'logs'", "Path          = '$(Join-Path $Directory 'logs')'")
    $text = $text.Replace("ReportPath    = 'output\reports'", "ReportPath    = '$(Join-Path $Directory 'reports')'")
    $text = $text.Replace("SnapshotPath             = 'output\snapshots'", "SnapshotPath             = '$(Join-Path $Directory 'snapshots')'")
    $path = Join-Path $Directory 'test.config.psd1'
    Set-Content -LiteralPath $path -Value $text -Encoding UTF8
    $path
}

function global:Initialize-FakeDirectory {
    <#
        Seeds a small directory: groups from the shipped config, two managers and two leavers.
    #>
    Reset-FakeEnvironment
    foreach ($g in 'GG_AllStaff', 'GG_IT', 'GG_IT_Helpdesk', 'GG_Finance', 'GG_Finance_Share_RW', 'GG_Sales', 'GG_CRM_Users',
        'GG_VPN_Users', 'GG_Remote_Desktop', 'LIC_M365_E3', 'Domain Users') {
        Add-FakeGroup $g
    }
    $null = Add-FakeUser -Sam 'mark.jones' -GivenName 'Mark' -Surname 'Jones' -EmployeeId 'E00001' -WithMailbox -Groups 'GG_AllStaff'
    $null = Add-FakeUser -Sam 'sara.khan' -GivenName 'Sara' -Surname 'Khan' -EmployeeId 'E00002' -WithMailbox -Groups 'GG_AllStaff', 'GG_IT'
    $null = Add-FakeUser -Sam 'tom.baker' -GivenName 'Tom' -Surname 'Baker' -EmployeeId 'E00003' -ManagerSam 'mark.jones' -WithMailbox `
        -Groups 'GG_AllStaff', 'GG_Sales', 'LIC_M365_E3', 'Domain Users'
    $null = Add-FakeUser -Sam 'amy.wong' -GivenName 'Amy' -Surname 'Wong' -EmployeeId 'E00004' -ManagerSam 'mark.jones' -WithMailbox -MailboxGB 62 `
        -Groups 'GG_AllStaff', 'GG_Sales', 'GG_CRM_Users'
    # A namesake for the first starter, so the username clash logic is exercised.
    $null = Add-FakeUser -Sam 'jane.smith' -GivenName 'Jane' -Surname 'Smith' -EmployeeId 'E09999' -Groups 'GG_AllStaff'

    # amy.wong has a direct E3 licence.
    $amy = $global:FakeEnv.CloudUsers['amy.wong@contoso.com']
    $amy.AssignedLicenses = @([pscustomobject]@{ SkuId = '05e9a617-0261-4cee-bb44-138d3ef5d965' })
    $amy.LicenseAssignmentStates = @([pscustomobject]@{ SkuId = '05e9a617-0261-4cee-bb44-138d3ef5d965'; AssignedByGroup = $null })
    $global:FakeEnv.Changes.Clear()
}

Reset-FakeEnvironment
