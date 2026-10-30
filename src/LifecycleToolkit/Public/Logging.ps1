$script:LtLog = @{
    File   = $null
    RunId  = $null
    Counts = @{ INFO = 0; SUCCESS = 0; WARN = 0; ERROR = 0; WHATIF = 0 }
}

$script:LtUtf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Initialize-LtLog {
    <#
    .SYNOPSIS
        Starts a new log file for this run and removes log files older than RetentionDays.
    .OUTPUTS
        The full path of the new log file.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$Operation,
        [int]$RetentionDays = 0
    )

    # Logging must still happen under -WhatIf, so use .NET instead of cmdlets that honour ShouldProcess.
    [void][System.IO.Directory]::CreateDirectory($Directory)

    if ($RetentionDays -gt 0) {
        $cutoff = (Get-Date).AddDays(-$RetentionDays)
        Get-ChildItem -Path $Directory -Filter "$Operation*.log" -File |
            Where-Object { $_.LastWriteTime -lt $cutoff } |
            ForEach-Object { [System.IO.File]::Delete($_.FullName) }
    }

    $script:LtLog.RunId = [guid]::NewGuid().ToString('N').Substring(0, 8)
    foreach ($key in @($script:LtLog.Counts.Keys)) { $script:LtLog.Counts[$key] = 0 }
    $name = '{0}_{1}_{2}.log' -f $Operation, (Get-Date -Format 'yyyyMMdd-HHmmss'), $script:LtLog.RunId
    $script:LtLog.File = Join-Path $Directory $name
    $script:LtLog.File
}

function Get-LtLogState {
    <#
    .SYNOPSIS
        Returns the current log file, run ID and per-level message counts.
    #>
    [CmdletBinding()]
    param()
    [pscustomobject]@{
        File   = $script:LtLog.File
        RunId  = $script:LtLog.RunId
        Counts = $script:LtLog.Counts.Clone()
    }
}

function Write-LtLog {
    <#
    .SYNOPSIS
        Writes one timestamped line to the console (coloured) and to the run's log file.
    .EXAMPLE
        Write-LtLog 'Created AD user' -Level SUCCESS -Subject 'jane.smith'
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Coloured operator console output is intended.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO', 'SUCCESS', 'WARN', 'ERROR', 'WHATIF')][string]$Level = 'INFO',
        [string]$Subject
    )

    $prefix = if ($Subject) { "[$Subject] " } else { '' }
    $line = '{0} [{1,-7}] {2}{3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $prefix, $Message
    $script:LtLog.Counts[$Level]++

    if ($script:LtLog.File) {
        [System.IO.File]::AppendAllText($script:LtLog.File, $line + [Environment]::NewLine, $script:LtUtf8NoBom)
    }

    $colour = switch ($Level) {
        'SUCCESS' { 'Green' }
        'WARN'    { 'Yellow' }
        'ERROR'   { 'Red' }
        'WHATIF'  { 'Cyan' }
        default   { 'Gray' }
    }
    Write-Host $line -ForegroundColor $colour
}

function New-LtResult {
    <#
    .SYNOPSIS
        Creates the per-user result record that ends up in the run report.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [int]$Row
    )
    [pscustomobject]@{
        Row               = $Row
        Input             = $Name
        SamAccountName    = $null
        UserPrincipalName = $null
        Status            = 'Pending'
        Actions           = New-Object System.Collections.Generic.List[string]
        Warnings          = New-Object System.Collections.Generic.List[string]
        Errors            = New-Object System.Collections.Generic.List[string]
        InitialPassword   = $null   # SecureString; never exported
    }
}

function Add-LtResultMessage {
    <#
    .SYNOPSIS
        Records an action, warning or error against a result. Warnings and errors are also logged.
    .PARAMETER Preview
        Marks an action as previewed only (prefixes it with 'WhatIf: ' in the report).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Result,
        [Parameter(Mandatory)][ValidateSet('Action', 'Warning', 'Error')][string]$Type,
        [Parameter(Mandatory)][string]$Message,
        [switch]$Preview,
        [switch]$NoLog
    )
    $subject = if ($Result.SamAccountName) { $Result.SamAccountName } else { $Result.Input }
    switch ($Type) {
        'Action'  { $Result.Actions.Add($(if ($Preview) { "WhatIf: $Message" } else { $Message })) }
        'Warning' { $Result.Warnings.Add($Message); if (-not $NoLog) { Write-LtLog $Message -Level WARN -Subject $subject } }
        'Error'   { $Result.Errors.Add($Message);   if (-not $NoLog) { Write-LtLog $Message -Level ERROR -Subject $subject } }
    }
}

function Export-LtReport {
    <#
    .SYNOPSIS
        Writes the run's per-user results to CSV. Passwords are never included.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Results,
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$Operation
    )
    [void][System.IO.Directory]::CreateDirectory($Directory)
    $path = Join-Path $Directory ('{0}_{1}_{2}.csv' -f $Operation, (Get-Date -Format 'yyyyMMdd-HHmmss'), $script:LtLog.RunId)

    $rows = foreach ($r in $Results) {
        [pscustomobject]@{
            Row               = $r.Row
            Input             = $r.Input
            SamAccountName    = $r.SamAccountName
            UserPrincipalName = $r.UserPrincipalName
            Status            = $r.Status
            Actions           = $r.Actions -join ' | '
            Warnings          = $r.Warnings -join ' | '
            Errors            = $r.Errors -join ' | '
        }
    }
    $csv = if ($rows) { ($rows | ConvertTo-Csv -NoTypeInformation) -join [Environment]::NewLine } else { '' }
    [System.IO.File]::WriteAllText($path, $csv + [Environment]::NewLine, $script:LtUtf8NoBom)
    $path
}
