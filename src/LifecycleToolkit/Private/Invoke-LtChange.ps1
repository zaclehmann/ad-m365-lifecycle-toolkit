function Invoke-LtChange {
    <#
    .SYNOPSIS
        Runs one state-changing action through the caller's ShouldProcess and logs the outcome.
    .DESCRIPTION
        Every change the toolkit makes goes through this function, so -WhatIf and -Confirm
        behave the same everywhere and every change is logged as SUCCESS or WHATIF.
        -Confirm prompts come from the caller's ShouldProcess.
        Returns whatever the script block outputs (nothing when the change was skipped).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Calls ShouldProcess on the caller''s $PSCmdlet, which declares SupportsShouldProcess.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Management.Automation.PSCmdlet]$Cmdlet,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [string]$Subject
    )

    # $WhatIfPreference is the calling function's (set by its -WhatIf). Handle it here rather than
    # through ShouldProcess so the console shows one WHATIF line instead of two.
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
