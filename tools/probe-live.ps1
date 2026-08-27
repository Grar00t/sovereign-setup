#requires -Version 5.1
<#
  فحص للقراءة فقط. صفر تغييرات. شغّله كمسؤول للحصول على كل النتائج.
  Read-only probe. Zero changes. Run elevated for complete results.

  v2 — أُصلح بعد تشغيل حقيقي على ويندوز 11 برو 26100 تحت PowerShell 7.6.5:
    * التواريخ والطوابع بالتقويم الميلادي دائماً (InvariantCulture).
    * تعداد تطبيقات Win32 آمن تحت StrictMode في PS7.
    * كشف OneDrive بملف العميل، لا بـ OneDriveSetup.exe.
    * نقاط الاستعادة عبر CIM مع تحويل DMTF صريح.
    * تمييز اختصارات متجر ويندوز (app-execution alias) عن تثبيت حقيقي.
    * خريطة حرف القرص -> رقم القرص -> نوع الوسيط.
#>
[CmdletBinding()]
param([string]$OutFile)
Set-StrictMode -Version Latest

$Inv = [Globalization.CultureInfo]::InvariantCulture
function Iso($Value) {
    if ($null -eq $Value) { return '' }
    return ([datetime]$Value).ToString('yyyy-MM-dd HH:mm:ss', $Inv)
}

if ($OutFile) {
    $dir = Split-Path -Parent $OutFile
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Start-Transcript -Path $OutFile | Out-Null
}

Write-Host '=== OS ===' -ForegroundColor Cyan
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$os = Get-CimInstance Win32_OperatingSystem
# ProductName في هذا المفتاح ما زال يقول "Windows 10 Pro" على بناء 22000+. Caption هو المعتمد.
'registry ProductName : {0}' -f $cv.ProductName
'CIM Caption          : {0}' -f $os.Caption
'edition / version    : {0} / {1}' -f $cv.EditionID, $cv.DisplayVersion
'build                : {0}.{1}' -f $cv.CurrentBuild, $cv.UBR
'installed            : {0}' -f (Iso $os.InstallDate)
$u = (Get-Date) - $os.LastBootUpTime
'uptime               : {0}d {1}h {2}m' -f $u.Days, $u.Hours, $u.Minutes
'PowerShell           : {0}' -f $PSVersionTable.PSVersion.ToString()

Write-Host '=== culture (يفسّر أي طابع زمني غريب في أسماء الملفات) ===' -ForegroundColor Cyan
'culture / UI         : {0} / {1}' -f (Get-Culture).Name, (Get-UICulture).Name
'calendar             : {0}' -f (Get-Culture).Calendar.GetType().Name
'Get-Date -Format     : {0}    <- تقويم النظام' -f (Get-Date -Format 'yyyyMMdd-HHmmss')
'invariant            : {0}    <- ما يجب أن تستعمله السكربتات' -f (Get-Date).ToString('yyyyMMdd-HHmmss', $Inv)

Write-Host '=== security invariants ===' -ForegroundColor Cyan
Get-Service wuauserv, WinDefend, mpssvc, DiagTrack, dmwappushservice -ErrorAction SilentlyContinue |
  Select-Object Name, Status, StartType | Format-Table -AutoSize
Get-NetFirewallProfile | Select-Object Name, Enabled | Format-Table -AutoSize
try {
  $mp = Get-MpComputerStatus -ErrorAction Stop
  [pscustomobject]@{
    AntivirusEnabled          = $mp.AntivirusEnabled
    RealTimeProtectionEnabled = $mp.RealTimeProtectionEnabled
    SignatureLastUpdated      = (Iso $mp.AntivirusSignatureLastUpdated)
  } | Format-List
} catch { Write-Host "! Defender status unavailable: $($_.Exception.Message)" -ForegroundColor Yellow }

Write-Host '=== installed Win32 apps ===' -ForegroundColor Cyan
$keys = @(
  'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
  'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
  'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
# لا تستعمل "Where-Object DisplayName": يرمي تحت StrictMode في PS7 لأي مفتاح بلا هذه الخاصية.
Get-ItemProperty $keys -ErrorAction SilentlyContinue |
  Where-Object { ($_.PSObject.Properties.Name -contains 'DisplayName') -and $_.DisplayName } |
  Select-Object DisplayName, DisplayVersion, Publisher |
  Sort-Object DisplayName -Unique | Format-Table -AutoSize

Write-Host '=== OneDrive ===' -ForegroundColor Cyan
$odClients = @(
  "$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe",
  "$env:ProgramFiles\Microsoft OneDrive\OneDrive.exe",
  "${env:ProgramFiles(x86)}\Microsoft OneDrive\OneDrive.exe"
) | Where-Object { $_ -and (Test-Path $_) }
$odSetups = @(
  "$env:SystemRoot\System32\OneDriveSetup.exe",
  "$env:SystemRoot\SysWOW64\OneDriveSetup.exe"
) | Where-Object { Test-Path $_ }
[pscustomobject]@{
  ClientInstalled  = [bool]$odClients.Count
  ClientPaths      = ($odClients -join ', ')
  SetupStubPresent = [bool]$odSetups.Count
  ProfileFolder    = (Test-Path (Join-Path $env:USERPROFILE 'OneDrive'))
} | Format-List
'ملاحظة: OneDriveSetup.exe يُشحن مع ويندوز دائماً — وجوده ليس دليل تثبيت.'

Write-Host '=== toolchain ===' -ForegroundColor Cyan
foreach ($c in 'git','pwsh','dotnet','cmake','ninja','python','py','node','rustup','code') {
  $cmd = Get-Command $c -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $cmd) { "[ ] $c"; continue }
  $src = ''
  if ($cmd.PSObject.Properties.Name -contains 'Source') { $src = "$($cmd.Source)" }
  $len = $null
  if ($src) { $len = (Get-Item -LiteralPath $src -ErrorAction SilentlyContinue).Length }
  if ($src -like '*\WindowsApps\*' -and $len -eq 0) {
    "[?] $c -> اختصار متجر بلا تثبيت حقيقي / Store app-execution alias stub: $src"
    continue
  }
  $v = ''
  try { $v = (& $src --version 2>&1 | Select-Object -First 1) } catch { $v = "probe failed: $($_.Exception.Message)" }
  "[x] $c -> $v   ($src)"
}

Write-Host '=== winget manifests (LIVE) ===' -ForegroundColor Cyan
# لا تُسجَّل أي بصمة SHA-256 من هذه الصفحات. البصمة تُؤخذ بـ Get-FileHash على ملف نُزّل فعلاً.
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
               'HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot',
               'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI',
               'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo',
               'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent',
               'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search',
               'HKLM:\SOFTWARE\Policies\Microsoft\Dsh',
               'HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization',
               'HKCU:\Software\Microsoft\InputPersonalization',
               'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager') {
  "==== $k ===="
  Get-ItemProperty $k -ErrorAction SilentlyContinue |
    Select-Object -Property * -ExcludeProperty PS* | Format-List
}

Write-Host '=== PATH ===' -ForegroundColor Cyan
$pathRows = @(
  'Machine','User' | ForEach-Object {
    $s = $_
    [Environment]::GetEnvironmentVariable('Path', $s) -split ';' | Where-Object { $_ } |
      ForEach-Object {
        $expanded = [Environment]::ExpandEnvironmentVariables($_)
        [pscustomobject]@{ Scope = $s; Entry = $_; Exists = (Test-Path -LiteralPath $expanded) }
      }
  }
)
$pathRows | Format-Table -AutoSize
'dead entries: {0} of {1}' -f @($pathRows | Where-Object { -not $_.Exists }).Count, $pathRows.Count

Write-Host '=== startup ===' -ForegroundColor Cyan
Write-Host 'تحذير: هذا القسم يحتوي SID المستخدم — لا تنشره كما هو.' -ForegroundColor DarkYellow
Get-CimInstance Win32_StartupCommand | Select-Object Name, Location, Command | Format-Table -AutoSize

Write-Host '=== telemetry-adjacent scheduled tasks (كامل الشجرة، فالغياب يُثبَت) ===' -ForegroundColor Cyan
foreach ($p in '\Microsoft\Windows\Application Experience\',
               '\Microsoft\Windows\Customer Experience Improvement Program\',
               '\Microsoft\Windows\Feedback\Siuf\',
               '\Microsoft\Windows\Windows Error Reporting\') {
  "==== $p ===="
  $tasks = @(Get-ScheduledTask -TaskPath $p -ErrorAction SilentlyContinue)
  if (-not $tasks.Count) { '  (no tasks at this path on this build)'; continue }
  $tasks | Select-Object TaskName, State | Sort-Object TaskName | Format-Table -AutoSize
}

Write-Host '=== restore points ===' -ForegroundColor Cyan
# CreationTime سلسلة DMTF بإزاحة -000 (أي UTC). Get-ComputerRestorePoint لا يعرضها تحت PS7.
$rps = @(Get-CimInstance -Namespace 'root/default' -ClassName SystemRestore -ErrorAction SilentlyContinue |
         Sort-Object SequenceNumber)
if ($rps.Count) {
  $rps | Select-Object -Last 5 | Select-Object SequenceNumber, Description, RestorePointType,
    @{ n = 'CreatedUtc'; e = { Iso ([Management.ManagementDateTimeConverter]::ToDateTime($_.CreationTime).ToUniversalTime()) } } |
    Format-Table -AutoSize
} else { Write-Host '! no restore points visible (System Protection off, or not elevated)' -ForegroundColor Yellow }

Write-Host '=== storage ===' -ForegroundColor Cyan
$diskMap = @{}
foreach ($d in @(Get-PhysicalDisk -ErrorAction SilentlyContinue)) { $diskMap["$($d.DeviceId)"] = "$($d.MediaType)" }
Get-PhysicalDisk -ErrorAction SilentlyContinue |
  Select-Object DeviceId, FriendlyName, MediaType, @{ n = 'SizeGB'; e = { [math]::Round($_.Size / 1GB, 1) } } |
  Sort-Object DeviceId | Format-Table -AutoSize
$volRows = @(
  foreach ($part in @(Get-Partition -ErrorAction SilentlyContinue)) {
    $letter = "$($part.DriveLetter)".Trim([char]0)
    if (-not $letter) { continue }
    $vol = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
    [pscustomobject]@{
      Drive  = "${letter}:"
      Disk   = $part.DiskNumber
      Media  = $diskMap["$($part.DiskNumber)"]
      SizeGB = [math]::Round($part.Size / 1GB, 1)
      FreeGB = if ($vol) { [math]::Round($vol.SizeRemaining / 1GB, 1) } else { $null }
    }
  }
)
$volRows | Sort-Object Drive | Format-Table -AutoSize
foreach ($root in 'C:\Dev', 'D:\Dev', 'C:\Projects', 'D:\Projects') {
  if (-not (Test-Path $root)) { continue }
  $letter = $root.Substring(0, 1)
  $media = ($volRows | Where-Object { $_.Drive -eq "${letter}:" }).Media
  "workspace $root -> disk media: $media"
}

Write-Host '=== network ===' -ForegroundColor Cyan
Get-NetAdapter | Select-Object Name, InterfaceDescription, Status, ifIndex, LinkSpeed | Format-Table -AutoSize
Get-DnsClientServerAddress -AddressFamily IPv4 | Select-Object InterfaceAlias, ServerAddresses | Format-Table -AutoSize
Write-Host 'المنافذ المستمعة (لا علاقة لها بـ netstat -n الذي يعرض الجلسات الصادرة):' -ForegroundColor DarkCyan
Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
  Select-Object LocalAddress, LocalPort, OwningProcess,
    @{ n = 'Process'; e = { (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName } } |
  Sort-Object LocalPort -Unique | Format-Table -AutoSize

if ($OutFile) { Stop-Transcript | Out-Null }
