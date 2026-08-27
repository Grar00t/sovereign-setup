#requires -Version 5.1
<#
  فحص للقراءة فقط. صفر تغييرات. شغّله كمسؤول للحصول على كل النتائج.
  Read-only probe. Zero changes. Run elevated for complete results.
#>
[CmdletBinding()]
param([string]$OutFile)
Set-StrictMode -Version Latest

$Inv = [Globalization.CultureInfo]::InvariantCulture

function Has($obj, [string]$name) {
  if ($null -eq $obj) { return $false }
  return ($obj.PSObject.Properties.Name -contains $name)
}
function Iso($v) {
  # التواريخ بتقويم ثابت: تحت ar-SA كان تاريخ Defender يطبع هجرياً (09/03/48).
  # Invariant dates: under ar-SA the Defender date printed as Hijri (09/03/48).
  if ($null -eq $v) { return '' }
  if ($v -is [datetime]) { return $v.ToString('yyyy-MM-dd HH:mm:ss', $Inv) }
  return "$v"
}
function WmiTime([string]$s) {
  # 20260827221805.421835-000 -> UTC
  if ([string]::IsNullOrEmpty($s) -or $s.Length -lt 14) { return $null }
  try {
    $d = [datetime]::ParseExact($s.Substring(0, 14), 'yyyyMMddHHmmss', $Inv)
    $offset = 0
    if ($s.Length -ge 25) { $offset = [int]$s.Substring(21) }
    return $d.AddMinutes(-1 * $offset)
  } catch { return $null }
}

if ($OutFile) { Start-Transcript -Path $OutFile | Out-Null }

Write-Host '=== OS ===' -ForegroundColor Cyan
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$build = 0
if (Has $cv 'CurrentBuild') { $build = [int]$cv.CurrentBuild }
$family = 'Windows 10'
if ($build -ge 22000) { $family = 'Windows 11' }
$edition = ("$($cv.ProductName)" -replace '^Windows\s+\d+\s*', '')
'{0} {1} {2} build {3}.{4}' -f $family, $edition, $cv.DisplayVersion, $cv.CurrentBuild, $cv.UBR
# ProductName يبقى "Windows 10 Pro" على Windows 11. الحقيقة في رقم البناء.
# ProductName stays "Windows 10 Pro" on Windows 11. The build number is the truth.
'registry ProductName: {0}' -f $cv.ProductName
$u = (Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
"Uptime: $($u.Days)d $($u.Hours)h $($u.Minutes)m"
$PSVersionTable.PSVersion.ToString()

Write-Host '=== security invariants ===' -ForegroundColor Cyan
# الثابت هو StartType لا Status: wuauserv خدمة عند الطلب وتتبدّل بين Running و Stopped.
# The invariant is StartType, not Status: wuauserv is demand-start and legitimately toggles.
Get-Service wuauserv, WinDefend, mpssvc, DiagTrack, dmwappushservice -ErrorAction SilentlyContinue |
  Select-Object Name, Status, StartType | Format-Table -AutoSize | Out-Host
Get-NetFirewallProfile | Select-Object Name, Enabled | Format-Table -AutoSize | Out-Host
try {
  $mp = Get-MpComputerStatus -ErrorAction Stop
  [pscustomobject]@{
    AntivirusEnabled              = $mp.AntivirusEnabled
    RealTimeProtectionEnabled     = $mp.RealTimeProtectionEnabled
    AntivirusSignatureLastUpdated = Iso $mp.AntivirusSignatureLastUpdated
  } | Format-List | Out-Host
} catch { Write-Host "! Defender status unavailable: $($_.Exception.Message)" -ForegroundColor Yellow }

Write-Host '=== installed Win32 apps ===' -ForegroundColor Cyan
$keys = @(
  'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
  'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
  'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
# Where-Object DisplayName يرفع خطأً تحت Set-StrictMode عند أول مدخل بلا الخاصية.
# Where-Object DisplayName throws under Set-StrictMode for entries without that property.
Get-ItemProperty $keys -ErrorAction SilentlyContinue |
  Where-Object { $_.PSObject.Properties.Name -contains 'DisplayName' } |
  Select-Object DisplayName, DisplayVersion, Publisher |
  Sort-Object DisplayName | Format-Table -AutoSize | Out-Host

Write-Host '=== OneDrive ===' -ForegroundColor Cyan
# System32\OneDriveSetup.exe يبقى موجوداً بعد الإزالة؛ الدليل هو عميل المستخدم.
# System32\OneDriveSetup.exe survives uninstall; the per-user client is the real signal.
@("$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe",
  "$env:SystemRoot\System32\OneDriveSetup.exe",
  "$env:SystemRoot\SysWOW64\OneDriveSetup.exe") |
  ForEach-Object { [pscustomobject]@{ Path = $_; Exists = (Test-Path $_) } } | Format-Table -AutoSize | Out-Host
"OneDrive process running: $((@(Get-Process OneDrive -ErrorAction SilentlyContinue).Count -gt 0))"

Write-Host '=== toolchain ===' -ForegroundColor Cyan
foreach ($c in 'git','pwsh','dotnet','cmake','ninja','python','py','node','rustup','code') {
  $found = Get-Command $c -ErrorAction SilentlyContinue
  if (-not $found) { "[ ] $c"; continue }
  $src = ''
  if (Has $found 'Source') { $src = "$($found.Source)" }
  if ($src -like '*\Microsoft\WindowsApps\*') {
    # كعب Microsoft Store بحجم صفر بايت: كان python يُعدّ مثبتاً بلا أي إصدار.
    # 0-byte Microsoft Store execution alias: python was reported present with no version.
    $fi = Get-Item -LiteralPath $src -ErrorAction SilentlyContinue
    if ($fi -and $fi.Length -eq 0) { "[~] $c -> Microsoft Store execution alias (0 bytes), not installed"; continue }
  }
  $v = ''
  try { $v = "$(& $c --version 2>&1 | Select-Object -First 1)".Trim() } catch { $v = '' }
  if ($v -eq '') { "[~] $c -> no version output ($src)" } else { "[x] $c -> $v" }
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
               'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search',
               'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive',
               'HKLM:\SOFTWARE\Policies\Microsoft\Dsh',
               'HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization') {
  "==== $k ===="
  Get-ItemProperty $k -ErrorAction SilentlyContinue | Format-List | Out-Host
}

Write-Host '=== PATH ===' -ForegroundColor Cyan
'Machine','User' | ForEach-Object {
  $s = $_
  [Environment]::GetEnvironmentVariable('Path', $s) -split ';' | Where-Object { $_ } |
    ForEach-Object { [pscustomobject]@{ Scope = $s; Entry = $_; Exists = (Test-Path $_) } }
} | Format-Table -AutoSize | Out-Host

Write-Host '=== startup, tasks, restore, disks, network ===' -ForegroundColor Cyan
Get-CimInstance Win32_StartupCommand | Select-Object Name, Location, Command | Format-Table -AutoSize | Out-Host
Get-ScheduledTask | Where-Object {
  $_.TaskPath -match 'Application Experience|Customer Experience|Feedback' -or
  $_.TaskName -match 'Consolidator|UsbCeip|DmClient'
} | Select-Object TaskPath, TaskName, State | Sort-Object TaskPath, TaskName | Format-Table -AutoSize | Out-Host
# Get-ComputerRestorePoint غير موجود في PowerShell 7، وعبر طبقة التوافق كان CreationTime يعود فارغاً.
# Get-ComputerRestorePoint does not exist in PowerShell 7; via the compatibility layer CreationTime came back blank.
try {
  Get-CimInstance -Namespace 'root/default' -ClassName 'SystemRestore' -ErrorAction Stop |
    Sort-Object SequenceNumber |
    ForEach-Object {
      [pscustomobject]@{
        SequenceNumber  = $_.SequenceNumber
        Description     = $_.Description
        CreationTimeUtc = Iso (WmiTime "$($_.CreationTime)")
      }
    } | Format-Table -AutoSize | Out-Host
} catch { Write-Host "! restore points unavailable: $($_.Exception.Message)" -ForegroundColor Yellow }
Get-PhysicalDisk | Select-Object DeviceId, FriendlyName, MediaType, Size | Format-Table -AutoSize | Out-Host
Get-NetAdapter | Select-Object Name, InterfaceDescription, Status, ifIndex | Format-Table -AutoSize | Out-Host
Get-DnsClientServerAddress -AddressFamily IPv4 | Select-Object InterfaceAlias, ServerAddresses | Format-Table -AutoSize | Out-Host

if ($OutFile) { Stop-Transcript | Out-Null }
