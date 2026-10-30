# Lifecycle toolkit configuration.
# Loaded with Import-PowerShellDataFile: literals only, no code is executed.
# Relative paths are resolved against the toolkit root folder.
@{
    Organisation    = @{
        Name      = 'Contoso'
        UpnSuffix = 'contoso.com'          # user@<UpnSuffix>; must be a verified domain in M365
    }

    ActiveDirectory = @{
        Server                = ''         # Optional DC to target (keeps every step on one DC). Blank = auto.
        DefaultUserOU         = 'OU=Users,OU=Contoso,DC=contoso,DC=local'
        DisabledUsersOU       = 'OU=Disabled Users,OU=Contoso,DC=contoso,DC=local'

        # Department (CSV value) -> OU. Unmapped departments fall back to DefaultUserOU with a warning.
        DepartmentOUs         = @{
            'IT'      = 'OU=IT,OU=Users,OU=Contoso,DC=contoso,DC=local'
            'Finance' = 'OU=Finance,OU=Users,OU=Contoso,DC=contoso,DC=local'
            'Sales'   = 'OU=Sales,OU=Users,OU=Contoso,DC=contoso,DC=local'
        }

        # Tokens: {first} {last} {f} (first initial). Result is lower-cased, ASCII only, max 20 chars.
        SamAccountNameFormat  = '{first}.{last}'
        PasswordLength        = 16
        ChangePasswordAtLogon = $true
        HideFromGalOnLeave    = $true      # Sets msExchHideFromAddressLists (needs Exchange schema attributes in AD)
    }

    Groups          = @{
        Baseline         = @('GG_AllStaff')
        Department       = @{
            'IT'      = @('GG_IT', 'GG_IT_Helpdesk')
            'Finance' = @('GG_Finance', 'GG_Finance_Share_RW')
            'Sales'   = @('GG_Sales', 'GG_CRM_Users')
        }
        # Never removed during offboarding.
        ProtectedOnLeave = @('Domain Users')
    }

    HomeFolder      = @{
        Enabled      = $true
        RootPath     = '\\FS01\Home$'
        DriveLetter  = 'H:'
        AccessRights = 'Modify'            # FileSystemRights granted to the user on their folder
        LeaverAction = 'Keep'              # Keep | Archive
        ArchivePath  = '\\FS01\HomeArchive$'
    }

    M365            = @{
        Enabled               = $true
        TenantId              = '00000000-0000-0000-0000-000000000000'
        Organization          = 'contoso.onmicrosoft.com'  # Used by Connect-ExchangeOnline
        # App-only auth (recommended for scheduled runs). Leave blank for interactive sign-in.
        ClientId              = ''
        CertificateThumbprint = ''

        # Group  : add the user to LicenseGroup (group-based licensing in Entra)
        # Direct : wait for sync, then assign DefaultLicenseSku with Microsoft Graph
        # None   : don't touch licensing
        LicenseMode           = 'Group'
        LicenseGroup          = 'LIC_M365_E3'
        DefaultLicenseSku     = 'SPE_E3'   # SkuPartNumber, see Get-MgSubscribedSku
        DefaultUsageLocation  = 'GB'

        DirSync               = @{
            Enabled             = $true
            Server              = 'AADC01' # Entra Connect server; Start-ADSyncSyncCycle runs there
            WaitTimeoutSeconds  = 900
            PollIntervalSeconds = 30
        }
    }

    Offboarding     = @{
        ConvertMailboxToShared   = $true
        GrantManagerMailboxAccess = $true
        SetAutoReply             = $true
        # Tokens: {DisplayName} {Organisation} {ManagerName} {ManagerEmail}
        AutoReplyMessage         = 'Thank you for your email. {DisplayName} no longer works at {Organisation}. Please contact {ManagerName} ({ManagerEmail}) instead.'
        RevokeSessions           = $true
        RemoveLicenses           = $true
        SharedMailboxSizeLimitGB = 50      # Above this a shared mailbox still needs a licence
        SnapshotPath             = 'output\snapshots'
    }

    Logging         = @{
        Path          = 'logs'
        ReportPath    = 'output\reports'
        RetentionDays = 90
    }
}
