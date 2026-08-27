#requires -Version 5.1
<#
  Pester 5. Asserts the shape of the applied-change journal and that the
  pipeline never touched a protected service.

  Install-Module Pester -Force -SkipPublisherCheck -Scope CurrentUser
  Invoke-Pester .\tests\Journal.Tests.ps1 -Output Detailed

  Override the journal location with $env:SOVEREIGN_UNDO_JSON.
#>

BeforeDiscovery {
    $script:UndoPath = if ($env:SOVEREIGN_UNDO_JSON) { $env:SOVEREIGN_UNDO_JSON } else { 'C:\Backups\sovereign-undo.json' }
    $script:HasUndo  = Test-Path -LiteralPath $script:UndoPath
    $script:Raw      = ''
    $script:Entries  = @()
    if ($script:HasUndo) {
        $script:Raw     = Get-Content -LiteralPath $script:UndoPath -Raw -Encoding UTF8
        $script:Entries = @($script:Raw | ConvertFrom-Json)
    }
    $script:RegEntries  = @($script:Entries | Where-Object { "$($_.Kind)" -eq 'registry' })
    $script:SvcEntries  = @($script:Entries | Where-Object { "$($_.Kind)" -eq 'service' })
    $script:TaskEntries = @($script:Entries | Where-Object { "$($_.Kind)" -eq 'task' })
    $script:EnvEntries  = @($script:Entries | Where-Object { "$($_.Kind)" -eq 'env' })
    $script:DirEntries  = @($script:Entries | Where-Object { "$($_.Kind)" -eq 'folder' })
}

Describe 'undo journal file' -Skip:(-not $script:HasUndo) {

    It 'parses as a non-empty JSON array' {
        $script:Entries.Count | Should -BeGreaterThan 0
    }

    It 'contains only known entry kinds' {
        $allowed = @('registry','service','task','env','folder')
        foreach ($e in $script:Entries) {
            $allowed | Should -Contain "$($e.Kind)"
        }
    }

    It 'accounts for every entry in exactly one kind bucket' {
        $sum = $script:RegEntries.Count + $script:SvcEntries.Count + $script:TaskEntries.Count +
               $script:EnvEntries.Count + $script:DirEntries.Count
        $sum | Should -Be $script:Entries.Count
    }
}

Describe 'registry entries' -Skip:(-not $script:HasUndo) {

    It 'carries Path, Name, HadValue and KeyExisted: <_.Path>\<_.Name>' -ForEach $script:RegEntries {
        $names = $_.PSObject.Properties.Name
        $names | Should -Contain 'Path'
        $names | Should -Contain 'Name'
        $names | Should -Contain 'HadValue'
        $names | Should -Contain 'KeyExisted'
        "$($_.Path)" | Should -Not -BeNullOrEmpty
        "$($_.Name)" | Should -Not -BeNullOrEmpty
    }

    It 'records OldValue whenever HadValue is true' -ForEach $script:RegEntries {
        if ([bool]$_.HadValue) {
            $_.PSObject.Properties.Name | Should -Contain 'OldValue'
        }
    }

    It 'has no duplicate Path\Name pair' {
        $keys = @($script:RegEntries | ForEach-Object { "$($_.Path)\$($_.Name)" })
        $unique = @($keys | Sort-Object -Unique)
        $unique.Count | Should -Be $keys.Count
    }

    It 'points at a key that still exists: <_.Path>' -ForEach $script:RegEntries {
        Test-Path -LiteralPath "$($_.Path)" | Should -BeTrue
    }
}

Describe 'service entries' -Skip:(-not $script:HasUndo) {

    It 'records a restorable start mode: <_.Name>' -ForEach $script:SvcEntries {
        $names = $_.PSObject.Properties.Name
        $names | Should -Contain 'OldStartMode'
        $names | Should -Contain 'WasRunning'
        @('Auto','Automatic','Manual','Disabled','Boot','System') | Should -Contain "$($_.OldStartMode)"
    }
}

Describe 'task entries' -Skip:(-not $script:HasUndo) {

    It 'records Path, Name and OldState: <_.Name>' -ForEach $script:TaskEntries {
        $names = $_.PSObject.Properties.Name
        $names | Should -Contain 'Path'
        $names | Should -Contain 'Name'
        $names | Should -Contain 'OldState'
        "$($_.OldState)" | Should -Not -Be 'Disabled'
    }
}

Describe 'env and folder entries' -Skip:(-not $script:HasUndo) {

    It 'env entry records Name and HadValue: <_.Name>' -ForEach $script:EnvEntries {
        $names = $_.PSObject.Properties.Name
        $names | Should -Contain 'Name'
        $names | Should -Contain 'HadValue'
    }

    It 'folder entry points at a path that exists: <_.Path>' -ForEach $script:DirEntries {
        Test-Path -LiteralPath "$($_.Path)" | Should -BeTrue
    }
}

Describe 'protected services were never touched' -Skip:(-not $script:HasUndo) {

    It 'no journal entry names a protected service' {
        foreach ($name in 'wuauserv','WinDefend','mpssvc','SecurityHealthService','WdNisSvc') {
            @($script:SvcEntries | Where-Object { "$($_.Name)" -eq $name }).Count | Should -Be 0
        }
    }

    It 'the raw journal text mentions no protected service' {
        $script:Raw | Should -Not -Match 'wuauserv|WinDefend|mpssvc|WdNisSvc'
    }
}

Describe 'live security invariants' {

    It 'Windows Update start type is not Disabled' {
        # Status is deliberately not asserted: wuauserv is demand-start and
        # Windows stops it when idle, so Stopped is normal and is not drift.
        $svc = Get-Service -Name wuauserv -ErrorAction SilentlyContinue
        $svc | Should -Not -BeNullOrEmpty
        "$($svc.StartType)" | Should -Not -Be 'Disabled'
    }

    It 'Defender antivirus is enabled' {
        (Get-MpComputerStatus).AntivirusEnabled | Should -BeTrue
    }

    It 'all three firewall profiles are enabled' {
        foreach ($p in @(Get-NetFirewallProfile)) { [bool]$p.Enabled | Should -BeTrue }
    }

    It 'telemetry services remain disabled' {
        foreach ($n in 'DiagTrack','dmwappushservice') {
            $cim = Get-CimInstance -ClassName Win32_Service -Filter ("Name='{0}'" -f $n)
            "$($cim.StartMode)" | Should -Be 'Disabled'
        }
    }
}
