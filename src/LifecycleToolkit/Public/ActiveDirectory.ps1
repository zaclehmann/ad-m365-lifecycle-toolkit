[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'ShouldProcess is called via Invoke-LtChange -Cmdlet $PSCmdlet.')]
param()

$script:LtUserProperties = @(
    'DisplayName', 'GivenName', 'Surname', 'UserPrincipalName', 'mail', 'EmployeeID', 'Department', 'Title',
    'Manager', 'MemberOf', 'HomeDirectory', 'HomeDrive', 'Description', 'Enabled', 'DistinguishedName',
    'ObjectGUID', 'SID', 'msExchHideFromAddressLists', 'AccountExpirationDate'
)

function Get-LtADUserByEmployeeId {
    <#
    .SYNOPSIS
        Finds an AD user by EmployeeID (the toolkit's idempotency key for starters).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EmployeeId,
        [string]$Server
    )
    $sp = Get-LtServerParam $Server
    $id = $EmployeeId.Replace("'", "''")
    $users = @(Get-ADUser -Filter "EmployeeID -eq '$id'" -Properties $script:LtUserProperties @sp)
    if ($users.Count -gt 1) {
        throw "EmployeeID '$EmployeeId' is on more than one AD account: $($users.SamAccountName -join ', ')"
    }
    $users | Select-Object -First 1
}

function Find-LtADUser {
    <#
    .SYNOPSIS
        Finds an AD user by sAMAccountName, UPN, distinguished name or object GUID. Returns $null if not found.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Identity,
        [string]$Server
    )
    $sp = Get-LtServerParam $Server
    $guid = [guid]::Empty
    if ([guid]::TryParse($Identity, [ref]$guid)) {
        try { return Get-ADUser -Identity $guid -Properties $script:LtUserProperties @sp }
        catch { return $null }
    }
    $id = $Identity.Replace("'", "''")
    $filter = if ($Identity -match '^CN=.+,DC=') { "DistinguishedName -eq '$id'" }
    elseif ($Identity -like '*@*') { "UserPrincipalName -eq '$id'" }
    else { "SamAccountName -eq '$id'" }
    Get-ADUser -Filter $filter -Properties $script:LtUserProperties @sp | Select-Object -First 1
}

function New-LtADUser {
    <#
    .SYNOPSIS
        Creates an AD user account for a starter.
    .OUTPUTS
        The new ADUser (with SID and ObjectGUID), or nothing under -WhatIf.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$SamAccountName,
        [Parameter(Mandatory)][string]$UserPrincipalName,
        [Parameter(Mandatory)][string]$GivenName,
        [Parameter(Mandatory)][string]$Surname,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][securestring]$Password,
        [Parameter(Mandatory)][string]$EmployeeId,
        [string]$Department,
        [string]$Title,
        [string]$Office,
        [string]$ManagerDN,
        [bool]$ChangePasswordAtLogon = $true,
        [string]$Server
    )

    $displayName = "$GivenName $Surname"
    $params = @{
        Name                  = $displayName
        SamAccountName        = $SamAccountName
        UserPrincipalName     = $UserPrincipalName
        GivenName             = $GivenName
        Surname               = $Surname
        DisplayName           = $displayName
        EmailAddress          = $UserPrincipalName
        EmployeeID            = $EmployeeId
        Path                  = $Path
        AccountPassword       = $Password
        ChangePasswordAtLogon = $ChangePasswordAtLogon
        Enabled               = $true
        PassThru              = $true
        Confirm               = $false
    }
    if ($Department) { $params.Department = $Department }
    if ($Title) { $params.Title = $Title; $params.Description = $Title }
    if ($Office) { $params.Office = $Office }
    if ($ManagerDN) { $params.Manager = $ManagerDN }
    $params += Get-LtServerParam $Server

    $sp = Get-LtServerParam $Server
    $cnClash = Get-ADUser -Filter "Name -eq '$($displayName.Replace("'", "''"))'" -SearchBase $Path -SearchScope OneLevel @sp
    if ($cnClash) { $params.Name = "$displayName ($SamAccountName)" }

    Invoke-LtChange -Cmdlet $PSCmdlet -Subject $SamAccountName -Target "CN=$($params.Name),$Path" -Action 'Create AD user' -ScriptBlock {
        New-ADUser @params
    }
}

function Add-LtGroupMembership {
    <#
    .SYNOPSIS
        Ensures a user is a member of each listed group. Groups the user is already in are skipped.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$SamAccountName,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Group,
        $User,
        [string]$Server
    )
    $sp = Get-LtServerParam $Server
    $outcome = [pscustomobject]@{
        Added         = New-Object System.Collections.Generic.List[string]
        AlreadyMember = New-Object System.Collections.Generic.List[string]
        Failed        = New-Object System.Collections.Generic.List[string]
    }
    $currentDNs = if ($User -and $User.MemberOf) { @($User.MemberOf) } else { @() }

    foreach ($name in ($Group | Where-Object { $_ } | Select-Object -Unique)) {
        $escaped = $name.Replace("'", "''")
        $adGroup = Get-ADGroup -Filter "Name -eq '$escaped' -or SamAccountName -eq '$escaped' -or DistinguishedName -eq '$escaped'" @sp |
            Select-Object -First 1
        if (-not $adGroup) {
            Write-LtLog "Group '$name' not found in AD" -Level ERROR -Subject $SamAccountName
            $outcome.Failed.Add($name)
            continue
        }
        if ($currentDNs -contains $adGroup.DistinguishedName) {
            Write-LtLog "Already a member of '$name'" -Subject $SamAccountName
            $outcome.AlreadyMember.Add($name)
            continue
        }
        try {
            Invoke-LtChange -Cmdlet $PSCmdlet -Subject $SamAccountName -Target $name -Action 'Add to group' -ScriptBlock {
                Add-ADGroupMember -Identity $adGroup -Members $SamAccountName -Confirm:$false @sp
            }
            $outcome.Added.Add($name)
        }
        catch {
            Write-LtLog "Failed to add to '$name': $($_.Exception.Message)" -Level ERROR -Subject $SamAccountName
            $outcome.Failed.Add($name)
        }
    }
    $outcome
}

function New-LtHomeFolder {
    <#
    .SYNOPSIS
        Creates a user's home folder, grants them access by SID and sets HomeDirectory/HomeDrive.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$SamAccountName,
        [Parameter(Mandatory)][string]$RootPath,
        [string]$DriveLetter = 'H:',
        [string]$AccessRights = 'Modify',
        $User,
        [string]$Server
    )
    $sp = Get-LtServerParam $Server
    $path = Join-Path $RootPath $SamAccountName

    if (Test-Path -LiteralPath $path) {
        Write-LtLog "Home folder already exists: $path" -Subject $SamAccountName
    }
    else {
        Invoke-LtChange -Cmdlet $PSCmdlet -Subject $SamAccountName -Target $path -Action 'Create home folder' -ScriptBlock {
            New-Item -ItemType Directory -Path $path -Confirm:$false | Out-Null
        }
    }

    if ($User -and $User.SID) {
        $sid = $User.SID
        if ($sid -isnot [System.Security.Principal.SecurityIdentifier]) {
            $sid = New-Object System.Security.Principal.SecurityIdentifier([string]$sid)
        }
        $acl = if (Test-Path -LiteralPath $path) { Get-Acl -LiteralPath $path } else { $null }
        $hasAce = $acl -and ($acl.Access | Where-Object {
                $_.IdentityReference.Value -eq $sid.Value -or
                ($_.IdentityReference -is [System.Security.Principal.NTAccount] -and $_.IdentityReference.Value -like "*\$SamAccountName")
            })
        if ($acl -and -not $hasAce) {
            Invoke-LtChange -Cmdlet $PSCmdlet -Subject $SamAccountName -Target $path -Action "Grant $AccessRights to user" -ScriptBlock {
                $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $sid, $AccessRights, 'ContainerInherit,ObjectInherit', 'None', 'Allow')
                $acl.AddAccessRule($rule)
                Set-Acl -LiteralPath $path -AclObject $acl -Confirm:$false
            }
        }
    }

    if (-not $User -or $User.HomeDirectory -ne $path -or $User.HomeDrive -ne $DriveLetter) {
        Invoke-LtChange -Cmdlet $PSCmdlet -Subject $SamAccountName -Target "$DriveLetter $path" -Action 'Set home drive' -ScriptBlock {
            Set-ADUser -Identity $SamAccountName -HomeDirectory $path -HomeDrive $DriveLetter -Confirm:$false @sp
        }
    }
    $path
}

function Save-LtUserSnapshot {
    <#
    .SYNOPSIS
        Saves a leaver's key attributes, groups and licences to JSON before anything is changed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]$User,
        [Parameter(Mandatory)][string]$Directory,
        [string]$Ticket,
        $CloudUser,
        $MailboxInfo
    )
    $directSkus = @()
    if ($CloudUser) {
        $directSkus = @($CloudUser.LicenseAssignmentStates | Where-Object { -not $_.AssignedByGroup } |
                ForEach-Object { [string]$_.SkuId } | Select-Object -Unique)
    }
    $snapshot = [ordered]@{
        SchemaVersion     = 1
        TakenAt           = (Get-Date).ToString('o')
        TakenBy           = "{0}\{1}" -f [Environment]::UserDomainName, [Environment]::UserName
        Ticket            = $Ticket
        SamAccountName    = $User.SamAccountName
        UserPrincipalName = $User.UserPrincipalName
        DisplayName       = $User.DisplayName
        EmployeeID        = $User.EmployeeID
        DistinguishedName = $User.DistinguishedName
        ObjectGUID        = [string]$User.ObjectGUID
        Enabled           = $User.Enabled
        Department        = $User.Department
        Title             = $User.Title
        Manager           = $User.Manager
        Description       = $User.Description
        HomeDirectory     = $User.HomeDirectory
        HiddenFromGal     = [bool]$User.msExchHideFromAddressLists
        MemberOf          = @($User.MemberOf)
        DirectLicenseSkuIds = $directSkus
        MailboxType       = $(if ($MailboxInfo) { $MailboxInfo.RecipientTypeDetails } else { $null })
    }
    $file = Join-Path $Directory ('{0}_{1}.json' -f $User.SamAccountName, (Get-Date -Format 'yyyyMMdd-HHmmssfff'))
    Invoke-LtChange -Cmdlet $PSCmdlet -Subject $User.SamAccountName -Target $file -Action 'Save pre-change snapshot' -ScriptBlock {
        [void][System.IO.Directory]::CreateDirectory($Directory)
        [System.IO.File]::WriteAllText($file, ($snapshot | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    }
    $file
}

function Disable-LtADUser {
    <#
    .SYNOPSIS
        Disables a leaver's account, resets the password, stamps the description and hides them from the GAL.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]$User,
        [Parameter(Mandatory)][string]$Description,
        [switch]$HideFromGal,
        [string]$Server
    )
    $sp = Get-LtServerParam $Server
    $sam = $User.SamAccountName
    $guid = [string]$User.ObjectGUID

    Invoke-LtChange -Cmdlet $PSCmdlet -Subject $sam -Target $sam -Action 'Reset password to random value' -ScriptBlock {
        Set-ADAccountPassword -Identity $guid -Reset -NewPassword (New-LtPassword -Length 32) -Confirm:$false @sp
    }

    if ($User.Enabled) {
        Invoke-LtChange -Cmdlet $PSCmdlet -Subject $sam -Target $sam -Action 'Disable account' -ScriptBlock {
            Disable-ADAccount -Identity $guid -Confirm:$false @sp
        }
    }
    else {
        Write-LtLog 'Account already disabled' -Subject $sam
    }

    $replace = @{}
    if ($HideFromGal -and -not $User.msExchHideFromAddressLists) { $replace.msExchHideFromAddressLists = $true }
    $action = if ($replace.Count) { "Set description '$Description' and hide from GAL" } else { "Set description '$Description'" }
    Invoke-LtChange -Cmdlet $PSCmdlet -Subject $sam -Target $sam -Action $action -ScriptBlock {
        $setParams = @{ Identity = $guid; Description = $Description; Confirm = $false }
        if ($replace.Count) { $setParams.Replace = $replace }
        Set-ADUser @setParams @sp
    }
}

function Remove-LtGroupMembership {
    <#
    .SYNOPSIS
        Removes a user from every group except the protected ones.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]$User,
        [string[]]$ProtectedGroup = @('Domain Users'),
        [string]$Server
    )
    $sp = Get-LtServerParam $Server
    $sam = $User.SamAccountName
    $outcome = [pscustomobject]@{
        Removed = New-Object System.Collections.Generic.List[string]
        Failed  = New-Object System.Collections.Generic.List[string]
    }

    foreach ($dn in @($User.MemberOf)) {
        if (-not $dn) { continue }
        $cn = ($dn -split '(?<!\\),', 2)[0] -replace '^CN=', ''
        if ($ProtectedGroup -contains $cn) {
            Write-LtLog "Keeping protected group '$cn'" -Subject $sam
            continue
        }
        try {
            Invoke-LtChange -Cmdlet $PSCmdlet -Subject $sam -Target $cn -Action 'Remove from group' -ScriptBlock {
                Remove-ADGroupMember -Identity $dn -Members ([string]$User.ObjectGUID) -Confirm:$false @sp
            }
            $outcome.Removed.Add($cn)
        }
        catch {
            Write-LtLog "Failed to remove from '$cn': $($_.Exception.Message)" -Level ERROR -Subject $sam
            $outcome.Failed.Add($cn)
        }
    }
    $outcome
}

function Move-LtADUserToOU {
    <#
    .SYNOPSIS
        Moves a user to the target OU, unless they are already there.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]$User,
        [Parameter(Mandatory)][string]$TargetOU,
        [string]$Server
    )
    $sp = Get-LtServerParam $Server
    $parent = ($User.DistinguishedName -split '(?<!\\),', 2)[1]
    if ($parent -eq $TargetOU) {
        Write-LtLog "Already in $TargetOU" -Subject $User.SamAccountName
        return
    }
    Invoke-LtChange -Cmdlet $PSCmdlet -Subject $User.SamAccountName -Target $TargetOU -Action 'Move to OU' -ScriptBlock {
        Move-ADObject -Identity ([string]$User.ObjectGUID) -TargetPath $TargetOU -Confirm:$false @sp
    }
}

function Move-LtHomeFolder {
    <#
    .SYNOPSIS
        Moves a leaver's home folder to the archive share with robocopy (keeps ACLs and timestamps).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ArchiveRoot,
        [string]$Subject
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-LtLog "Home folder not found, nothing to archive: $Path" -Level WARN -Subject $Subject
        return
    }
    $destination = Join-Path $ArchiveRoot (Split-Path $Path -Leaf)
    Invoke-LtChange -Cmdlet $PSCmdlet -Subject $Subject -Target "$Path -> $destination" -Action 'Archive home folder' -ScriptBlock {
        $null = & robocopy.exe $Path $destination /E /MOVE /COPY:DATSO /R:1 /W:1 /NP /NFL /NDL
        if ($LASTEXITCODE -ge 8) { throw "robocopy failed with exit code $LASTEXITCODE" }
    }
}

function Set-LtAccountExpiration {
    <#
    .SYNOPSIS
        Sets the account to expire at the end of the given day (used for leavers with a future leave date).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]$User,
        [Parameter(Mandatory)][datetime]$LeaveDate,
        [string]$Server
    )
    $sp = Get-LtServerParam $Server
    $expires = $LeaveDate.Date.AddDays(1)
    if ($User.AccountExpirationDate -and ([datetime]$User.AccountExpirationDate).Date -eq $expires) {
        Write-LtLog "Account already set to expire at the end of $($LeaveDate.ToString('yyyy-MM-dd'))" -Subject $User.SamAccountName
        return
    }
    Invoke-LtChange -Cmdlet $PSCmdlet -Subject $User.SamAccountName -Target $User.SamAccountName -Action "Set account to expire at end of $($LeaveDate.ToString('yyyy-MM-dd'))" -ScriptBlock {
        Set-ADUser -Identity ([string]$User.ObjectGUID) -AccountExpirationDate $expires -Confirm:$false @sp
    }
}

function Enable-LtADUser {
    <#
    .SYNOPSIS
        Re-enables a restored leaver: new password, description and GAL visibility back, expiry cleared.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]$User,
        [Parameter(Mandatory)][securestring]$Password,
        [AllowEmptyString()][string]$Description,
        [bool]$HiddenFromGal = $false,
        [string]$Server
    )
    $sp = Get-LtServerParam $Server
    $sam = $User.SamAccountName
    $guid = [string]$User.ObjectGUID

    $passwordParams = @{ Identity = $guid; Reset = $true; NewPassword = $Password; Confirm = $false }
    Invoke-LtChange -Cmdlet $PSCmdlet -Subject $sam -Target $sam -Action 'Set new password (change at next logon)' -ScriptBlock {
        Set-ADAccountPassword @passwordParams @sp
        Set-ADUser -Identity $guid -ChangePasswordAtLogon $true -Confirm:$false @sp
    }

    $setParams = @{ Identity = $guid; AccountExpirationDate = $null; Confirm = $false }
    $clear = @()
    if ($Description) { $setParams.Description = $Description } else { $clear += 'description' }
    if ($HiddenFromGal) { $setParams.Replace = @{ msExchHideFromAddressLists = $true } }
    elseif ($User.msExchHideFromAddressLists) { $clear += 'msExchHideFromAddressLists' }
    if ($clear) { $setParams.Clear = $clear }
    Invoke-LtChange -Cmdlet $PSCmdlet -Subject $sam -Target $sam -Action 'Restore description, GAL visibility and clear expiry' -ScriptBlock {
        Set-ADUser @setParams @sp
    }

    if ($User.Enabled) {
        Write-LtLog 'Account already enabled' -Subject $sam
    }
    else {
        Invoke-LtChange -Cmdlet $PSCmdlet -Subject $sam -Target $sam -Action 'Enable account' -ScriptBlock {
            Enable-ADAccount -Identity $guid -Confirm:$false @sp
        }
    }
}

function Get-LtUserSnapshot {
    <#
    .SYNOPSIS
        Loads a leaver snapshot from a file, or finds the earliest snapshot for a user in a folder.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path')][string]$Path,
        [Parameter(Mandatory, ParameterSetName = 'Find')][string]$Directory,
        [Parameter(Mandatory, ParameterSetName = 'Find')][string]$SamAccountName
    )
    if ($PSCmdlet.ParameterSetName -eq 'Find') {
        $files = @(Get-ChildItem -Path $Directory -Filter "$SamAccountName`_*.json" -File -ErrorAction SilentlyContinue |
                Where-Object { $_.BaseName -match "^$([regex]::Escape($SamAccountName))_\d{8}-\d{6,9}$" } |
                Sort-Object Name)
        if (-not $files) { throw "No snapshot for '$SamAccountName' in $Directory" }
        $Path = $files[0].FullName
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Snapshot not found: $Path" }

    $snapshot = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($field in 'SamAccountName', 'ObjectGUID', 'DistinguishedName') {
        if (-not $snapshot.$field) { throw "Snapshot '$Path' has no $field; is it a toolkit snapshot?" }
    }
    $snapshot | Add-Member -NotePropertyName SourcePath -NotePropertyValue $Path -Force
    $snapshot
}
