function Import-LtConfig {
    <#
    .SYNOPSIS
        Loads and validates the toolkit configuration (.psd1).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RootPath
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Config file not found: $Path"
    }
    $config = Import-PowerShellDataFile -LiteralPath $Path

    $required = @(
        'Organisation.Name', 'Organisation.UpnSuffix',
        'ActiveDirectory.DefaultUserOU', 'ActiveDirectory.DisabledUsersOU', 'ActiveDirectory.SamAccountNameFormat',
        'Groups', 'HomeFolder', 'M365', 'Offboarding', 'Logging.Path', 'Logging.ReportPath'
    )
    $problems = New-Object System.Collections.Generic.List[string]
    foreach ($key in $required) {
        $node = $config
        foreach ($part in $key.Split('.')) {
            if ($node -is [hashtable] -and $node.ContainsKey($part)) { $node = $node[$part] } else { $node = $null; break }
        }
        if ($null -eq $node -or ($node -is [string] -and [string]::IsNullOrWhiteSpace($node))) {
            $problems.Add("Missing setting '$key'")
        }
    }

    if ($config.M365 -and $config.M365.Enabled) {
        if ($config.M365.LicenseMode -notin 'Group', 'Direct', 'None') {
            $problems.Add("M365.LicenseMode must be Group, Direct or None (got '$($config.M365.LicenseMode)')")
        }
        if ($config.M365.LicenseMode -eq 'Group' -and -not $config.M365.LicenseGroup) {
            $problems.Add('M365.LicenseGroup is required when LicenseMode is Group')
        }
        if ($config.M365.LicenseMode -eq 'Direct' -and -not $config.M365.DefaultLicenseSku) {
            $problems.Add('M365.DefaultLicenseSku is required when LicenseMode is Direct')
        }
    }
    if ($config.HomeFolder -and $config.HomeFolder.Enabled) {
        if (-not $config.HomeFolder.RootPath) { $problems.Add('HomeFolder.RootPath is required when HomeFolder.Enabled') }
        if ($config.HomeFolder.LeaverAction -notin 'Keep', 'Archive') { $problems.Add('HomeFolder.LeaverAction must be Keep or Archive') }
        if ($config.HomeFolder.LeaverAction -eq 'Archive' -and -not $config.HomeFolder.ArchivePath) {
            $problems.Add('HomeFolder.ArchivePath is required when LeaverAction is Archive')
        }
    }
    if ($config.ActiveDirectory.SamAccountNameFormat -and $config.ActiveDirectory.SamAccountNameFormat -notmatch '\{(first|last|f)\}') {
        $problems.Add('ActiveDirectory.SamAccountNameFormat must contain at least one of {first}, {last} or {f}')
    }

    if ($problems.Count) {
        throw ("Invalid config '{0}':`n - {1}" -f $Path, ($problems -join "`n - "))
    }

    if (-not $config.ActiveDirectory.PasswordLength) { $config.ActiveDirectory.PasswordLength = 16 }
    if (-not $config.ActiveDirectory.DepartmentOUs) { $config.ActiveDirectory.DepartmentOUs = @{} }
    if (-not $config.Groups.Baseline) { $config.Groups.Baseline = @() }
    if (-not $config.Groups.Department) { $config.Groups.Department = @{} }
    if (-not $config.Groups.ProtectedOnLeave) { $config.Groups.ProtectedOnLeave = @('Domain Users') }

    foreach ($pair in @(@('Logging', 'Path'), @('Logging', 'ReportPath'), @('Offboarding', 'SnapshotPath'))) {
        $value = $config[$pair[0]][$pair[1]]
        if ($value -and -not [System.IO.Path]::IsPathRooted($value)) {
            $config[$pair[0]][$pair[1]] = [System.IO.Path]::GetFullPath((Join-Path $RootPath $value))
        }
    }
    $config
}

function Import-LtCsv {
    <#
    .SYNOPSIS
        Imports a CSV, checks the required columns exist and trims every value.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$RequiredColumns
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "CSV file not found: $Path" }

    $rows = @(Import-Csv -LiteralPath $Path -Encoding UTF8)
    if ($rows.Count -eq 0) { throw "CSV file '$Path' has no data rows" }

    $columns = $rows[0].PSObject.Properties.Name
    $missing = $RequiredColumns | Where-Object { $_ -notin $columns }
    if ($missing) { throw "CSV file '$Path' is missing required column(s): $($missing -join ', ')" }

    foreach ($row in $rows) {
        foreach ($prop in $row.PSObject.Properties) {
            if ($prop.Value -is [string]) { $prop.Value = $prop.Value.Trim() }
        }
    }
    $rows
}

function Get-LtCsvValue {
    <#
    .SYNOPSIS
        Returns a column value from a CSV row, or $null if the column is missing or empty.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Row, [Parameter(Mandatory)][string]$Column)
    $prop = $Row.PSObject.Properties[$Column]
    if ($prop -and -not [string]::IsNullOrWhiteSpace($prop.Value)) { [string]$prop.Value } else { $null }
}

function Expand-LtTemplate {
    <#
    .SYNOPSIS
        Replaces {Token} placeholders in a template string.
    .EXAMPLE
        Expand-LtTemplate '{first}.{last}' @{ first = 'jane'; last = 'smith' }   # jane.smith
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Template,
        [Parameter(Mandatory, Position = 1)][hashtable]$Values
    )
    $text = $Template
    foreach ($key in $Values.Keys) {
        $text = $text.Replace('{' + $key + '}', [string]$Values[$key])
    }
    $text
}

function ConvertTo-LtAsciiName {
    <#
    .SYNOPSIS
        Lower-cases a name and strips accents and anything that isn't a-z, 0-9 or a hyphen.
    .EXAMPLE
        ConvertTo-LtAsciiName "O'Brien-Nunez"   # obrien-nunez (accents are stripped too)
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name)

    $decomposed = $Name.Normalize([System.Text.NormalizationForm]::FormD)
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $decomposed.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($ch)
        }
    }
    $text = $sb.ToString().ToLowerInvariant()
    $text = $text.Replace([string][char]0x00DF, 'ss').Replace([string][char]0x00F8, 'o').Replace([string][char]0x00E6, 'ae').Replace([string][char]0x0142, 'l')
    ($text -replace '[^a-z0-9-]', '').Trim('-')
}

function New-LtPassword {
    <#
    .SYNOPSIS
        Generates a cryptographically random password with upper, lower, digit and symbol characters.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Generates a value only.')]
    [CmdletBinding()]
    param(
        [ValidateRange(12, 128)][int]$Length = 16,
        [switch]$AsPlainText
    )

    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!@#$%*-_=+?')
    $all = -join $sets
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $next = {
            param([int]$max)
            $buffer = New-Object byte[] 4
            $limit = [uint32]::MaxValue - ([uint32]::MaxValue % [uint32]$max)
            do {
                $rng.GetBytes($buffer)
                $value = [BitConverter]::ToUInt32($buffer, 0)
            } while ($value -ge $limit)
            [int]($value % [uint32]$max)
        }

        $chars = New-Object System.Collections.Generic.List[char]
        foreach ($set in $sets) { $chars.Add($set[(& $next $set.Length)]) }
        while ($chars.Count -lt $Length) { $chars.Add($all[(& $next $all.Length)]) }

        for ($i = $chars.Count - 1; $i -gt 0; $i--) {
            $j = & $next ($i + 1)
            $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
        }
    }
    finally {
        $rng.Dispose()
    }

    if ($AsPlainText) { return -join $chars }

    $secure = New-Object System.Security.SecureString
    foreach ($c in $chars) { $secure.AppendChar($c) }
    $chars.Clear()
    $secure.MakeReadOnly()
    $secure
}

function ConvertFrom-LtSecureString {
    <#
    .SYNOPSIS
        Returns the plain text of a SecureString. Used only to show initial passwords on screen once.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][securestring]$SecureString)
    (New-Object System.Net.NetworkCredential('', $SecureString)).Password
}

function New-LtSamAccountName {
    <#
    .SYNOPSIS
        Builds a unique sAMAccountName from the configured format, adding 2, 3... on a clash.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Generates a value only.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$FirstName,
        [Parameter(Mandatory)][string]$LastName,
        [Parameter(Mandatory)][string]$Format,
        [Parameter(Mandatory)][string]$UpnSuffix,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.HashSet[string]]$Reserved,
        [string]$Server
    )

    $first = ConvertTo-LtAsciiName $FirstName
    $last = ConvertTo-LtAsciiName $LastName
    if (-not $first -or -not $last) {
        throw "Cannot build a username from '$FirstName $LastName': no usable characters after sanitising"
    }
    $base = Expand-LtTemplate $Format @{ first = $first; last = $last; f = $first.Substring(0, 1) }
    $base = $base.ToLowerInvariant().Trim('.', '-')

    $adParams = @{}
    if ($Server) { $adParams.Server = $Server }

    for ($n = 1; $n -lt 100; $n++) {
        $suffix = if ($n -eq 1) { '' } else { [string]$n }
        $stem = $base.Substring(0, [Math]::Min($base.Length, 20 - $suffix.Length)).TrimEnd('.', '-')
        $candidate = $stem + $suffix

        if ($Reserved.Contains($candidate)) { continue }
        $upn = "$candidate@$UpnSuffix"
        $existing = Get-ADUser -Filter "SamAccountName -eq '$candidate' -or UserPrincipalName -eq '$upn'" @adParams
        if ($existing) { continue }

        [void]$Reserved.Add($candidate)
        return $candidate
    }
    throw "Could not find a free username for '$FirstName $LastName' (tried $base .. ${base}99)"
}

function Assert-LtCommand {
    <#
    .SYNOPSIS
        Throws a helpful error if a required command (and so its module) is not available.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Name,
        [Parameter(Mandatory)][string]$Module,
        [string]$InstallHint
    )
    $missing = $Name | Where-Object { -not (Get-Command -Name $_ -ErrorAction SilentlyContinue) }
    if ($missing) {
        $hint = if ($InstallHint) { " $InstallHint" } else { '' }
        throw "Module '$Module' is required (missing: $($missing -join ', ')).$hint"
    }
}
