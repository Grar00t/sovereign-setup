#requires -Version 5.1
<#
  فحص للقراءة فقط. صفر تغييرات. شغّله كمسؤول للحصول على كل النتائج.
  Read-only probe. Zero changes. Run elevated for complete results.
#>
[CmdletBinding()]
param([string]$OutFile)
Set-StrictMode -Version Latest

if ($OutFile) { Start-Transcript -Path $OutFile | Out-Null }

Write-Host '=== OS ===' -ForegroundColor Cyan
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
'{0} {1} build {2}.{3}' -f $cv.ProductName, $cv.DisplayVersion, $cv.CurrentBuild, $cv.UBR
$u = (Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
"Uptime: $($u.Days)d $($u.Hours)h $($u.Minutes)m"
$PSVersionTable.PSVersion.ToString()

Write-Host '=== security invariants ===' -ForegroundColor Cyan
Get-Service wuauserv, WinDefend, mpssvc, DiagTrack, dmwappushservice -ErrorAction SilentlyContinue |
  Select-Object Name, Status, StartType | Format-Table -AutoSize
Get-NetFirewallProfile | Select-Object Name, Enabled | Format-Table -AutoSize
try {
  Get-MpComputerStatus | Select-Object AntivirusEnabled, RealTimeProtectionEnabled, AntivirusSignatureLastUpdated
} catch { Write-Host "! Defender status unavailable: $($_.Exception.Message)" -ForegroundColor Yellow }

Write-Host '=== installed Win32 apps ===' -ForegroundColor Cyan
$keys = @(
  'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
  'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
  'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
Get-ItemProperty $keys -ErrorAction SilentlyContinue |
  Where-Object DisplayName |
  Select-Object DisplayName, DisplayVersion, Publisher |
  Sort-Object DisplayName | Format-Table -AutoSize

Write-Host '=== OneDrive ===' -ForegroundColor Cyan
@("$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe",
  "$env:SystemRoot\System32\OneDriveSetup.exe",
  "$env:SystemRoot\SysWOW64\OneDriveSetup.exe") |
  ForEach-Object { [pscustomobject]@{ Path = $_; Exists = (Test-Path $_) } } | Format-Table -AutoSize

Write-Host '=== toolchain ===' -ForegroundColor Cyan
foreach ($c in 'git','pwsh','dotnet','cmake','ninja','python','py','node','rustup','code') {
  $found = Get-Command $c -ErrorAction SilentlyContinue
  if ($found) { $v = (& $c --version 2>&1 | Select-Object -First 1); "[x] $c -> $v" } else { "[ ] $c" }
}

Write-Host '=== winget manifests (LIVE) ===' -ForegroundColor Cyan
if (Get-Command winget -ErrorAction SilentlyContinue) {
  winget --version
  foreach ($id in 'Microsoft.DotNet.SDK.9','Ninja-build.Ninja','Python.Python.3.12') {
    "==== $id ===="
    winget show --id $id --exact --source winget | Select-Object -First 12
  }
} else { Write-Host '! winget unavailable' -ForegroundColor Yellow }

Write-Host '=== policy keys ===' -ForegroundColor Cyan
foreach ($k in 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection',
               'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot',
               'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI',
               'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo',
               'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent',
               'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search') {
  "==== $k ===="
  Get-ItemProperty $k -ErrorAction SilentlyContinue | Format-List
}

Write-Host '=== PATH ===' -ForegroundColor Cyan
'Machine','User' | ForEach-Object {
  $s = $_
  [Environment]::GetEnvironmentVariable('Path', $s) -split ';' | Where-Object { $_ } |
    ForEach-Object { [pscustomobject]@{ Scope = $s; Entry = $_; Exists = (Test-Path $_) } }
} | Format-Table -AutoSize

Write-Host '=== startup, tasks, restore, disks, network ===' -ForegroundColor Cyan
Get-CimInstance Win32_StartupCommand | Select-Object Name, Location, Command | Format-Table -AutoSize
Get-ScheduledTask | Where-Object {
  $_.TaskPath -match 'Application Experience|Customer Experience|Feedback' -or
  $_.TaskName -match 'Consolidator|UsbCeip|DmClient'
} | Select-Object TaskPath, TaskName, State | Format-Table -AutoSize
Get-ComputerRestorePoint -ErrorAction SilentlyContinue | Select-Object -Last 3
Get-PhysicalDisk | Select-Object DeviceId, FriendlyName, MediaType, Size | Format-Table -AutoSize
Get-NetAdapter | Select-Object Name, InterfaceDescription, Status, ifIndex | Format-Table -AutoSize
Get-DnsClientServerAddress -AddressFamily IPv4 | Select-Object InterfaceAlias, ServerAddresses | Format-Table -AutoSize

if ($OutFile) { Stop-Transcript | Out-Null }
