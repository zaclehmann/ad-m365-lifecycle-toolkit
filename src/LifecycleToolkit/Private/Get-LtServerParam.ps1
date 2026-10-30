function Get-LtServerParam {
    # Splat for AD cmdlets: pins every call to one DC when ActiveDirectory.Server is set.
    param([string]$Server)
    if ($Server) { @{ Server = $Server } } else { @{} }
}
