#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Unit tests for the module's helper functions. Run: Invoke-Pester ./tests

BeforeAll {
    $repoRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repoRoot 'src/LifecycleToolkit/LifecycleToolkit.psd1') -Force

    # Mock needs the command to exist; RSAT isn't installed on CI runners.
    foreach ($name in 'Get-ADUser', 'New-ADUser') {
        if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
            New-Item -Path "function:global:$name" -Value { param($Filter, $Identity, $Properties, $Server, $SearchBase, $SearchScope) } | Out-Null
        }
    }
}

Describe 'ConvertTo-LtAsciiName' {
    It 'turns "<In>" into "<Out>"' -ForEach @(
        @{ In = 'Jane'; Out = 'jane' }
        @{ In = "O'Brien"; Out = 'obrien' }
        @{ In = 'José'; Out = 'jose' }
        @{ In = 'Núñez-García'; Out = 'nunez-garcia' }
        @{ In = 'Strauß'; Out = 'strauss' }
        @{ In = 'van der Berg'; Out = 'vanderberg' }
        @{ In = ' -Smith- '; Out = 'smith' }
    ) {
        ConvertTo-LtAsciiName $In | Should -BeExactly $Out
    }
}

Describe 'Expand-LtTemplate' {
    It 'replaces every token' {
        Expand-LtTemplate '{first}.{last}@{first}' @{ first = 'jane'; last = 'smith' } | Should -Be 'jane.smith@jane'
    }
    It 'leaves unknown tokens alone' {
        Expand-LtTemplate 'Hi {Name}' @{ Other = 'x' } | Should -Be 'Hi {Name}'
    }
}

Describe 'New-LtPassword' {
    It 'returns a SecureString by default' {
        New-LtPassword | Should -BeOfType [securestring]
    }
    It 'meets complexity rules at length <Length>' -ForEach @(@{ Length = 12 }, @{ Length = 16 }, @{ Length = 64 }) {
        $p = New-LtPassword -Length $Length -AsPlainText
        $p.Length | Should -Be $Length
        $p | Should -MatchExactly '[A-Z]'
        $p | Should -MatchExactly '[a-z]'
        $p | Should -Match '[0-9]'
        $p | Should -Match '[^A-Za-z0-9]'
        $p | Should -Not -MatchExactly '[0OIl1]'
    }
    It 'does not repeat' {
        $set = 1..50 | ForEach-Object { New-LtPassword -AsPlainText } | Select-Object -Unique
        @($set).Count | Should -Be 50
    }
    It 'round-trips through ConvertFrom-LtSecureString' {
        $plain = ConvertFrom-LtSecureString (New-LtPassword -Length 20)
        $plain.Length | Should -Be 20
        $plain | Should -MatchExactly '[A-Z]'
    }
    It 'rejects lengths under 12' {
        { New-LtPassword -Length 8 } | Should -Throw
    }
}

Describe 'ConvertFrom-LtSizeString' {
    It 'parses an EXO size string' {
        ConvertFrom-LtSizeString '1.2 GB (1,288,490,188 bytes)' | Should -Be 1288490188
    }
    It 'returns 0 for anything else' {
        ConvertFrom-LtSizeString 'Unlimited' | Should -Be 0
    }
}

Describe 'New-LtSamAccountName' {
    BeforeEach {
        $reserved = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $common = @{ Format = '{first}.{last}'; UpnSuffix = 'contoso.com'; Reserved = $reserved }
    }

    It 'uses the format when the name is free' {
        Mock Get-ADUser -ModuleName LifecycleToolkit { $null }
        New-LtSamAccountName -FirstName 'José' -LastName "O'Brien" @common | Should -Be 'jose.obrien'
    }
    It 'adds a number when the name is taken' {
        Mock Get-ADUser -ModuleName LifecycleToolkit { if ($Filter -match "'jane\.smith'") { [pscustomobject]@{ SamAccountName = 'jane.smith' } } }
        New-LtSamAccountName -FirstName 'Jane' -LastName 'Smith' @common | Should -Be 'jane.smith2'
    }
    It 'does not hand out a name reserved earlier in the run' {
        Mock Get-ADUser -ModuleName LifecycleToolkit { $null }
        New-LtSamAccountName -FirstName 'Jane' -LastName 'Smith' @common | Should -Be 'jane.smith'
        New-LtSamAccountName -FirstName 'Jane' -LastName 'Smith' @common | Should -Be 'jane.smith2'
    }
    It 'keeps within 20 characters, including the number' {
        Mock Get-ADUser -ModuleName LifecycleToolkit { if ($Filter -match "'christopher\.montgome'") { 'taken' } }
        $name = New-LtSamAccountName -FirstName 'Christopher' -LastName 'Montgomery-Smythe' @common
        $name | Should -Be 'christopher.montgom2'
        $name.Length | Should -BeLessOrEqual 20
    }
    It 'supports other formats' {
        Mock Get-ADUser -ModuleName LifecycleToolkit { $null }
        $common.Format = '{f}{last}'
        New-LtSamAccountName -FirstName 'Jane' -LastName 'Smith' @common | Should -Be 'jsmith'
    }
    It 'throws when nothing usable is left' {
        Mock Get-ADUser -ModuleName LifecycleToolkit { $null }
        { New-LtSamAccountName -FirstName '!!!' -LastName 'Smith' @common } | Should -Throw '*no usable characters*'
    }
}

Describe 'New-LtADUser' {
    It 'creates nothing under -WhatIf' {
        Mock Get-ADUser -ModuleName LifecycleToolkit { $null }
        Mock New-ADUser -ModuleName LifecycleToolkit { }
        $params = @{
            SamAccountName = 'jane.smith'; UserPrincipalName = 'jane.smith@contoso.com'; GivenName = 'Jane'; Surname = 'Smith'
            Path = 'OU=Users,DC=contoso,DC=local'; Password = (New-LtPassword); EmployeeId = 'E1'
        }
        New-LtADUser @params -WhatIf 6>$null
        Should -Invoke New-ADUser -ModuleName LifecycleToolkit -Times 0
    }
    It 'uses "Name (username)" as the CN when a namesake is already in the OU' {
        Mock Get-ADUser -ModuleName LifecycleToolkit { [pscustomobject]@{ Name = 'Jane Smith' } }
        Mock New-ADUser -ModuleName LifecycleToolkit { }
        $params = @{
            SamAccountName = 'jane.smith2'; UserPrincipalName = 'jane.smith2@contoso.com'; GivenName = 'Jane'; Surname = 'Smith'
            Path = 'OU=Users,DC=contoso,DC=local'; Password = (New-LtPassword); EmployeeId = 'E1'
        }
        New-LtADUser @params -Confirm:$false 6>$null
        Should -Invoke New-ADUser -ModuleName LifecycleToolkit -Times 1 -ParameterFilter { $Name -eq 'Jane Smith (jane.smith2)' }
    }
}

Describe 'Import-LtConfig' {
    BeforeAll {
        $repoRoot = Split-Path $PSScriptRoot -Parent
        $shipped = Join-Path $repoRoot 'config/toolkit.config.psd1'
    }

    It 'loads the shipped config and resolves relative paths' {
        $config = Import-LtConfig -Path $shipped -RootPath $repoRoot
        $config.Organisation.UpnSuffix | Should -Be 'contoso.com'
        [System.IO.Path]::IsPathRooted($config.Logging.Path) | Should -BeTrue
        $config.Logging.Path | Should -BeLike "$repoRoot*"
    }
    It 'reports every problem at once' {
        $bad = Join-Path $TestDrive 'bad.psd1'
        (Get-Content $shipped -Raw).Replace("UpnSuffix = 'contoso.com'", "UpnSuffix = ''").Replace("LicenseMode           = 'Group'", "LicenseMode           = 'Magic'") |
            Set-Content $bad
        { Import-LtConfig -Path $bad -RootPath $TestDrive } | Should -Throw -ExpectedMessage '*Organisation.UpnSuffix*LicenseMode*'
    }
    It 'throws a clear error when the file is missing' {
        { Import-LtConfig -Path (Join-Path $TestDrive 'nope.psd1') -RootPath $TestDrive } | Should -Throw '*not found*'
    }
}

Describe 'Import-LtCsv' {
    It 'trims values' {
        $csv = Join-Path $TestDrive 'a.csv'
        "FirstName,LastName`n  Jane ,Smith  " | Set-Content $csv
        $row = Import-LtCsv -Path $csv -RequiredColumns FirstName, LastName
        $row.FirstName | Should -BeExactly 'Jane'
        $row.LastName | Should -BeExactly 'Smith'
    }
    It 'names the missing columns' {
        $csv = Join-Path $TestDrive 'b.csv'
        "FirstName`nJane" | Set-Content $csv
        { Import-LtCsv -Path $csv -RequiredColumns FirstName, LastName, EmployeeId } | Should -Throw '*LastName, EmployeeId*'
    }
    It 'rejects an empty file' {
        $csv = Join-Path $TestDrive 'c.csv'
        'FirstName,LastName' | Set-Content $csv
        { Import-LtCsv -Path $csv -RequiredColumns FirstName } | Should -Throw '*no data rows*'
    }
}

Describe 'Write-LtLog' {
    It 'writes to the log file even under -WhatIf' {
        $file = Initialize-LtLog -Directory (Join-Path $TestDrive 'logs') -Operation 'Test'
        $WhatIfPreference = $true
        Write-LtLog 'hello' -Level WARN -Subject 'jane' 6>$null
        $WhatIfPreference = $false
        Get-Content $file | Should -Match '\[WARN   \] \[jane\] hello$'
    }
}

Describe 'Get-LtUserSnapshot' {
    BeforeAll {
        $dir = Join-Path $TestDrive 'snaps'
        New-Item -ItemType Directory -Path $dir | Out-Null
        foreach ($stamp in '20261103-083002123', '20261101-090000000', '20261105-120000000') {
            @{ SamAccountName = 'tom.baker'; ObjectGUID = [guid]::NewGuid().ToString(); DistinguishedName = 'CN=Tom Baker,OU=Users,DC=x'; Stamp = $stamp } |
                ConvertTo-Json | Set-Content (Join-Path $dir "tom.baker_$stamp.json")
        }
        # Must not match tom.baker: a different user whose name starts the same way.
        @{ SamAccountName = 'tom.baker2'; ObjectGUID = 'x'; DistinguishedName = 'y'; Stamp = 'other' } |
            ConvertTo-Json | Set-Content (Join-Path $dir 'tom.baker2_20261001-000000000.json')
    }
    It 'picks the earliest snapshot for the user' {
        (Get-LtUserSnapshot -Directory $dir -SamAccountName 'tom.baker').Stamp | Should -Be '20261101-090000000'
    }
    It 'throws when there is none' {
        { Get-LtUserSnapshot -Directory $dir -SamAccountName 'nobody' } | Should -Throw '*No snapshot*'
    }
    It 'rejects a file that is not a snapshot' {
        $bad = Join-Path $TestDrive 'bad.json'
        '{ "foo": 1 }' | Set-Content $bad
        { Get-LtUserSnapshot -Path $bad } | Should -Throw '*has no SamAccountName*'
    }
}
