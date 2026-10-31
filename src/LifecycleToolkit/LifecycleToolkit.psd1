@{
    RootModule        = 'LifecycleToolkit.psm1'
    ModuleVersion     = '1.1.0'
    GUID              = '6f0b8e4a-3c1d-4f6e-9a57-2d8b1c4e7f30'
    Author            = 'zaclehmann'
    Description       = 'Joiner and leaver automation for on-prem Active Directory with Microsoft 365 (hybrid).'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Add-LtGroupMembership',
        'Add-LtM365License',
        'Add-LtResultMessage',
        'Assert-LtCommand',
        'Connect-LtCloud',
        'Convert-LtMailboxToRegular',
        'Convert-LtMailboxToShared',
        'ConvertFrom-LtSecureString',
        'ConvertFrom-LtSizeString',
        'ConvertTo-LtAsciiName',
        'Disable-LtADUser',
        'Enable-LtADUser',
        'Expand-LtTemplate',
        'Export-LtReport',
        'Find-LtADUser',
        'Get-LtADUserByEmployeeId',
        'Get-LtCloudUser',
        'Get-LtCsvValue',
        'Get-LtLogState',
        'Get-LtMailboxInfo',
        'Get-LtUserSnapshot',
        'Import-LtConfig',
        'Import-LtCsv',
        'Initialize-LtLog',
        'Move-LtADUserToOU',
        'Move-LtHomeFolder',
        'New-LtADUser',
        'New-LtHomeFolder',
        'New-LtPassword',
        'New-LtResult',
        'New-LtSamAccountName',
        'Remove-LtGroupMembership',
        'Remove-LtM365License',
        'Resolve-LtLicenseSku',
        'Revoke-LtSignInSession',
        'Save-LtUserSnapshot',
        'Set-LtAccountExpiration',
        'Set-LtM365License',
        'Start-LtDirectorySync',
        'Wait-LtCloudUser',
        'Write-LtLog'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            LicenseUri = 'https://github.com/zaclehmann/AD-M365-user-onboarding-and-offboarding-toolkit-PowerShell-/blob/main/LICENSE'
            ProjectUri = 'https://github.com/zaclehmann/AD-M365-user-onboarding-and-offboarding-toolkit-PowerShell-'
        }
    }
}
