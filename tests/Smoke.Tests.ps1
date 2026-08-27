#requires -Version 5.1
<#
  Pester 5 smoke tests.
  Install-Module Pester -Force -SkipPublisherCheck -Scope CurrentUser
  Invoke-Pester .\tests\Smoke.Tests.ps1
#>

Describe 'toolchain' {
  It 'command <_> is available' -ForEach @('git','pwsh','dotnet','cmake','ninja') {
    (Get-Command $_ -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
  }
}

Describe 'privacy baseline' {
  It 'DiagTrack is disabled' {
    (Get-CimInstance Win32_Service -Filter "Name='DiagTrack'").StartMode | Should -Be 'Disabled'
  }

  It 'dmwappushservice is disabled' {
    (Get-CimInstance Win32_Service -Filter "Name='dmwappushservice'").StartMode | Should -Be 'Disabled'
  }

  It 'telemetry is at the Pro minimum' {
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

Describe 'security invariants' {
  It 'Windows Update is not disabled' {
    (Get-CimInstance Win32_Service -Filter "Name='wuauserv'").StartMode | Should -Not -Be 'Disabled'
  }

  It 'Defender real-time protection is on' {
    (Get-MpComputerStatus).AntivirusEnabled | Should -BeTrue
  }

  It 'firewall profile <_> is enabled' -ForEach @('Domain','Private','Public') {
    (Get-NetFirewallProfile -Name $_).Enabled | Should -BeTrue
  }
}

Describe 'workspace' {
  It 'folder <_> exists' -ForEach @('D:\Dev\src','D:\Dev\tools','D:\Projects','C:\Backups') {
    Test-Path $_ | Should -BeTrue
  }

  It 'undo record exists and is non-empty' {
    Test-Path 'C:\Backups\sovereign-undo.json' | Should -BeTrue
    @(Get-Content 'C:\Backups\sovereign-undo.json' -Raw | ConvertFrom-Json).Count | Should -BeGreaterThan 0
  }
}
