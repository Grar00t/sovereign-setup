#requires -Version 5.1
[CmdletBinding()]
param(
  [switch]$DryRun,
  [switch]$RemoveApps,
  [switch]$IncludeOptionalTools,
  [string]$DevRoot    = 'D:\Dev',
  [string]$BackupRoot = 'C:\Backups\sovereign-setup'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'شغّل PowerShell كمسؤول / Run as administrator.' }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
foreach ($d in @($BackupRoot, "$BackupRoot\logs", "$BackupRoot\state")) {
  if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}
$journalPath = Join-Path "$BackupRoot\state" "journal-$stamp.json"
Start-Transcript -Path (Join-Path "$BackupRoot\logs" "apply-$stamp.log") | Out-Null
$script:Journal = New-Object System.Collections.ArrayList

function Add-J([hashtable]$e) {
  $e['appliedUtc'] = (Get-Date).ToUniversalTime().ToString('o')
  [void]$script:Journal.Add([pscustomobject]$e)
  ($script:Journal | ConvertTo-Json -Depth 6) | Set-Content -Path $journalPath -Encoding UTF8
}
function Say([string]$m, [string]$c = 'Gray') { Write-Host $m -ForegroundColor $c }

function Set-Reg {
  param([string]$Path, [string]$Name,
        [ValidateSet('DWord','String','ExpandString')][string]$Type = 'DWord', $Value)
  $keyExisted = Test-Path $Path
  $had = $false; $old = $null
  if ($keyExisted) {
    $p = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    if ($p -and ($p.PSObject.Properties.Name -contains $Name)) { $had = $true; $old = $p.$Name }
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
  $mode = (Get-CimInstance Win32_Service -Filter "Name='$Name'").StartMode
  $wasRunning = ($svc.Status -eq 'Running')
  if ($mode -eq 'Disabled' -and -not $wasRunning) { Say "=  service $Name already disabled" 'DarkGray'; return }
  if ($DryRun) { Say "~  would set service $Name -> $StartupType (now $mode/$($svc.Status))" 'Yellow'; return }
  Set-Service -Name $Name -StartupType $StartupType
  if ($wasRunning) { Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue }
  Add-J @{ kind='service'; name=$Name; oldStartMode=$mode; newStartupType=$StartupType; wasRunning=$wasRunning }
  Say "+  service $Name -> $StartupType" 'Green'
}

function Set-Task {
  param([string]$TaskPath, [string]$TaskName)
  $t = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
  if (-not $t) { return }
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

function New-RP {
  param([string]$Description)
  if ($DryRun) { Say "~  would create restore point '$Description'" 'Yellow'; return }
  try {
    Enable-ComputerRestore -Drive 'C:\' -ErrorAction SilentlyContinue
    Checkpoint-Computer -Description $Description -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
    Say '+  restore point created' 'Green'
  } catch { Say "!  restore point skipped: $($_.Exception.Message)" 'Yellow' }
}

# ---------- 0. restore point ----------
Say "`n=== 0. نقطة استعادة / restore point ===" 'Cyan'
New-RP -Description "sovereign-quick $stamp"

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
    if ($have) { Say "=  $($t.Id) present ($($t.Probe))" 'DarkGray'; continue }
    if ($DryRun) { Say "~  would install $($t.Id)" 'Yellow'; continue }
    Say "+  installing $($t.Id)" 'Green'
    & winget install --id $t.Id --exact --source winget --accept-package-agreements --accept-source-agreements --silent
    Add-J @{ kind='winget'; id=$t.Id; probe=$t.Probe; exitCode=$LASTEXITCODE }
  }
}

# ---------- 2. OneDrive ----------
Say "`n=== 2. OneDrive ===" 'Cyan'
$odSetups = @("$env:SystemRoot\SysWOW64\OneDriveSetup.exe", "$env:SystemRoot\System32\OneDriveSetup.exe") |
            Where-Object { Test-Path $_ }
if (-not $odSetups) { Say '=  OneDriveSetup.exe not found' 'DarkGray' }
elseif ($DryRun)   { Say "~  would uninstall OneDrive via $($odSetups -join ', ')" 'Yellow' }
else {
  Get-Process OneDrive -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  foreach ($s in $odSetups) { Start-Process -FilePath $s -ArgumentList '/uninstall' -Wait }
  Add-J @{ kind='onedrive'; setups=$odSetups }
  Say '+  OneDrive uninstalled (الملفات المحلية تبقى كما هي)' 'Green'
}
Set-Reg -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' -Name 'DisableFileSyncNGSC' -Value 1

# ---------- 3. privacy / assistants ----------
Say "`n=== 3. الخصوصية والمساعدات / privacy ===" 'Cyan'
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

Set-Svc -Name 'DiagTrack'        -StartupType Disabled
Set-Svc -Name 'dmwappushservice' -StartupType Disabled

Set-Task -TaskPath '\Microsoft\Windows\Application Experience\' -TaskName 'Microsoft Compatibility Appraiser'
Set-Task -TaskPath '\Microsoft\Windows\Application Experience\' -TaskName 'ProgramDataUpdater'
Set-Task -TaskPath '\Microsoft\Windows\Customer Experience Improvement Program\' -TaskName 'Consolidator'
Set-Task -TaskPath '\Microsoft\Windows\Customer Experience Improvement Program\' -TaskName 'UsbCeip'
Set-Task -TaskPath '\Microsoft\Windows\Feedback\Siuf\' -TaskName 'DmClient'
Set-Task -TaskPath '\Microsoft\Windows\Feedback\Siuf\' -TaskName 'DmClientOnScenarioDownload'

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
Get-Service DiagTrack, dmwappushservice, wuauserv, WinDefend, mpssvc |
  Select-Object Name, Status, StartType | Format-Table -AutoSize
Get-NetFirewallProfile | Select-Object Name, Enabled | Format-Table -AutoSize
foreach ($c in 'git','pwsh','dotnet','cmake','ninja') {
  $f = Get-Command $c -ErrorAction SilentlyContinue
  if ($f) { "[x] $c -> $((& $c --version 2>&1 | Select-Object -First 1))" } else { "[ ] $c" }
}
Say "`njournal: $journalPath" 'Cyan'
Say 'أعد تشغيل explorer.exe أو الجهاز لتطبيق تغييرات الواجهة.' 'Cyan'
Stop-Transcript | Out-Null
