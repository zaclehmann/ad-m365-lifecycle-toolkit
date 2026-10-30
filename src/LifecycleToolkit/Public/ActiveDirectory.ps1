$script:LtUserProperties = @(
    'DisplayName', 'GivenName', 'Surname', 'UserPrincipalName', 'mail', 'EmployeeID', 'Department', 'Title',
    'Manager', 'MemberOf', 'HomeDirectory', 'HomeDrive', 'Description', 'Enabled', 'DistinguishedName',
    'ObjectGUID', 'SID', 'msExchHideFromAddressLists'
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
        Finds an AD user by sAMAccountName, UPN or distinguished name. Returns $null if not found.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Identity,
        [string]$Server
    )
    $sp = Get-LtServerParam $Server
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

    # The CN must be unique within the OU; fall back to "Name (username)" if a namesake already lives there.
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
    .DESCRIPTION
        Each group is checked for existence first, even under -WhatIf, so typos in the config or CSV
        show up in a preview run. Returns an object listing Added, AlreadyMember and Failed groups.
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
        $adGroup = Get-ADGroup -Filter "Name -eq '$($name.Replace("'", "''"))' -or SamAccountName -eq '$($name.Replace("'", "''"))'" @sp |
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
    .DESCRIPTION
        The ACE uses the account SID rather than DOMAIN\user, because a brand-new account may not
        yet have replicated to the DC the file server asks, and name resolution would fail.
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
        Saves a leaver's key attributes and group memberships to JSON before anything is changed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]$User,
        [Parameter(Mandatory)][string]$Directory,
        [string]$Ticket
    )
    $snapshot = [ordered]@{
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
        MemberOf          = @($User.MemberOf)
    }
    $file = Join-Path $Directory ('{0}_{1}.json' -f $User.SamAccountName, (Get-Date -Format 'yyyyMMdd-HHmmss'))
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
    .DESCRIPTION
        Carries on past a failed removal so one locked-down group doesn't block the rest.
        Returns an object listing Removed and Failed group names.
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
        # Move-Item can't move folders between servers; robocopy can, and keeps security (/COPY:DATSO).
        $null = & robocopy.exe $Path $destination /E /MOVE /COPY:DATSO /R:1 /W:1 /NP /NFL /NDL
        if ($LASTEXITCODE -ge 8) { throw "robocopy failed with exit code $LASTEXITCODE" }
    }
}
