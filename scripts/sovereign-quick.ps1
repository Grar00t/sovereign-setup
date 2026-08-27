#requires -Version 5.1
[CmdletBinding()]
param(
  [switch]$DryRun,
  [switch]$RemoveApps,
  [switch]$IncludeOptionalTools,
  [switch]$NoRestorePoint,
  [string]$DevRoot    = 'D:\Dev',
  [string]$BackupRoot = 'C:\Backups\sovereign-setup'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Inv = [Globalization.CultureInfo]::InvariantCulture
$JournalSchema = 2
$script:fails = 0

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $DryRun) { throw 'شغّل PowerShell كمسؤول / Run as administrator.' }

# الطابع الزمني: UTC وتقويم ثابت. Get-Date -Format يتبع ثقافة الجلسة، وتحت ar-SA
# كتب الاسم هجرياً: journal-14480315-013014.json. لا تُعِد استخدام Get-Date -Format هنا.
# UTC + InvariantCulture. Get-Date -Format follows session culture and produced a Hijri file name.
$stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss', $Inv) + 'Z'

foreach ($d in @($BackupRoot, "$BackupRoot\logs", "$BackupRoot\state")) {
  if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}
$journalPath = Join-Path "$BackupRoot\state" "journal-$stamp.json"
Start-Transcript -Path (Join-Path "$BackupRoot\logs" "apply-$stamp.log") | Out-Null
$script:Journal = New-Object System.Collections.ArrayList

function Has($obj, [string]$name) {
  if ($null -eq $obj) { return $false }
  return ($obj.PSObject.Properties.Name -contains $name)
}
function Add-J([hashtable]$e) {
  $e['schema']     = $JournalSchema
  $e['appliedUtc'] = [DateTime]::UtcNow.ToString('o', $Inv)
  [void]$script:Journal.Add([pscustomobject]$e)
  ($script:Journal | ConvertTo-Json -Depth 6) | Set-Content -Path $journalPath -Encoding UTF8
}
function Say([string]$m, [string]$c = 'Gray') { Write-Host $m -ForegroundColor $c }
function Assert-Inv([string]$label, [bool]$ok) {
  if ($ok) { Say "PASS  $label" 'Green' } else { Say "FAIL  $label" 'Red'; $script:fails++ }
}

function Set-Reg {
  param([string]$Path, [string]$Name,
        [ValidateSet('DWord','String','ExpandString')][string]$Type = 'DWord', $Value)
  $keyExisted = Test-Path $Path
  $had = $false; $old = $null
  if ($keyExisted) {
    $p = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    if (Has $p $Name) { $had = $true; $old = $p.$Name }
  }
  if ($had -and "$old" -eq "$Value") { Say "=  $Path\$Name = $Value" 'DarkGray'; return }
  if ($DryRun) { Say "~  would set $Path\$Name = $Value" 'Yellow'; return }
  if (-not $keyExisted) { New-Item -Path $Path -Force | Out-Null }
  New-ItemProperty -Path $Path -Name $Name -PropertyType $Type -Value $Value -Force | Out-Null
  Add-J @{ kind='registry'; path=$Path; name=$Name; type=$Type; keyExisted=$keyExisted; hadValue=$had; oldValue=$old; newValue=$Value }
  Say "+  $Path\$Name = $Value" 'Green'
}

function Set-Svc {
  param([string]$Name, [ValidateSet('Disabled','Manual','Automatic')][string]$StartupType)
  $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
  if (-not $svc) { Say "!  service $Name absent" 'DarkYellow'; return }
  $ci = Get-CimInstance Win32_Service -Filter "Name='$Name'" -ErrorAction SilentlyContinue
  $mode = 'unknown'
  if ($ci) { $mode = "$($ci.StartMode)" }
  $wasRunning = ("$($svc.Status)" -eq 'Running')
  # Win32_Service يقول Auto لا Automatic. Win32_Service reports Auto, not Automatic.
  $modeTarget = @{ 'Disabled' = 'Disabled'; 'Manual' = 'Manual'; 'Automatic' = 'Auto' }[$StartupType]
  if ($mode -eq $modeTarget -and -not $wasRunning) { Say "=  service $Name already $StartupType and stopped" 'DarkGray'; return }
  if ($DryRun) { Say "~  would set service $Name -> $StartupType (now $mode/$($svc.Status))" 'Yellow'; return }
  Add-J @{ kind='service'; name=$Name; oldStartMode=$mode; newStartupType=$StartupType; wasRunning=$wasRunning }
  if ($mode -ne $modeTarget) {
    Set-Service -Name $Name -StartupType $StartupType
    Say "+  service $Name -> $StartupType (was $mode)" 'Green'
  }
  if ($wasRunning) {
    Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
    Say "+  service $Name stopped" 'Green'
  }
}

function Set-Task {
  param([string]$TaskPath, [string]$TaskName)
  $t = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
  if (-not $t) { Say "!  task $TaskName غير موجودة على هذا الإصدار / not present on this build" 'DarkYellow'; return }
  if ("$($t.State)" -eq 'Disabled') { Say "=  task $TaskName already disabled" 'DarkGray'; return }
  if ($DryRun) { Say "~  would disable task $TaskPath$TaskName" 'Yellow'; return }
  try {
    Disable-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop | Out-Null
    Add-J @{ kind='scheduledTask'; taskPath=$TaskPath; taskName=$TaskName; oldState="$($t.State)"; newState='Disabled' }
    Say "+  task $TaskName disabled" 'Green'
  } catch { Say "!  task $TaskName : $($_.Exception.Message)" 'Yellow' }
}

function Set-Env {
  param([string]$Name, [string]$Value)
  $old = [Environment]::GetEnvironmentVariable($Name, 'Machine')
  if ($old -eq $Value) { Say "=  env $Name already $Value" 'DarkGray'; return }
  if ($DryRun) { Say "~  would set env $Name = $Value (Machine)" 'Yellow'; return }
  [Environment]::SetEnvironmentVariable($Name, $Value, 'Machine')
  Add-J @{ kind='env'; name=$Name; scope='Machine'; hadValue=($null -ne $old); oldValue=$old; newValue=$Value }
  Say "+  env $Name = $Value" 'Green'
}

function Get-RestorePointMax {
  # عبر CIM لأن Get-ComputerRestorePoint غير موجود في PowerShell 7.
  # Via CIM because Get-ComputerRestorePoint does not exist in PowerShell 7.
  try {
    $rp = @(Get-CimInstance -Namespace 'root/default' -ClassName 'SystemRestore' -ErrorAction Stop)
    if ($rp.Count -eq 0) { return 0 }
    return [int](($rp | Measure-Object -Property SequenceNumber -Maximum).Maximum)
  } catch { return -1 }
}

function New-RP {
  param([string]$Description)
  $before = Get-RestorePointMax
  if ($before -lt 0) { Say '!  System Restore غير قابل للاستعلام / System Restore not queryable' 'Yellow'; return $false }
  if ($DryRun) { Say "~  would create restore point '$Description' (last sequence: $before)" 'Yellow'; return $true }
  $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  if (-not (Test-Path $ps51)) { Say '!  محرّك 5.1 غير موجود / Windows PowerShell 5.1 engine missing' 'Yellow'; return $false }
  $freqKey  = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
  $freqName = 'SystemRestorePointCreationFrequency'
  $freqHad = $false; $freqOld = $null
  $p = Get-ItemProperty -Path $freqKey -Name $freqName -ErrorAction SilentlyContinue
  if (Has $p $freqName) { $freqHad = $true; $freqOld = $p.$freqName }
  try {
    # القيمة تُعاد إلى ما كانت عليه في finally، لذلك لا تُسجَّل في الـ journal.
    # Reverted in finally, so it is deliberately not journaled.
    New-ItemProperty -Path $freqKey -Name $freqName -PropertyType DWord -Value 0 -Force | Out-Null
    $cmd = "Enable-ComputerRestore -Drive 'C:\'; Checkpoint-Computer -Description '$Description' -RestorePointType 'MODIFY_SETTINGS'"
    & $ps51 -NoProfile -NonInteractive -Command $cmd 2>&1 | ForEach-Object { Say "   $_" 'DarkGray' }
  } finally {
    if ($freqHad) { New-ItemProperty -Path $freqKey -Name $freqName -PropertyType DWord -Value $freqOld -Force | Out-Null }
    else { Remove-ItemProperty -Path $freqKey -Name $freqName -ErrorAction SilentlyContinue }
  }
  $after = Get-RestorePointMax
  if ($after -gt $before) { Say "+  restore point created (sequence $after)" 'Green'; return $true }
  Say "!  لم تُنشأ نقطة استعادة / no new restore point (sequence still $after)" 'Yellow'
  return $false
}

# ---------- 0. restore point ----------
Say "`n=== 0. نقطة استعادة / restore point ===" 'Cyan'
$rpOk = New-RP -Description "sovereign-quick $stamp"
if (-not $rpOk -and -not $DryRun) {
  if ($NoRestorePoint) {
    Say '!  المتابعة بلا نقطة استعادة بطلب صريح / continuing without a restore point (-NoRestorePoint)' 'Yellow'
  } else {
    Stop-Transcript | Out-Null
    throw 'توقّف: لم تُنشأ نقطة استعادة. أعد المحاولة أو مرّر -NoRestorePoint للمتابعة بوعي. / Stopped: no restore point was created. Retry, or pass -NoRestorePoint to proceed deliberately.'
  }
}

# ---------- 1. toolchain ----------
Say "`n=== 1. سلسلة الأدوات / toolchain ===" 'Cyan'
$tools = @(
  @{ Id='Git.Git';                Probe='git'    },
  @{ Id='Microsoft.PowerShell';   Probe='pwsh'   },
  @{ Id='Microsoft.DotNet.SDK.9'; Probe='dotnet' },
  @{ Id='Kitware.CMake';          Probe='cmake'  },
  @{ Id='Ninja-build.Ninja';      Probe='ninja'  }
)
if ($IncludeOptionalTools) {
  $tools += @{ Id='Python.Python.3.12';         Probe='py'     }
  $tools += @{ Id='Microsoft.VisualStudioCode'; Probe='code'   }
  $tools += @{ Id='Rustlang.Rustup';            Probe='rustup' }
}
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
  Say '!  winget غير متاح في هذه الجلسة — حدّث App Installer من Microsoft Store' 'Yellow'
} else {
  foreach ($t in $tools) {
    $have = Get-Command $t.Probe -ErrorAction SilentlyContinue
    # ملاحظة: أسماء مثل python قد تكون كعب Microsoft Store بحجم صفر بايت.
    # Note: names like python can be a 0-byte Microsoft Store execution alias.
    if ($have -and (Has $have 'Source') -and $have.Source -like '*\Microsoft\WindowsApps\*') {
      $fi = Get-Item -LiteralPath $have.Source -ErrorAction SilentlyContinue
      if ($fi -and $fi.Length -eq 0) { $have = $null }
    }
    if ($have) { Say "=  $($t.Id) present ($($t.Probe))" 'DarkGray'; continue }
    if ($DryRun) { Say "~  would install $($t.Id)" 'Yellow'; continue }
    Say "+  installing $($t.Id)" 'Green'
    & winget install --id $t.Id --exact --source winget --accept-package-agreements --accept-source-agreements --silent
    Add-J @{ kind='winget'; id=$t.Id; probe=$t.Probe; exitCode=$LASTEXITCODE }
  }
}

# ---------- 2. OneDrive ----------
Say "`n=== 2. OneDrive ===" 'Cyan'
# System32\OneDriveSetup.exe يبقى موجوداً بعد الإزالة، فوجوده وحده لا يعني أن العميل مثبَّت.
# System32\OneDriveSetup.exe survives uninstall, so its presence alone does not mean the client is installed.
$odUserExe = Join-Path $env:LOCALAPPDATA 'Microsoft\OneDrive\OneDrive.exe'
$odSetups = @("$env:SystemRoot\SysWOW64\OneDriveSetup.exe", "$env:SystemRoot\System32\OneDriveSetup.exe") |
            Where-Object { Test-Path $_ }
$odRunning = (@(Get-Process OneDrive -ErrorAction SilentlyContinue).Count -gt 0)
$odInstalled = ((Test-Path $odUserExe) -or $odRunning)
if (-not $odSetups) { Say '=  OneDriveSetup.exe not found' 'DarkGray' }
elseif (-not $odInstalled) { Say '=  عميل OneDrive غير مثبَّت للمستخدم، لا شيء لإزالته / per-user OneDrive client absent, nothing to uninstall' 'DarkGray' }
elseif ($DryRun) { Say "~  would uninstall OneDrive via $($odSetups -join ', ')" 'Yellow' }
else {
  Get-Process OneDrive -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  foreach ($s in $odSetups) { Start-Process -FilePath $s -ArgumentList '/uninstall' -Wait }
  Add-J @{ kind='onedrive'; setups=$odSetups }
  Say '+  OneDrive uninstalled (الملفات المحلية تبقى كما هي)' 'Green'
}
Set-Reg -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' -Name 'DisableFileSyncNGSC' -Value 1

# ---------- 3. privacy / assistants ----------
Say "`n=== 3. الخصوصية والمساعدات / privacy ===" 'Cyan'
# AllowTelemetry = 1 هو الحد الأدنى المدعوم في Pro. القيمة 0 تُقبل شكلاً وتُعامل كـ 1.
# AllowTelemetry = 1 is the Pro floor. 0 is accepted but treated as 1 outside Enterprise/Education.
Set-Reg -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Name 'AllowTelemetry' -Value 1
Set-Reg -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Name 'AllowDeviceNameInTelemetry' -Value 0
Set-Reg -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Name 'DoNotShowFeedbackNotifications' -Value 1
Set-Reg -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' -Name 'TurnOffWindowsCopilot' -Value 1
Set-Reg -Path 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' -Name 'TurnOffWindowsCopilot' -Value 1
Set-Reg -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'      -Name 'DisableAIDataAnalysis' -Value 1
Set-Reg -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'ShowCopilotButton' -Value 0
Set-Reg -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' -Name 'DisableWindowsConsumerFeatures' -Value 1
Set-Reg -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' -Name 'DisableCloudOptimizedContent' -Value 1
Set-Reg -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' -Name 'DisableConsumerAccountStateContent' -Value 1
Set-Reg -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo' -Name 'DisabledByGroupPolicy' -Value 1
Set-Reg -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' -Name 'Enabled' -Value 0
Set-Reg -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' -Name 'DisableWebSearch' -Value 1
Set-Reg -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' -Name 'ConnectedSearchUseWeb' -Value 0
Set-Reg -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' -Name 'EnableDynamicContentInWSB' -Value 0
Set-Reg -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' -Name 'AllowNewsAndInterests' -Value 0
Set-Reg -Path 'HKCU:\Software\Microsoft\Siuf\Rules' -Name 'NumberOfSIUFInPeriod' -Value 0
Set-Reg -Path 'HKCU:\Software\Microsoft\InputPersonalization' -Name 'RestrictImplicitTextCollection' -Value 1
Set-Reg -Path 'HKCU:\Software\Microsoft\InputPersonalization' -Name 'RestrictImplicitInkCollection' -Value 1
Set-Reg -Path 'HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization' -Name 'AllowLinguisticDataCollection' -Value 0

$cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
foreach ($n in 'SilentInstalledAppsEnabled','PreInstalledAppsEnabled','OemPreInstalledAppsEnabled',
               'SystemPaneSuggestionsEnabled','SoftLandingEnabled','RotatingLockScreenOverlayEnabled',
               'SubscribedContent-338388Enabled','SubscribedContent-338389Enabled','SubscribedContent-338393Enabled',
               'SubscribedContent-353694Enabled','SubscribedContent-353696Enabled','SubscribedContent-310093Enabled') {
  Set-Reg -Path $cdm -Name $n -Value 0
}
Say '   مفاتيح HKCU تُطبَّق على المستخدم الحالي فقط / HKCU values apply to the current user only' 'DarkGray'

Set-Svc -Name 'DiagTrack'        -StartupType Disabled
Set-Svc -Name 'dmwappushservice' -StartupType Disabled

# مهام التلمتري فقط. تُترك بقصد: PcaPatchDbTask و SdbinstMergeDbTask (صيانة قاعدة التوافق)،
# StartupAppTask (قائمة بدء التشغيل في مدير المهام)، CloudExperienceHost\CreateObjectTask (OOBE).
# Telemetry tasks only. Deliberately untouched: PcaPatchDbTask, SdbinstMergeDbTask (shim-database
# maintenance), StartupAppTask (Task Manager startup list), CloudExperienceHost\CreateObjectTask (OOBE).
$ceipTasks = @(
  @{ Path='\Microsoft\Windows\Application Experience\'; Name='Microsoft Compatibility Appraiser' },
  @{ Path='\Microsoft\Windows\Application Experience\'; Name='Microsoft Compatibility Appraiser Exp' },
  @{ Path='\Microsoft\Windows\Application Experience\'; Name='ProgramDataUpdater' },
  @{ Path='\Microsoft\Windows\Application Experience\'; Name='MareBackup' },
  @{ Path='\Microsoft\Windows\Customer Experience Improvement Program\'; Name='Consolidator' },
  @{ Path='\Microsoft\Windows\Customer Experience Improvement Program\'; Name='UsbCeip' },
  @{ Path='\Microsoft\Windows\Feedback\Siuf\'; Name='DmClient' },
  @{ Path='\Microsoft\Windows\Feedback\Siuf\'; Name='DmClientOnScenarioDownload' }
)
foreach ($ct in $ceipTasks) { Set-Task -TaskPath $ct.Path -TaskName $ct.Name }

Set-Env -Name 'DOTNET_CLI_TELEMETRY_OPTOUT' -Value '1'
Set-Env -Name 'POWERSHELL_TELEMETRY_OPTOUT' -Value '1'

# ---------- 4. optional consumer apps ----------
Say "`n=== 4. تطبيقات استهلاكية / consumer apps (-RemoveApps) ===" 'Cyan'
$consumerApps = @(
  'Microsoft.BingNews','Microsoft.BingWeather','Microsoft.MicrosoftSolitaireCollection',
  'Microsoft.GamingApp','Microsoft.MicrosoftOfficeHub','MicrosoftCorporationII.MicrosoftFamily',
  'Clipchamp.Clipchamp','Microsoft.Todos','Microsoft.WindowsFeedbackHub','Microsoft.PowerAutomateDesktop'
)
if (-not $RemoveApps) { Say "=  skipped. القائمة: $($consumerApps -join ', ')" 'DarkGray' }
else {
  foreach ($n in $consumerApps) {
    foreach ($p in @(Get-AppxPackage -Name $n -ErrorAction SilentlyContinue)) {
      if ($DryRun) { Say "~  would remove $($p.PackageFullName)" 'Yellow'; continue }
      try {
        Remove-AppxPackage -Package $p.PackageFullName -ErrorAction Stop
        Add-J @{ kind='appx'; packageName=$p.Name; packageFullName=$p.PackageFullName }
        Say "-  removed $($p.Name)" 'Green'
      } catch { Say "!  $($p.Name): $($_.Exception.Message)" 'Yellow' }
    }
    foreach ($pp in @(Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -eq $n })) {
      if ($DryRun) { Say "~  would deprovision $($pp.PackageName)" 'Yellow'; continue }
      try {
        Remove-AppxProvisionedPackage -Online -PackageName $pp.PackageName -ErrorAction Stop | Out-Null
        Add-J @{ kind='appxProvisioned'; displayName=$pp.DisplayName; packageName=$pp.PackageName }
        Say "-  deprovisioned $($pp.DisplayName)" 'Green'
      } catch { Say "!  $($pp.DisplayName): $($_.Exception.Message)" 'Yellow' }
    }
  }
}

# ---------- 5. workspace ----------
Say "`n=== 5. شجرة العمل / workspace ===" 'Cyan'
$folders = @("$DevRoot\src", "$DevRoot\tools", 'D:\Projects', $BackupRoot)
foreach ($f in $folders) {
  if (Test-Path $f) { Say "=  $f" 'DarkGray'; continue }
  if ($DryRun) { Say "~  would create $f" 'Yellow'; continue }
  New-Item -ItemType Directory -Path $f -Force | Out-Null
  Add-J @{ kind='folder'; path=$f }
  Say "+  $f" 'Green'
}
Set-Reg -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'HideFileExt' -Value 0

# ---------- 6. verify ----------
Say "`n=== 6. تحقق / verify ===" 'Cyan'
if ($DryRun) { Say '   تشغيل جاف: ثوابت الخصوصية قد تفشل لأن لا شيء طُبِّق / dry run: privacy invariants may fail because nothing was applied' 'DarkGray' }
$svcModes = @{}
foreach ($n in 'DiagTrack','dmwappushservice','wuauserv','WinDefend','mpssvc') {
  $ci = Get-CimInstance Win32_Service -Filter "Name='$n'" -ErrorAction SilentlyContinue
  if ($ci) { $svcModes[$n] = "$($ci.StartMode)" } else { $svcModes[$n] = 'absent' }
}
Get-Service DiagTrack, dmwappushservice, wuauserv, WinDefend, mpssvc -ErrorAction SilentlyContinue |
  Select-Object Name, Status, StartType | Format-Table -AutoSize | Out-Host
# الثابت هو نمط البدء لا Status: wuauserv خدمة عند الطلب وتتبدّل بين Running و Stopped بطبيعتها.
# The invariant is StartMode, not Status: wuauserv is demand-start and legitimately toggles.
Assert-Inv "DiagTrack StartMode = Disabled (now $($svcModes['DiagTrack']))" ($svcModes['DiagTrack'] -eq 'Disabled')
Assert-Inv "dmwappushservice StartMode = Disabled (now $($svcModes['dmwappushservice']))" ($svcModes['dmwappushservice'] -eq 'Disabled')
Assert-Inv "wuauserv StartMode not Disabled (now $($svcModes['wuauserv']))" ($svcModes['wuauserv'] -ne 'Disabled')
Assert-Inv "WinDefend StartMode = Auto (now $($svcModes['WinDefend']))" ($svcModes['WinDefend'] -eq 'Auto')
Assert-Inv "mpssvc StartMode = Auto (now $($svcModes['mpssvc']))" ($svcModes['mpssvc'] -eq 'Auto')
foreach ($fp in @(Get-NetFirewallProfile -ErrorAction SilentlyContinue)) {
  Assert-Inv "firewall profile $($fp.Name) enabled" ("$($fp.Enabled)" -eq 'True')
}
foreach ($c in 'git','pwsh','dotnet','cmake','ninja') {
  $f = Get-Command $c -ErrorAction SilentlyContinue
  if ($f) { "[x] $c -> $((& $c --version 2>&1 | Select-Object -First 1))" } else { "[ ] $c" }
}
if ($script:fails -gt 0) { Say "`nثوابت فاشلة: $script:fails / failing invariants: $script:fails" 'Red' }
else { Say "`nكل الثوابت سليمة / all invariants hold" 'Green' }
Say "`njournal: $journalPath" 'Cyan'
Say 'أعد تشغيل explorer.exe أو الجهاز لتطبيق تغييرات الواجهة.' 'Cyan'
Stop-Transcript | Out-Null
