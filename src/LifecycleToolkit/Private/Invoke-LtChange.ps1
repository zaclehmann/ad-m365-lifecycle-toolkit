function Invoke-LtChange {
    <#
    .SYNOPSIS
        Runs one state-changing action through the caller's ShouldProcess and logs the outcome.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Uses the caller''s $PSCmdlet.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Management.Automation.PSCmdlet]$Cmdlet,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [string]$Subject
    )

    if ($WhatIfPreference) {
        Write-LtLog "Would: $Action -> $Target" -Level WHATIF -Subject $Subject
    }
    elseif ($Cmdlet.ShouldProcess($Target, $Action)) {
        & $ScriptBlock
        Write-LtLog "$Action -> $Target" -Level SUCCESS -Subject $Subject
    }
    else {
        Write-LtLog "Not confirmed, skipped: $Action -> $Target" -Level WARN -Subject $Subject
    }
}
