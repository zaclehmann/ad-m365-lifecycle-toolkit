#Requires -Version 5.1
<#
.SYNOPSIS
    Onboards new starters from a CSV: AD account, groups, home folder and Microsoft 365 licence.

.DESCRIPTION
    For each CSV row the script:
      1. Validates the row.
      2. Creates the AD user in the department OU with a random password (or finds the existing
         account by EmployeeID, so re-running is safe and finishes incomplete starters).
      3. Adds baseline, department and per-row groups (plus the licence group in Group mode).
      4. Creates the home folder and grants the user access.
      5. Direct licence mode only: triggers a delta sync, waits for the cloud user, then sets the
         usage location and assigns the SKU.

    Run with -WhatIf first. A preview run still checks the config, CSV, OUs, groups, manager
    accounts and licence SKUs, so it works as a pre-flight test.

    Initial passwords are shown once on screen at the end of the run. They are never written
    to the log file or the report.

.PARAMETER CsvPath
    CSV of starters. Required columns: FirstName, LastName, EmployeeId, Department.
    Optional columns: JobTitle, Office, Manager (sAMAccountName or UPN), Groups (separated by ;),
    UsageLocation (2-letter country code), LicenseSku (SkuPartNumber, Direct mode only).

.PARAMETER ConfigPath
    Toolkit config file. Defaults to config\toolkit.config.psd1 next to this script.

.PARAMETER SkipCloud
    Only do the on-prem AD and file server steps. Nothing in Microsoft 365 is changed.

.PARAMETER PassThru
    Output the result objects (InitialPassword is a SecureString) for use in automation.
    The script then returns normally and sets $LASTEXITCODE instead of calling exit.

.EXAMPLE
    .\Invoke-Onboarding.ps1 -CsvPath .\samples\new-starters.csv -WhatIf

    Previews every change without making any.

.EXAMPLE
    .\Invoke-Onboarding.ps1 -CsvPath \\fs01\hr$\starters-2026-11-03.csv

.NOTES
    Exit codes: 0 = all succeeded, 1 = at least one starter failed or partly failed,
    2 = the config or CSV could not be loaded.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$CsvPath,
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
    $logFile = Initialize-LtLog -Directory $config.Logging.Path -Operation 'Onboarding' -RetentionDays $config.Logging.RetentionDays
    Write-LtLog ("Onboarding run {0} started by {1}\{2} on {3}{4}" -f (Get-LtLogState).RunId, [Environment]::UserDomainName, [Environment]::UserName, [Environment]::MachineName, $(if ($isPreview) { ' [WHATIF - no changes will be made]' }))
    Write-LtLog "Config: $ConfigPath | CSV: $CsvPath | Log: $logFile"

    Assert-LtCommand -Name 'Get-ADUser', 'New-ADUser', 'Add-ADGroupMember' -Module 'ActiveDirectory' `
        -InstallHint 'Install RSAT: Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0'

    $rows = @(Import-LtCsv -Path $CsvPath -RequiredColumns 'FirstName', 'LastName', 'EmployeeId', 'Department')
    Write-LtLog "Loaded $($rows.Count) starter(s) from CSV"

    $ad = $config.ActiveDirectory
    $m365 = $config.M365
    $useCloud = $m365.Enabled -and -not $SkipCloud
    $licenseMode = if ($m365.Enabled) { $m365.LicenseMode } else { 'None' }
    if ($useCloud -and $licenseMode -eq 'Direct') {
        Connect-LtCloud -M365Config $m365 -Graph
    }
}
catch {
    if ((Get-LtLogState).File) { Write-LtLog "Setup failed: $($_.Exception.Message)" -Level ERROR }
    else { Write-Error "Setup failed: $($_.Exception.Message)" -ErrorAction Continue }
    exit 2
}

# ---- Pre-flight: duplicate EmployeeIds in the CSV --------------------------------------------
$duplicateIds = $rows | Group-Object EmployeeId | Where-Object { $_.Name -and $_.Count -gt 1 } | ForEach-Object Name

# ---- Per starter -----------------------------------------------------------------------------
$reserved = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$results = New-Object System.Collections.Generic.List[object]
$passwords = New-Object System.Collections.Generic.List[object]
$needsLicence = New-Object System.Collections.Generic.List[object]
$rowNumber = 1

foreach ($row in $rows) {
    $rowNumber++  # row 1 is the header
    $first = Get-LtCsvValue $row 'FirstName'
    $last = Get-LtCsvValue $row 'LastName'
    $employeeId = Get-LtCsvValue $row 'EmployeeId'
    $department = Get-LtCsvValue $row 'Department'
    $result = New-LtResult -Name "$first $last ($employeeId)" -Row $rowNumber
    $results.Add($result)
    $userCreated = $false

    try {
        # 1. Validate --------------------------------------------------------------------------
        $problems = @()
        foreach ($col in 'FirstName', 'LastName', 'EmployeeId', 'Department') {
            if (-not (Get-LtCsvValue $row $col)) { $problems += "$col is empty" }
        }
        if ($employeeId -and $duplicateIds -contains $employeeId) { $problems += "EmployeeId $employeeId appears more than once in the CSV" }
        $usageLocation = Get-LtCsvValue $row 'UsageLocation'
        if (-not $usageLocation) { $usageLocation = $m365.DefaultUsageLocation }
        if ($usageLocation -and $usageLocation -notmatch '^[A-Za-z]{2}$') { $problems += "UsageLocation '$usageLocation' must be a 2-letter country code" }
        if ($problems) {
            foreach ($p in $problems) { Add-LtResultMessage $result Error "Row $rowNumber invalid: $p" }
            $result.Status = 'Failed'
            continue
        }
        $usageLocation = if ($usageLocation) { $usageLocation.ToUpperInvariant() } else { $null }

        $ou = $ad.DepartmentOUs[$department]
        if (-not $ou) {
            $ou = $ad.DefaultUserOU
            Add-LtResultMessage $result Warning "No OU mapped for department '$department'; using $ou"
        }

        $managerDN = $null
        $managerName = Get-LtCsvValue $row 'Manager'
        if ($managerName) {
            $manager = Find-LtADUser -Identity $managerName -Server $ad.Server
            if ($manager) { $managerDN = $manager.DistinguishedName }
            else { Add-LtResultMessage $result Warning "Manager '$managerName' not found in AD; manager left blank" }
        }

        # 2. AD account ------------------------------------------------------------------------
        $user = Get-LtADUserByEmployeeId -EmployeeId $employeeId -Server $ad.Server
        if ($user) {
            $result.SamAccountName = $user.SamAccountName
            $result.UserPrincipalName = $user.UserPrincipalName
            Write-LtLog "Account already exists for EmployeeID $employeeId; checking the remaining steps" -Subject $user.SamAccountName
            Add-LtResultMessage $result Action 'AD account already existed'
        }
        else {
            $sam = New-LtSamAccountName -FirstName $first -LastName $last -Format $ad.SamAccountNameFormat `
                -UpnSuffix $config.Organisation.UpnSuffix -Reserved $reserved -Server $ad.Server
            $result.SamAccountName = $sam
            $result.UserPrincipalName = "$sam@$($config.Organisation.UpnSuffix)"
            $password = New-LtPassword -Length $ad.PasswordLength -AsPlainText
            $result.InitialPassword = ConvertTo-SecureString $password -AsPlainText -Force

            $user = New-LtADUser @sp -SamAccountName $sam -UserPrincipalName $result.UserPrincipalName `
                -GivenName $first -Surname $last -Path $ou -Password $result.InitialPassword -EmployeeId $employeeId `
                -Department $department -Title (Get-LtCsvValue $row 'JobTitle') -Office (Get-LtCsvValue $row 'Office') `
                -ManagerDN $managerDN -ChangePasswordAtLogon ([bool]$ad.ChangePasswordAtLogon) -Server $ad.Server
            if ($user) {
                $userCreated = $true
                Add-LtResultMessage $result Action "Created AD user in $ou"
                $passwords.Add([pscustomobject]@{ SamAccountName = $sam; UserPrincipalName = $result.UserPrincipalName; Password = $password })
            }
            elseif ($isPreview) {
                Add-LtResultMessage $result Action "Created AD user in $ou" -Preview
            }
            else {
                throw 'AD user was not created (not confirmed)'
            }
        }
        $sam = $result.SamAccountName

        # 3. Groups ----------------------------------------------------------------------------
        $groups = @($config.Groups.Baseline) + @($config.Groups.Department[$department])
        $csvGroups = Get-LtCsvValue $row 'Groups'
        if ($csvGroups) { $groups += $csvGroups -split '[;,]' | ForEach-Object { $_.Trim() } }
        if ($licenseMode -eq 'Group') { $groups += $m365.LicenseGroup }
        $groups = @($groups | Where-Object { $_ })

        $groupOutcome = Add-LtGroupMembership @sp -SamAccountName $sam -Group $groups -User $user -Server $ad.Server
        if ($groupOutcome.Added.Count) {
            Add-LtResultMessage $result Action "Added to $($groupOutcome.Added.Count) group(s): $($groupOutcome.Added -join ', ')" -Preview:$isPreview
        }
        foreach ($g in $groupOutcome.Failed) { Add-LtResultMessage $result Error "Group '$g' could not be added" -NoLog }

        # 4. Home folder -----------------------------------------------------------------------
        if ($config.HomeFolder.Enabled) {
            try {
                # Re-read the user so we have the SID and current HomeDirectory.
                $freshUser = if ($user) { Get-LtADUserByEmployeeId -EmployeeId $employeeId -Server $ad.Server } else { $null }
                $homePath = New-LtHomeFolder @sp -SamAccountName $sam -RootPath $config.HomeFolder.RootPath `
                    -DriveLetter $config.HomeFolder.DriveLetter -AccessRights $config.HomeFolder.AccessRights `
                    -User $freshUser -Server $ad.Server
                Add-LtResultMessage $result Action "Home folder $homePath" -Preview:$isPreview
            }
            catch {
                Add-LtResultMessage $result Error "Home folder: $($_.Exception.Message)"
            }
        }

        # 5. Licence ---------------------------------------------------------------------------
        if ($useCloud -and $licenseMode -eq 'Direct') {
            $skuName = Get-LtCsvValue $row 'LicenseSku'
            if (-not $skuName) { $skuName = $m365.DefaultLicenseSku }
            if (-not $usageLocation) { throw 'No UsageLocation in CSV or M365.DefaultUsageLocation; required for licensing' }
            $sku = Resolve-LtLicenseSku -SkuPartNumber $skuName   # validates the SKU even in preview
            if ($isPreview) {
                Write-LtLog "Would: assign licence $skuName ($($sku.Available) free) after sync" -Level WHATIF -Subject $sam
                Add-LtResultMessage $result Action "Assigned licence $skuName" -Preview
            }
            else {
                # Licensing waits for Entra Connect; do it for everyone after the AD loop so one sync covers all.
                $needsLicence.Add([pscustomobject]@{ Result = $result; Sku = $skuName; UsageLocation = $usageLocation })
            }
        }
        elseif ($licenseMode -eq 'Group') {
            Add-LtResultMessage $result Action "Licensed through group $($m365.LicenseGroup)" -Preview:$isPreview
        }
    }
    catch {
        Add-LtResultMessage $result Error $_.Exception.Message
        $result.Status = if ($userCreated -or ($result.Actions -contains 'AD account already existed')) { 'Partial' } else { 'Failed' }
    }
}

# ---- Direct licensing (after one sync for the whole batch) -----------------------------------
if ($needsLicence.Count) {
    if ($m365.DirSync.Enabled -and $m365.DirSync.Server) {
        Start-LtDirectorySync @sp -Server $m365.DirSync.Server
    }
    foreach ($item in $needsLicence) {
        $result = $item.Result
        try {
            $cloudUser = Wait-LtCloudUser -UserPrincipalName $result.UserPrincipalName `
                -TimeoutSeconds $m365.DirSync.WaitTimeoutSeconds -PollIntervalSeconds $m365.DirSync.PollIntervalSeconds
            if (-not $cloudUser) {
                throw "Not synced to Entra ID within $($m365.DirSync.WaitTimeoutSeconds)s; re-run the same CSV later to assign the licence"
            }
            Set-LtM365License @sp -CloudUser $cloudUser -SkuPartNumber $item.Sku -UsageLocation $item.UsageLocation
            Add-LtResultMessage $result Action "Licence $($item.Sku) assigned (usage location $($item.UsageLocation))"
        }
        catch {
            Add-LtResultMessage $result Error "Licence: $($_.Exception.Message)"
        }
    }
}

# ---- Final status, report and summary --------------------------------------------------------
foreach ($r in $results) {
    if ($r.Status -ne 'Pending') { continue }
    # In a preview, any error means the real run would fail for this starter.
    $r.Status = if ($r.Errors.Count) { if ($isPreview) { 'Failed' } else { 'Partial' } } elseif ($isPreview) { 'WhatIf' } else { 'Success' }
}

$reportPath = Export-LtReport -Results $results -Directory $config.Logging.ReportPath -Operation 'Onboarding'
$byStatus = $results | Group-Object Status | ForEach-Object { "$($_.Name)=$($_.Count)" }
Write-LtLog ("Finished. {0} starter(s): {1}" -f $results.Count, ($byStatus -join ', ')) -Level $(if ($results.Status -match 'Failed|Partial') { 'WARN' } else { 'SUCCESS' })
Write-LtLog "Report: $reportPath"
Write-LtLog "Log:    $logFile"

if ($passwords.Count) {
    # Deliberately shown on screen only: not logged, not in the report.
    Write-Host ''
    Write-Host 'Initial passwords (shown once; users must change at first logon). Hand over securely:' -ForegroundColor Yellow
    $passwords | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
}

$exitCode = if ($results.Status -match 'Failed|Partial') { 1 } else { 0 }
if ($PassThru) {
    # 'exit' would cut off a downstream pipeline (| Format-Table), so return normally instead.
    $global:LASTEXITCODE = $exitCode
    return $results
}
exit $exitCode
