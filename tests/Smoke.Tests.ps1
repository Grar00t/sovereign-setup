#requires -Version 5.1
<#
  Pester 5.
  Install-Module Pester -Force -SkipPublisherCheck -Scope CurrentUser

  Invoke-Pester .\tests\Smoke.Tests.ps1              # الكل / everything
  Invoke-Pester .\tests\Smoke.Tests.ps1 -Tag repo    # لا يحتاج جهازاً مُقسّى / no hardened machine needed
  Invoke-Pester .\tests\Smoke.Tests.ps1 -Tag machine # يفحص الجهاز بعد التطبيق / asserts an applied machine

  المسارات من SOVEREIGN_DEV_ROOT و SOVEREIGN_BACKUP_ROOT إن وُجدا، وإلا فالقيم الافتراضية.
  Paths come from SOVEREIGN_DEV_ROOT and SOVEREIGN_BACKUP_ROOT when set.
#>

BeforeDiscovery {
  $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

  $script:DevRoot = $env:SOVEREIGN_DEV_ROOT
  if (-not $script:DevRoot) { $script:DevRoot = 'D:\Dev' }
  $script:BackupRoot = $env:SOVEREIGN_BACKUP_ROOT
  if (-not $script:BackupRoot) { $script:BackupRoot = 'C:\Backups' }

  $script:Scripts = @(
    Get-ChildItem -Path $script:RepoRoot -Recurse -Filter *.ps1 -File |
      Where-Object { $_.FullName -notlike '*\.git\*' }
  )

  # كل مسار سكربت أو مستند مذكور في أي ملف Markdown يجب أن يكون موجوداً.
  # Every script or doc path named in any Markdown file must exist.
  $refs = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($m in @(Get-ChildItem -Path $script:RepoRoot -Recurse -Filter *.md -File | Where-Object { $_.FullName -notlike '*\.git\*' })) {
    $text = Get-Content -LiteralPath $m.FullName -Raw
    foreach ($pattern in @('(scripts|tools|undo|tests|docs)/[\w.\-]+\.(ps1|md|yml)',
                           '(scripts|tools|undo|tests|docs)\\[\w.\-]+\.(ps1|md|yml)')) {
      foreach ($mm in [regex]::Matches($text, $pattern)) { [void]$refs.Add(($mm.Value -replace '\\', '/')) }
    }
  }
  $script:DocPaths = @($refs)
}

Describe 'repo' -Tag 'repo' {

  It 'script <_.Name> parses' -ForEach $script:Scripts {
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$errors) | Out-Null
    @($errors).Count | Should -Be 0
  }

  It 'documented path <_> exists' -ForEach $script:DocPaths {
    Test-Path (Join-Path $script:RepoRoot $_) | Should -BeTrue
  }

  It 'the apply script stamps journals with InvariantCulture' {
    # Get-Date -Format يتبع تقويم الجلسة، وأنتج journal-14480315-013014.json تحت ar-SA.
    $t = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'scripts/sovereign-quick.ps1') -Raw
    $t | Should -Match 'InvariantCulture'
    $t | Should -Not -Match "Get-Date -Format 'yyyyMMdd"
  }

  It 'undo reads every journal field defensively' {
    # الوصول المباشر إلى حقل غائب يرفع استثناءً تحت Set-StrictMode ويترك الجهاز نصف معكوس.
    $t = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'undo/sovereign-undo.ps1') -Raw
    $t | Should -Match 'function Field'
    $t | Should -Not -Match '\$e\.'
  }

  It 'undo accepts the ad-hoc journal schema' {
    $t = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'undo/sovereign-undo.ps1') -Raw
    $t | Should -Match "taskPath','path"
    $t | Should -Match '-Validate'
  }

  It 'the probe filters DisplayName without a strict-mode failure' {
    $t = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'tools/probe-live.ps1') -Raw
    $t | Should -Not -Match 'Where-Object DisplayName'
    $t | Should -Match "-contains 'DisplayName'"
  }

  It 'the probe derives the OS family from the build number' {
    $t = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'tools/probe-live.ps1') -Raw
    $t | Should -Match '22000'
  }
}

Describe 'toolchain' -Tag 'machine' {
  It 'command <_> is available' -ForEach @('git','pwsh','dotnet','cmake','ninja') {
    (Get-Command $_ -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
  }
}

Describe 'privacy baseline' -Tag 'machine' {
  It 'DiagTrack is disabled' {
    (Get-CimInstance Win32_Service -Filter "Name='DiagTrack'").StartMode | Should -Be 'Disabled'
  }

  It 'dmwappushservice is disabled' {
    (Get-CimInstance Win32_Service -Filter "Name='dmwappushservice'").StartMode | Should -Be 'Disabled'
  }

  It 'telemetry is at the Pro minimum' {
    # 1 هو الحد الأدنى في Pro؛ 0 يُحترم في Enterprise/Education فقط.
    $v = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Name AllowTelemetry -ErrorAction SilentlyContinue).AllowTelemetry
    [int]$v | Should -Be 1
  }

  It 'device name is excluded from telemetry' {
    $v = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Name AllowDeviceNameInTelemetry -ErrorAction SilentlyContinue).AllowDeviceNameInTelemetry
    [int]$v | Should -Be 0
  }

  It 'Copilot policy is enforced in <_>' -ForEach @(
    'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot',
    'HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot'
  ) {
    $v = (Get-ItemProperty $_ -Name TurnOffWindowsCopilot -ErrorAction SilentlyContinue).TurnOffWindowsCopilot
    [int]$v | Should -Be 1
  }

  It 'AI data analysis is disabled' {
    $v = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' -Name DisableAIDataAnalysis -ErrorAction SilentlyContinue).DisableAIDataAnalysis
    [int]$v | Should -Be 1
  }

  It 'advertising ID is disabled by policy' {
    $v = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo' -Name DisabledByGroupPolicy -ErrorAction SilentlyContinue).DisabledByGroupPolicy
    [int]$v | Should -Be 1
  }

  It 'web search in Start is disabled' {
    $v = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' -Name DisableWebSearch -ErrorAction SilentlyContinue).DisableWebSearch
    [int]$v | Should -Be 1
  }

  It 'consumer features are disabled' {
    $v = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' -Name DisableWindowsConsumerFeatures -ErrorAction SilentlyContinue).DisableWindowsConsumerFeatures
    [int]$v | Should -Be 1
  }

  It 'file extensions are visible' {
    $v = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name HideFileExt -ErrorAction SilentlyContinue).HideFileExt
    [int]$v | Should -Be 0
  }

  It 'toolchain telemetry is opted out: <_>' -ForEach @('DOTNET_CLI_TELEMETRY_OPTOUT','POWERSHELL_TELEMETRY_OPTOUT') {
    [Environment]::GetEnvironmentVariable($_, 'Machine') | Should -Be '1'
  }
}

Describe 'security invariants' -Tag 'machine' {
  It 'Windows Update is not disabled' {
    # الثابت هو StartMode لا Status: wuauserv تتبدّل بين Running و Stopped بطبيعتها.
    (Get-CimInstance Win32_Service -Filter "Name='wuauserv'").StartMode | Should -Not -Be 'Disabled'
  }

  It 'Defender real-time protection is on' {
    (Get-MpComputerStatus).AntivirusEnabled | Should -BeTrue
  }

  It 'firewall profile <_> is enabled' -ForEach @('Domain','Private','Public') {
    (Get-NetFirewallProfile -Name $_).Enabled | Should -BeTrue
  }
}

Describe 'workspace' -Tag 'machine' {
  It 'folder <_> exists' -ForEach @("$script:DevRoot\src", "$script:DevRoot\tools", 'D:\Projects', $script:BackupRoot) {
    Test-Path $_ | Should -BeTrue
  }

  It 'at least one journal exists and is non-empty' {
    $candidates = @(Join-Path $script:BackupRoot 'sovereign-undo.json')
    $stateDir = Join-Path $script:BackupRoot 'sovereign-setup\state'
    if (Test-Path $stateDir) {
      $candidates += @(Get-ChildItem -Path $stateDir -Filter 'journal-*.json' -File | ForEach-Object { $_.FullName })
    }
    $found = @($candidates | Where-Object { Test-Path $_ })
    $found.Count | Should -BeGreaterThan 0
    foreach ($f in $found) {
      @(Get-Content -LiteralPath $f -Raw | ConvertFrom-Json).Count | Should -BeGreaterThan 0
    }
  }
}
