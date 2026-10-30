#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# End-to-end tests: run the real entry scripts against the in-memory fake directory/tenant.

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    $onboard = Join-Path $repoRoot 'Invoke-Onboarding.ps1'
    $offboard = Join-Path $repoRoot 'Invoke-Offboarding.ps1'
    $starters = Join-Path $repoRoot 'samples/new-starters.csv'
    $leavers = Join-Path $repoRoot 'samples/leavers.csv'
    . (Join-Path $PSScriptRoot 'Fakes/FakeEnvironment.ps1')

    function New-TestRun {
        param([string]$LicenseMode = 'Group')
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        [void][System.IO.Directory]::CreateDirectory($dir)
        Initialize-FakeDirectory
        [pscustomobject]@{ Dir = $dir; Config = (New-FakeConfig -Directory $dir -LicenseMode $LicenseMode) }
    }
    function Get-RunLog($Run) { Get-ChildItem (Join-Path $Run.Dir 'logs') -Filter *.log | Sort-Object LastWriteTime | Select-Object -Last 1 | Get-Content -Raw }
}

Describe 'Onboarding' {
    Context '-WhatIf' {
        BeforeAll {
            $run = New-TestRun
            $results = & $onboard -CsvPath $starters -ConfigPath $run.Config -WhatIf -PassThru 6>$null
            $exit = $LASTEXITCODE
        }
        It 'makes no changes' { $FakeEnv.Changes | Should -BeNullOrEmpty }
        It 'creates no home folders' { Get-ChildItem (Join-Path $run.Dir 'home') | Should -BeNullOrEmpty }
        It 'marks every starter WhatIf and exits 0' {
            $results.Status | Should -Be @('WhatIf', 'WhatIf', 'WhatIf')
            $exit | Should -Be 0
        }
        It 'previews unique usernames, including in-run clashes' {
            $results.SamAccountName | Should -Be @('jane.smith2', 'jose.obrien', 'priya.patel')
        }
        It 'logs WHATIF lines' { Get-RunLog $run | Should -Match '\[WHATIF \] \[jane\.smith2\] Would: Create AD user' }
    }

    Context 'real run' {
        BeforeAll {
            $run = New-TestRun
            $results = & $onboard -CsvPath $starters -ConfigPath $run.Config -PassThru 6>$null
            $exit = $LASTEXITCODE
        }
        It 'succeeds for every starter' {
            $results.Status | Should -Be @('Success', 'Success', 'Success')
            $exit | Should -Be 0
        }
        It 'creates the user in the department OU with the manager set' {
            $jose = Get-ADUser -Identity 'jose.obrien'
            $jose.DistinguishedName | Should -Be "CN=José O'Brien,OU=IT,OU=Users,OU=Contoso,DC=contoso,DC=local"
            $jose.Manager | Should -BeLike 'CN=Sara Khan,*'
            $jose.EmployeeID | Should -Be 'E10232'
        }
        It 'adds baseline, department, CSV and licence groups' {
            $groups = (Get-ADUser -Identity 'jose.obrien').MemberOf | ForEach-Object { ($_ -split ',')[0] -replace 'CN=' }
            $groups | Sort-Object | Should -Be @('GG_AllStaff', 'GG_IT', 'GG_IT_Helpdesk', 'GG_Remote_Desktop', 'GG_VPN_Users', 'LIC_M365_E3')
        }
        It 'creates the home folder and sets HomeDirectory' {
            $homePath = Join-Path (Join-Path $run.Dir 'home') 'priya.patel'
            Test-Path $homePath | Should -BeTrue
            (Get-ADUser -Identity 'priya.patel').HomeDirectory | Should -Be $homePath
        }
        It 'never writes passwords to the log or report' {
            $log = Get-RunLog $run
            $report = Get-ChildItem (Join-Path $run.Dir 'reports') | Get-Content -Raw
            foreach ($r in $results) {
                $plain = [System.Net.NetworkCredential]::new('', $r.InitialPassword).Password
                $plain | Should -Not -BeNullOrEmpty
                $log.Contains($plain) | Should -BeFalse
                $report.Contains($plain) | Should -BeFalse
            }
        }
        It 'is idempotent: a re-run changes nothing in AD' {
            $FakeEnv.Changes.Clear()
            $again = & $onboard -CsvPath $starters -ConfigPath $run.Config -PassThru 6>$null
            $again.Status | Should -Be @('Success', 'Success', 'Success')
            $FakeEnv.Changes | Should -BeNullOrEmpty
            $again.SamAccountName | Should -Be @('jane.smith2', 'jose.obrien', 'priya.patel')
        }
    }

    Context 'invalid rows' {
        BeforeAll {
            $run = New-TestRun
            $csv = Join-Path $run.Dir 'bad.csv'
            @(
                'FirstName,LastName,EmployeeId,Department,Groups,UsageLocation'
                'Ann,Lee,E20001,Finance,GG_Typo_Group,GB'
                ',NoFirst,E20002,IT,,'
                'Bob,Dup,E20003,IT,,'
                'Bob,Dup,E20003,IT,,'
                'Cat,Bad,E20004,IT,,GBR'
                'Dan,Ok,E20005,Marketing,,US'
            ) | Set-Content $csv
            $results = & $onboard -CsvPath $csv -ConfigPath $run.Config -PassThru 6>$null
            $exit = $LASTEXITCODE
        }
        It 'fails bad rows, carries on with good ones and exits 1' {
            $results.Status | Should -Be @('Partial', 'Failed', 'Failed', 'Failed', 'Failed', 'Success')
            $exit | Should -Be 1
        }
        It 'explains why' {
            $results[0].Errors | Should -Contain "Group 'GG_Typo_Group' could not be added"
            $results[1].Errors[0] | Should -BeLike '*FirstName is empty*'
            $results[2].Errors[0] | Should -BeLike '*appears more than once*'
            $results[4].Errors[0] | Should -BeLike '*2-letter country code*'
            $results[5].Warnings[0] | Should -BeLike "No OU mapped for department 'Marketing'*"
        }
    }

    Context 'Direct licence mode' {
        BeforeAll {
            $run = New-TestRun -LicenseMode Direct
            $results = & $onboard -CsvPath $starters -ConfigPath $run.Config -PassThru 6>$null
        }
        It 'syncs once, sets usage location and assigns the licence' {
            @($FakeEnv.Changes -match '^DeltaSync').Count | Should -Be 1
            $cloud = $FakeEnv.CloudUsers['jane.smith2@contoso.com']
            $cloud.UsageLocation | Should -Be 'GB'
            $cloud.AssignedLicenses.SkuId | Should -Contain '05e9a617-0261-4cee-bb44-138d3ef5d965'
        }
        It 'reports Partial when no licences are free' {
            $results[2].Status | Should -Be 'Partial'
            $results[2].Errors[0] | Should -BeLike '*No free SPE_E5 licences*'
        }
        It 'does not add the licence group' {
            ((Get-ADUser -Identity 'jane.smith2').MemberOf -join ';') | Should -Not -Match 'LIC_M365_E3'
        }
    }
}

Describe 'Offboarding' {
    Context '-WhatIf' {
        BeforeAll {
            $run = New-TestRun
            $results = & $offboard -CsvPath $leavers -ConfigPath $run.Config -WhatIf -PassThru 6>$null
        }
        It 'makes no changes and writes no snapshot' {
            $FakeEnv.Changes | Should -BeNullOrEmpty
            Test-Path (Join-Path $run.Dir 'snapshots') | Should -BeFalse
            (Get-ADUser -Identity 'tom.baker').Enabled | Should -BeTrue
        }
        It 'marks preview actions in the report' {
            $results.Status | Should -Be @('WhatIf', 'WhatIf')
            $results[0].Actions | Should -Contain 'WhatIf: Password reset, account disabled, description set'
        }
    }

    Context 'real run' {
        BeforeAll {
            $run = New-TestRun
            $results = & $offboard -CsvPath $leavers -ConfigPath $run.Config -PassThru 6>$null
            $exit = $LASTEXITCODE
            $changes = @($FakeEnv.Changes)
            $index = { param($pattern) for ($i = 0; $i -lt $changes.Count; $i++) { if ($changes[$i] -match $pattern) { return $i } }; -1 }
        }
        It 'succeeds' {
            $results.Status | Should -Be @('Success', 'Success')
            $exit | Should -Be 0
        }
        It 'disables, stamps and moves the account' {
            $tom = Get-ADUser -Identity 'tom.baker'
            $tom.Enabled | Should -BeFalse
            $tom.Description | Should -BeLike 'Leaver * - INC0042117 - by *'
            $tom.msExchHideFromAddressLists | Should -BeTrue
            $tom.DistinguishedName | Should -Be 'CN=Tom Baker,OU=Disabled Users,OU=Contoso,DC=contoso,DC=local'
        }
        It 'removes groups except protected ones' {
            (Get-ADUser -Identity 'tom.baker').MemberOf | Should -Be @('CN=Domain Users,OU=Groups,OU=Contoso,DC=contoso,DC=local')
        }
        It 'converts the mailbox before removing any group (licence safety)' {
            $convert = & $index '^Set-Mailbox tom\.baker'
            $firstRemoval = & $index '^Remove-ADGroupMember .* tom\.baker'
            $convert | Should -BeGreaterThan -1
            $convert | Should -BeLessThan $firstRemoval
        }
        It 'disables before touching the mailbox, and moves OU last' {
            (& $index '^Disable-ADAccount tom') | Should -BeLessThan (& $index '^Set-Mailbox tom')
            $tomChanges = @($changes | Where-Object { $_ -match 'tom\.baker' })
            $tomChanges[-1] | Should -Be 'Move-ADObject tom.baker'
        }
        It 'grants the manager access and sets an auto-reply naming them' {
            $FakeEnv.Mailboxes['tom.baker@contoso.com'].RecipientTypeDetails | Should -Be 'SharedMailbox'
            $FakeEnv.Permissions | Where-Object Identity -eq 'tom.baker@contoso.com' | ForEach-Object User | Should -Be 'mark.jones@contoso.com'
            $FakeEnv.AutoReplies['tom.baker@contoso.com'] | Should -BeLike '*Mark Jones (mark.jones@contoso.com)*'
        }
        It 'uses the CSV delegate and message when given' {
            $FakeEnv.Permissions | Where-Object Identity -eq 'amy.wong@contoso.com' | ForEach-Object User | Should -Be 'sara.khan'
            $FakeEnv.AutoReplies['amy.wong@contoso.com'] | Should -BeLike 'Amy has moved on*'
        }
        It 'keeps the licence on a mailbox over 50 GB' {
            $FakeEnv.CloudUsers['amy.wong@contoso.com'].AssignedLicenses | Should -Not -BeNullOrEmpty
            $results[1].Warnings[0] | Should -BeLike 'Licences kept*'
        }
        It 'saves a snapshot with the original groups' {
            $file = Get-ChildItem (Join-Path $run.Dir 'snapshots') -Filter 'tom.baker_*.json' | Select-Object -First 1
            $snap = Get-Content $file.FullName -Raw | ConvertFrom-Json
            $snap.MemberOf.Count | Should -Be 4
            $snap.Ticket | Should -Be 'INC0042117'
        }
        It 'triggers one delta sync at the end' {
            $changes[-1] | Should -Be 'DeltaSync AADC01'
        }
    }

    Context 'when mailbox conversion fails' {
        BeforeAll {
            $run = New-TestRun
            $global:FakeEnv.FailMailboxConversion = $true
            $results = & $offboard -Identity 'tom.baker' -Ticket 'INC1' -ConfigPath $run.Config -PassThru 6>$null
            $exit = $LASTEXITCODE
        }
        It 'still disables the account' { (Get-ADUser -Identity 'tom.baker').Enabled | Should -BeFalse }
        It 'leaves groups (and so the licence group) in place' {
            $FakeEnv.Changes | Where-Object { $_ -like 'Remove-ADGroupMember*' } | Should -BeNullOrEmpty
            ((Get-ADUser -Identity 'tom.baker').MemberOf -join ';') | Should -Match 'LIC_M365_E3'
        }
        It 'reports Partial and exits 1' {
            $results.Status | Should -Be 'Partial'
            $exit | Should -Be 1
        }
    }

    Context 'unknown user' {
        It 'fails cleanly with exit code 1' {
            $run = New-TestRun
            $results = & $offboard -Identity 'nobody' -Ticket 'INC1' -ConfigPath $run.Config -PassThru 6>$null
            $results.Status | Should -Be 'Failed'
            $results.Errors[0] | Should -BeLike "No AD user found*'nobody'*"
            $LASTEXITCODE | Should -Be 1
            $FakeEnv.Changes | Should -BeNullOrEmpty
        }
    }
}

Describe 'Setup errors' {
    It 'exits 2 when the config is missing' {
        & $onboard -CsvPath $starters -ConfigPath (Join-Path $TestDrive 'missing.psd1') 2>$null 6>$null
        $LASTEXITCODE | Should -Be 2
    }
}
