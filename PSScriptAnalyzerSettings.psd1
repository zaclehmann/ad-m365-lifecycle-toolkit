@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Coloured console output for the operator is intended (see Write-LtLog).
        'PSAvoidUsingWriteHost'
    )
}
