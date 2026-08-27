#requires -Version 5.1
<#
  Pester 5 و 6.
  يتحقّق من شكل مجلة التغييرات المطبَّقة، ومن أن الخط لم يلمس أي خدمة محمية.
  Asserts the shape of the applied-change journal, and that no protected service was touched.

  Install-Module Pester -Force -SkipPublisherCheck -Scope CurrentUser
  Invoke-Pester .\tests\Journal.Tests.ps1 -Output Detailed
  Invoke-Pester .\tests\Journal.Tests.ps1 -Tag machine   # الثوابت الحيّة وحدها، بلا مجلة

  موقع المجلة يُضبط بـ $env:SOVEREIGN_UNDO_JSON، والافتراضي C:\Backups\sovereign-undo.json

  مرحلتان، لا حالة جلسة واحدة / two phases, not one session state:
    BeforeDiscovery تعمل في مرحلة الاكتشاف. قيمها تُحقن في -ForEach فتصل إلى الاختبارات
    كبيانات، لكن متغيّرات $script: من تلك المرحلة لا تعيش في مرحلة التشغيل. لذلك رأى كل
    اختبار تجميعي مجموعة فارغة: واحد فشل، وخمسة نجحت بلا أي تأكيد، لأن الحلقة على مجموعة
    فارغة تنجح دائماً. الحل: إعادة التحميل في BeforeAll، وتأكيد أن العدد أكبر من صفر في
    أول كل اختبار تجميعي حتى يستحيل النجاح الفارغ.
    Observed live: 117 passed, 1 failed, and five of those passes asserted nothing.
#>

BeforeDiscovery {
    $script:UndoPath = if ($env:SOVEREIGN_UNDO_JSON) { $env:SOVEREIGN_UNDO_JSON } else { 'C:\Backups\sovereign-undo.json' }
    $script:HasUndo  = Test-Path -LiteralPath $script:UndoPath

    $discovered = @()
    if ($script:HasUndo) {
        $discovered = @(Get-Content -LiteralPath $script:UndoPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    }
    $script:RegEntries  = @($discovered | Where-Object { "$($_.Kind)" -eq 'registry' })
    $script:SvcEntries  = @($discovered | Where-Object { "$($_.Kind)" -eq 'service'  })
    $script:TaskEntries = @($discovered | Where-Object { "$($_.Kind)" -eq 'task'     })
    $script:EnvEntries  = @($discovered | Where-Object { "$($_.Kind)" -eq 'env'      })
    $script:DirEntries  = @($discovered | Where-Object { "$($_.Kind)" -eq 'folder'   })
}

BeforeAll {
    # نفس التحميل مرة أخرى، لأن مرحلة التشغيل حالة جلسة مستقلة عن مرحلة الاكتشاف.
    # The same load again: the run phase is a separate session state from discovery.
    $script:UndoPath = if ($env:SOVEREIGN_UNDO_JSON) { $env:SOVEREIGN_UNDO_JSON } else { 'C:\Backups\sovereign-undo.json' }
    $script:Raw      = ''
    $script:Entries  = @()
    if (Test-Path -LiteralPath $script:UndoPath) {
        $script:Raw     = Get-Content -LiteralPath $script:UndoPath -Raw -Encoding UTF8
        $script:Entries = @($script:Raw | ConvertFrom-Json)
    }
    $script:Buckets = [ordered]@{}
    foreach ($k in 'registry','service','task','env','folder') {
        $script:Buckets[$k] = @($script:Entries | Where-Object { "$($_.Kind)" -eq $k })
    }
    $script:Protected = @('wuauserv','WinDefend','mpssvc','SecurityHealthService','WdNisSvc')
}

Describe 'undo journal file' -Tag 'live' -Skip:(-not $script:HasUndo) {

    It 'exists on disk' {
        Test-Path -LiteralPath $script:UndoPath | Should -BeTrue
    }

    It 'parses as a non-empty JSON array' {
        $script:Entries.Count | Should -BeGreaterThan 0
    }

    It 'contains only known entry kinds' {
        $script:Entries.Count | Should -BeGreaterThan 0   # لا نجاح فارغ / no vacuous pass
        $allowed = @('registry','service','task','env','folder')
        foreach ($e in $script:Entries) {
            $allowed | Should -Contain "$($e.Kind)"
        }
    }

    It 'accounts for every entry in exactly one kind bucket' {
        $script:Entries.Count | Should -BeGreaterThan 0
        $sum = 0
        foreach ($k in @($script:Buckets.Keys)) { $sum += $script:Buckets[$k].Count }
        $sum | Should -Be $script:Entries.Count
    }

    It 'bucket <_> is not empty' -ForEach @('registry','service','task','env','folder') {
        $script:Buckets[$_].Count | Should -BeGreaterThan 0
    }
}

Describe 'registry entries' -Tag 'live' -Skip:(-not $script:HasUndo) {

    It 'carries Path, Name, HadValue and KeyExisted: <_.Path>\<_.Name>' -ForEach $script:RegEntries {
        $names = $_.PSObject.Properties.Name
        $names | Should -Contain 'Path'
        $names | Should -Contain 'Name'
        $names | Should -Contain 'HadValue'
        $names | Should -Contain 'KeyExisted'
        "$($_.Path)" | Should -Not -BeNullOrEmpty
        "$($_.Name)" | Should -Not -BeNullOrEmpty
    }

    It 'records OldValue when HadValue is true: <_.Path>\<_.Name>' -ForEach $script:RegEntries {
        if ([bool]$_.HadValue) {
            $_.PSObject.Properties.Name | Should -Contain 'OldValue'
        } else {
            # لا قيمة سابقة، فالعكس حذف لا استرجاع / nothing to restore: undo removes the value
            [bool]$_.HadValue | Should -BeFalse
        }
    }

    It 'has no duplicate Path\Name pair' {
        $reg = $script:Buckets['registry']
        $reg.Count | Should -BeGreaterThan 0
        $keys   = @($reg | ForEach-Object { "$($_.Path)\$($_.Name)" })
        $unique = @($keys | Sort-Object -Unique)
        $unique.Count | Should -Be $keys.Count
    }

    It 'points at a key that still exists: <_.Path>' -ForEach $script:RegEntries {
        Test-Path -LiteralPath "$($_.Path)" | Should -BeTrue
    }
}

Describe 'service entries' -Tag 'live' -Skip:(-not $script:HasUndo) {

    It 'records a restorable start mode: <_.Name>' -ForEach $script:SvcEntries {
        $names = $_.PSObject.Properties.Name
        $names | Should -Contain 'OldStartMode'
        $names | Should -Contain 'WasRunning'
        @('Auto','Automatic','Manual','Disabled','Boot','System') | Should -Contain "$($_.OldStartMode)"
    }

    It 'never records a protected service' {
        $svc = $script:Buckets['service']
        $svc.Count | Should -BeGreaterThan 0
        foreach ($name in $script:Protected) {
            @($svc | Where-Object { "$($_.Name)" -eq $name }).Count | Should -Be 0
        }
    }
}

Describe 'task entries' -Tag 'live' -Skip:(-not $script:HasUndo) {

    It 'records Path, Name and OldState: <_.Name>' -ForEach $script:TaskEntries {
        $names = $_.PSObject.Properties.Name
        $names | Should -Contain 'Path'
        $names | Should -Contain 'Name'
        $names | Should -Contain 'OldState'
        # تسجيل Disabled كحالة سابقة يعني أن العكس سيُمكّن مهمة كانت معطّلة أصلاً.
        "$($_.OldState)" | Should -Not -Be 'Disabled'
    }
}

Describe 'env and folder entries' -Tag 'live' -Skip:(-not $script:HasUndo) {

    It 'env entry records Name and HadValue: <_.Name>' -ForEach $script:EnvEntries {
        $names = $_.PSObject.Properties.Name
        $names | Should -Contain 'Name'
        $names | Should -Contain 'HadValue'
    }

    It 'folder entry points at a path that exists: <_.Path>' -ForEach $script:DirEntries {
        Test-Path -LiteralPath "$($_.Path)" | Should -BeTrue
    }
}

Describe 'protected services were never touched' -Tag 'live' -Skip:(-not $script:HasUndo) {

    It 'the raw journal text mentions no protected service' {
        $script:Raw.Length | Should -BeGreaterThan 0
        $script:Raw | Should -Not -Match 'wuauserv|WinDefend|mpssvc|WdNisSvc|SecurityHealthService'
    }
}

Describe 'live security invariants' -Tag 'machine' {

    It 'Windows Update start type is not Disabled' {
        # الحالة ليست ثابتاً: wuauserv تعمل عند الطلب وويندوز يوقفها عند الخمول.
        # Status is deliberately not asserted: wuauserv is demand-start.
        $svc = Get-Service -Name wuauserv -ErrorAction SilentlyContinue
        $svc | Should -Not -BeNullOrEmpty
        "$($svc.StartType)" | Should -Not -Be 'Disabled'
    }

    It 'Defender antivirus is enabled' {
        (Get-MpComputerStatus).AntivirusEnabled | Should -BeTrue
    }

    It 'Defender signatures are fresher than 7 days' {
        # وقع حياً: توقيعات عمرها 5 أيام و10 ساعات على محرّك يقول AntivirusEnabled True.
        # Observed live: signatures 5d10h old while the engine reported enabled.
        $mp = Get-MpComputerStatus
        $mp.AntivirusSignatureLastUpdated | Should -Not -BeNullOrEmpty
        ((Get-Date) - $mp.AntivirusSignatureLastUpdated).TotalDays | Should -BeLessThan 7
    }

    It 'all three firewall profiles are enabled' {
        $profiles = @(Get-NetFirewallProfile)
        $profiles.Count | Should -Be 3
        foreach ($p in $profiles) { [bool]$p.Enabled | Should -BeTrue }
    }

    It 'telemetry services remain disabled' {
        foreach ($n in 'DiagTrack','dmwappushservice') {
            $cim = Get-CimInstance -ClassName Win32_Service -Filter ("Name='{0}'" -f $n)
            "$($cim.StartMode)" | Should -Be 'Disabled'
        }
    }
}
