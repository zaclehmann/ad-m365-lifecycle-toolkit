function Get-LtServerParam {
    param([string]$Server)
    if ($Server) { @{ Server = $Server } } else { @{} }
}
