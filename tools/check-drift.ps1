#requires -Version 5.1
<#
.SYNOPSIS
  State-drift check for the sovereign-setup baseline. Read-only unless -Record.

.DESCRIPTION
  Three independent jobs:
    1. Hard security invariants, asserted with no baseline file needed.
    2. Volatile facts that must be asserted but never compared: Defender signature age.
    3. Baseline comparison for privacy policy values, service start types,
       scheduled task states and machine environment variables.

  Design note on wuauserv, deliberately not asserted on Status:
    wuauserv is a demand-start service. Windows starts it and stops it on its own,
    so Status = 'Stopped' is normal and is NOT drift. The invariant that matters is
    StartType, which must never be Disabled. An alert on Status would fire on a
    healthy machine and train the owner to ignore the alert, which is worse than
    having no alert at all. Status is still collected and printed as information.

  Design note on what may not enter the baseline:
    Anything that changes by design must never be stored in the baseline snapshot,
    or every later check reports drift and the report becomes noise. Defender
    signature version, date and age therefore live in a separate volatile map and
    are asserted as invariants only. Observed live: signatures were 5 days 10 hours
    stale while the engine reported AntivirusEnabled True, with nothing asserting it.

  Exit codes: 0 = clean, 2 = drift or invariant failure, 3 = baseline missing.
#>
[CmdletBinding()]
param(
  [switch]$Record,
  [string]$BaselinePath = 'C:\Backups\sovereign-baseline.json'
)
Set-StrictMode -Version Latest
$Inv = [Globalization.CultureInfo]::InvariantCulture

# ConvertFrom-Json يحوّل نص ISO إلى DateTime، ثم يطبعه -f بتقويم الجلسة.
# هكذا ظهر 'baseline recorded: 14/03/48 10:53:49 م' في ملف مهمته كشف الانحراف.
# ConvertFrom-Json turns the ISO string into a DateTime and -f then formats it with the
# thread calendar. Every timestamp printed by this script goes through here instead.
function Format-Utc {
  param($Value)
  if ($null -eq $Value -or "$Value" -eq '') { return '<unknown>' }
  try { return ([datetime]$Value).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss', $Inv) + ' UTC' }
  catch { return "$Value" }
}

$services = @('wuauserv','WinDefend','mpssvc','DiagTrack','dmwappushservice','DoSvc','PcaSvc','WerSvc')

$policyValues = @(
  @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Name='AllowTelemetry' }
  @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Name='AllowDeviceNameInTelemetry' }
  @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Name='DoNotShowFeedbackNotifications' }
  @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot'; Name='TurnOffWindowsCopilot' }
  @{ Path='HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot'; Name='TurnOffWindowsCopilot' }
  @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name='DisableAIDataAnalysis' }
  @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name='DisableWindowsConsumerFeatures' }
  @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name='DisableCloudOptimizedContent' }
  @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name='DisableConsumerAccountStateContent' }
  @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo'; Name='DisabledByGroupPolicy' }
  @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name='DisableWebSearch' }
  @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name='ConnectedSearchUseWeb' }
  @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name='EnableDynamicContentInWSB' }
  @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Dsh'; Name='AllowNewsAndInterests' }
  @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization'; Name='AllowLinguisticDataCollection' }
  @{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive'; Name='DisableFileSyncNGSC' }
  @{ Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; Name='Enabled' }
  @{ Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name='ShowCopilotButton' }
  @{ Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name='HideFileExt' }
  @{ Path='HKCU:\Software\Microsoft\Siuf\Rules'; Name='NumberOfSIUFInPeriod' }
  @{ Path='HKCU:\Software\Microsoft\InputPersonalization'; Name='RestrictImplicitTextCollection' }
  @{ Path='HKCU:\Software\Microsoft\InputPersonalization'; Name='RestrictImplicitInkCollection' }
)
$cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
foreach ($n in 'SilentInstalledAppsEnabled','PreInstalledAppsEnabled','OemPreInstalledAppsEnabled',
               'SystemPaneSuggestionsEnabled','SoftLandingEnabled','RotatingLockScreenOverlayEnabled',
               'SubscribedContent-338388Enabled','SubscribedContent-338389Enabled','SubscribedContent-338393Enabled',
               'SubscribedContent-353694Enabled','SubscribedContent-353696Enabled','SubscribedContent-310093Enabled') {
  $policyValues += @{ Path = $cdm; Name = $n }
}

$taskList = @(
  @{ Path='\Microsoft\Windows\Application Experience\'; Name='Microsoft Compatibility Appraiser' }
  @{ Path='\Microsoft\Windows\Application Experience\'; Name='Microsoft Compatibility Appraiser Exp' }
  @{ Path='\Microsoft\Windows\Application Experience\'; Name='ProgramDataUpdater' }
  @{ Path='\Microsoft\Windows\Customer Experience Improvement Program\'; Name='Consolidator' }
  @{ Path='\Microsoft\Windows\Customer Experience Improvement Program\'; Name='UsbCeip' }
  @{ Path='\Microsoft\Windows\Feedback\Siuf\'; Name='DmClient' }
  @{ Path='\Microsoft\Windows\Feedback\Siuf\'; Name='DmClientOnScenarioDownload' }
)

# Rule = Equal | NotEqual | AtMost. Asserted without any baseline file.
$hardInvariants = @(
  @{ Key='svc-start:wuauserv';         Rule='NotEqual'; Value='Disabled';  Why='Windows Update must remain startable' }
  @{ Key='svc-start:WinDefend';        Rule='Equal';    Value='Automatic'; Why='Defender start type' }
  @{ Key='svc-status:WinDefend';       Rule='Equal';    Value='Running';   Why='Defender must be running' }
  @{ Key='svc-start:mpssvc';           Rule='Equal';    Value='Automatic'; Why='Firewall service start type' }
  @{ Key='svc-status:mpssvc';          Rule='Equal';    Value='Running';   Why='Firewall service must be running' }
  @{ Key='fw:Domain';                  Rule='Equal';    Value='True';      Why='Firewall profile Domain' }
  @{ Key='fw:Private';                 Rule='Equal';    Value='True';      Why='Firewall profile Private' }
  @{ Key='fw:Public';                  Rule='Equal';    Value='True';      Why='Firewall profile Public' }
  @{ Key='mp:AntivirusEnabled';        Rule='Equal';    Value='True';      Why='Antivirus engine enabled' }
  @{ Key='mp:SignatureAgeDays';        Rule='AtMost';   Value='7';         Why='Signature freshness: fix with Update-MpSignature' }
  @{ Key='svc-start:DiagTrack';        Rule='Equal';    Value='Disabled';  Why='Telemetry service stays disabled' }
  @{ Key='svc-start:dmwappushservice'; Rule='Equal';    Value='Disabled';  Why='WAP push service stays disabled' }
)

function Get-RegString {
  param([string]$Path, [string]$Name)
  if (-not (Test-Path -LiteralPath $Path)) { return '<no-key>' }
  $prop = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
  if ($prop -and ($prop.PSObject.Properties.Name -contains $Name)) { return "$($prop.$Name)" }
  return '<absent>'
}

function New-StateSnapshot {
  $state = [ordered]@{}

  foreach ($s in $services) {
    $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
    if (-not $svc) {
      $state["svc-start:$s"]  = '<absent>'
      $state["svc-status:$s"] = '<absent>'
      continue
    }
    $cim  = Get-CimInstance -ClassName Win32_Service -Filter ("Name='{0}'" -f $s) -ErrorAction SilentlyContinue
    $mode = ''
    if ($cim) { $mode = "$($cim.StartMode)" }
    if ($mode -eq 'Auto') { $mode = 'Automatic' }
    $state["svc-start:$s"]  = $mode
    $state["svc-status:$s"] = "$($svc.Status)"
  }

  foreach ($p in @(Get-NetFirewallProfile -ErrorAction SilentlyContinue)) {
    $state["fw:$($p.Name)"] = "$([bool]$p.Enabled)"
  }

  try {
    $mp = Get-MpComputerStatus -ErrorAction Stop
    $state['mp:AntivirusEnabled']          = "$([bool]$mp.AntivirusEnabled)"
    $state['mp:RealTimeProtectionEnabled'] = "$([bool]$mp.RealTimeProtectionEnabled)"
  } catch {
    $state['mp:AntivirusEnabled']          = '<unavailable>'
    $state['mp:RealTimeProtectionEnabled'] = '<unavailable>'
  }

  foreach ($r in $policyValues) {
    $state["reg:$($r.Path)\$($r.Name)"] = (Get-RegString -Path $r.Path -Name $r.Name)
  }

  foreach ($t in $taskList) {
    $task = Get-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction SilentlyContinue
    if ($task) { $state["task:$($t.Path)$($t.Name)"] = "$($task.State)" }
    else       { $state["task:$($t.Path)$($t.Name)"] = '<absent>' }
  }

  foreach ($e in 'DOTNET_CLI_TELEMETRY_OPTOUT','POWERSHELL_TELEMETRY_OPTOUT') {
    $v = [Environment]::GetEnvironmentVariable($e, 'Machine')
    if ($null -eq $v) { $state["env:$e"] = '<absent>' } else { $state["env:$e"] = "$v" }
  }

  return $state
}

# حقائق متغيّرة بطبيعتها: تُؤكَّد ولا تُخزَّن، وإلا صار كل فحص لاحق انحرافاً.
# Volatile facts: asserted, never stored, or every later check would report drift.
function New-VolatileFacts {
  $live = [ordered]@{}
  try {
    $mp   = Get-MpComputerStatus -ErrorAction Stop
    $when = $mp.AntivirusSignatureLastUpdated
    if ($when) {
      $days = [int][math]::Floor(((Get-Date) - $when).TotalDays)
      $live['mp:SignatureAgeDays'] = $days.ToString($Inv)
      $live['mp:SignatureUpdated'] = (Format-Utc $when)
      $live['mp:SignatureVersion'] = "$($mp.AntivirusSignatureVersion)"
    } else {
      foreach ($k in 'mp:SignatureAgeDays','mp:SignatureUpdated','mp:SignatureVersion') { $live[$k] = '<unknown>' }
    }
  } catch {
    foreach ($k in 'mp:SignatureAgeDays','mp:SignatureUpdated','mp:SignatureVersion') { $live[$k] = '<unavailable>' }
  }
  return $live
}

$now = New-StateSnapshot

if ($Record) {
  $dir = Split-Path -Parent $BaselinePath
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $doc = [pscustomobject]@{
    schema     = 'sovereign-setup/baseline@1'
    createdUtc = (Get-Date).ToUniversalTime().ToString('o', $Inv)
    build      = ('{0}.{1}' -f (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuild,
                               (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').UBR)
    state      = [pscustomobject]$now
  }
  ($doc | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $BaselinePath -Encoding UTF8
  Write-Host ("+  baseline recorded: {0} ({1} keys) at {2}" -f $BaselinePath, $now.Count, (Format-Utc $doc.createdUtc)) -ForegroundColor Green
  Write-Host '+  تم تسجيل خط الأساس. أي انحراف لاحق يُقارن به.' -ForegroundColor Green
  exit 0
}

$live = New-VolatileFacts
$failures = 0

Write-Host '=== hard invariants / الثوابت الأمنية ===' -ForegroundColor Cyan
$invRows = foreach ($i in $hardInvariants) {
  $actual = '<not-collected>'
  if     ($live.Contains($i.Key)) { $actual = "$($live[$i.Key])" }
  elseif ($now.Contains($i.Key))  { $actual = "$($now[$i.Key])"  }
  $ok = switch ($i.Rule) {
    'Equal'    { $actual -eq $i.Value }
    'NotEqual' { $actual -ne $i.Value }
    'AtMost'   {
      $parsed = 0
      if ([int]::TryParse($actual, [ref]$parsed)) { $parsed -le [int]$i.Value } else { $false }
    }
    default    { $false }
  }
  if (-not $ok) { $failures++ }
  [pscustomobject]@{
    Result   = if ($ok) { 'PASS' } else { 'FAIL' }
    Key      = $i.Key
    Expected = ('{0} {1}' -f $i.Rule, $i.Value)
    Actual   = $actual
    Why      = $i.Why
  }
}
$invRows | Format-Table -AutoSize

# معلوماتي فقط، ليس ثابتاً. راجع ملاحظة التصميم في الرأس.
# Informational only. Not an invariant. See the design note in the header.
$wuStatus = '<absent>'
if ($now.Contains('svc-status:wuauserv')) { $wuStatus = "$($now['svc-status:wuauserv'])" }
Write-Host ("i  wuauserv Status = {0} (demand-start: Stopped is normal, StartType is the invariant)" -f $wuStatus) -ForegroundColor DarkCyan
Write-Host  'i  حالة wuauserv معلوماتية فقط: الخدمة تعمل عند الطلب، والثابت الحقيقي هو StartType.' -ForegroundColor DarkCyan
Write-Host ("i  Defender signatures: version {0}, published {1}" -f $live['mp:SignatureVersion'], $live['mp:SignatureUpdated']) -ForegroundColor DarkCyan

if (-not (Test-Path -LiteralPath $BaselinePath)) {
  Write-Host ''
  Write-Host ("!  no baseline at {0}. Run: .\tools\check-drift.ps1 -Record" -f $BaselinePath) -ForegroundColor Yellow
  Write-Host  '!  لا يوجد خط أساس مسجل، فلا مقارنة ممكنة.' -ForegroundColor Yellow
  if ($failures) { exit 2 }
  exit 3
}

$doc = Get-Content -LiteralPath $BaselinePath -Raw -Encoding UTF8 | ConvertFrom-Json
$baseState = $doc.state
$driftRows = @()
foreach ($key in @($now.Keys)) {
  $was = '<not-in-baseline>'
  if ($baseState.PSObject.Properties.Name -contains $key) { $was = "$($baseState.$key)" }
  $is = "$($now[$key])"
  if ($was -ne $is) {
    $driftRows += [pscustomobject]@{ Key = $key; Baseline = $was; Current = $is }
  }
}

Write-Host ''
Write-Host '=== drift vs baseline / الانحراف عن خط الأساس ===' -ForegroundColor Cyan
Write-Host ("baseline recorded: {0}" -f (Format-Utc $doc.createdUtc)) -ForegroundColor DarkGray
if (-not $driftRows.Count) {
  Write-Host ("=  no drift across {0} keys" -f $now.Count) -ForegroundColor Green
  Write-Host  '=  لا انحراف.' -ForegroundColor Green
} else {
  $driftRows | Format-Table -AutoSize
  Write-Host ("!  {0} key(s) drifted" -f $driftRows.Count) -ForegroundColor Yellow
  Write-Host  '!  راجع الجدول أعلاه. تحديث ويندوز يعيد أحياناً تمكين المهام المجدولة.' -ForegroundColor Yellow
}

if ($failures -or $driftRows.Count) { exit 2 }
exit 0
