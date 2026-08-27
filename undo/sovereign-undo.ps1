#requires -Version 5.1
<#
  يعكس ما طبّقه scripts/sovereign-quick.ps1 من ملف journal.
  يتحمّل المخطط اليدوي (PascalCase، بلا حقل type، وKind='task') أيضاً.
  -Validate: فحص للقراءة فقط بلا أي تغيير.
  Reverses an apply run from its journal. Tolerates the ad-hoc PascalCase schema too.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$JournalPath,
  [switch]$DryRun,
  [switch]$Validate,
  [switch]$Force
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not ($DryRun -or $Validate)) { throw 'شغّل PowerShell كمسؤول / Run as administrator.' }

$entries = @(Get-Content -Path $JournalPath -Raw -Encoding UTF8 | ConvertFrom-Json)
[array]::Reverse($entries)

# كل قراءة حقل تمرّ من هنا. الوصول المباشر إلى خاصية غائبة يرفع استثناءً تحت
# Set-StrictMode، وكان يترك الجهاز معكوساً نصفياً في منتصف الطريق.
# Every field read goes through here: direct access to a missing property throws under
# Set-StrictMode and used to leave the machine half-reverted.
function Field($obj, [string[]]$names) {
  if ($null -eq $obj) { return $null }
  $have = $obj.PSObject.Properties.Name
  foreach ($n in $names) {
    if ($have -contains $n) { return $obj.$n }
  }
  return $null
}
function Kind($e) {
  $k = "$(Field $e @('kind'))"
  if ($k -eq 'task') { return 'scheduledTask' }
  return $k
}
function Str($v) { if ($null -eq $v) { return '' } return "$v" }

$known = @('registry','service','scheduledTask','env','folder','winget','appx','appxProvisioned','onedrive')
$plan = New-Object System.Collections.ArrayList
foreach ($e in $entries) {
  $k = Kind $e
  $why = ''
  $target = ''
  if ($known -notcontains $k) { $why = "unknown kind '$k'" }
  elseif ($k -eq 'registry') {
    $target = (Str (Field $e @('path'))) + '\' + (Str (Field $e @('name')))
    if ((Str (Field $e @('path'))) -eq '' -or (Str (Field $e @('name'))) -eq '') { $why = 'missing path or name' }
  }
  elseif ($k -eq 'service') {
    $target = Str (Field $e @('name'))
    if ($target -eq '') { $why = 'missing name' }
  }
  elseif ($k -eq 'scheduledTask') {
    $tp = Str (Field $e @('taskPath','path'))
    $tn = Str (Field $e @('taskName','name'))
    $target = $tp + $tn
    if ($tp -eq '' -or $tn -eq '') { $why = 'missing task path or name' }
  }
  elseif ($k -eq 'env') {
    $target = Str (Field $e @('name'))
    if ($target -eq '') { $why = 'missing name' }
  }
  else { $target = Str (Field $e @('path','id','packageName','displayName','name')) }
  [void]$plan.Add([pscustomobject]@{ Kind = $k; Target = $target; Revertable = ($why -eq ''); Reason = $why })
}
$plan | Format-Table -AutoSize | Out-Host
$bad = @($plan | Where-Object { -not $_.Revertable })
Write-Host ("entries: {0} · revertable: {1} · blocked: {2}" -f $plan.Count, ($plan.Count - $bad.Count), $bad.Count) -ForegroundColor Cyan
if ($Validate) { Write-Host 'فحص فقط، لم يُغيَّر شيء / validation only, nothing changed' -ForegroundColor Cyan; return }
if ($bad.Count -gt 0 -and -not $Force) {
  throw "توقّف قبل أي تغيير: $($bad.Count) مدخلاً غير قابل للعكس. راجع الجدول أعلاه، أو مرّر -Force لعكس الباقي. / Stopped before changing anything: $($bad.Count) entries cannot be reverted. Pass -Force to revert the rest."
}

$done = 0; $failed = 0; $info = 0
foreach ($e in $entries) {
  $k = Kind $e
  try {
    switch ($k) {

      'registry' {
        $path = Str (Field $e @('path'))
        $name = Str (Field $e @('name'))
        $type = Str (Field $e @('type'))
        if ($type -eq '') { $type = 'DWord' }  # المخطط اليدوي لا يسجّل النوع / ad-hoc schema records no type
        $had  = [bool](Field $e @('hadValue'))
        if ($DryRun) { Write-Host "~ revert $path\$name (had=$had, type=$type)" -ForegroundColor Yellow; break }
        if ($had) {
          New-ItemProperty -Path $path -Name $name -PropertyType $type -Value (Field $e @('oldValue')) -Force | Out-Null
          Write-Host "+ restored $path\$name" -ForegroundColor Green
        } else {
          Remove-ItemProperty -Path $path -Name $name -ErrorAction SilentlyContinue
          if (-not [bool](Field $e @('keyExisted'))) {
            $kk = Get-Item -Path $path -ErrorAction SilentlyContinue
            if ($kk -and $kk.ValueCount -eq 0 -and $kk.SubKeyCount -eq 0) { Remove-Item -Path $path -Force }
          }
          Write-Host "- removed $path\$name" -ForegroundColor Green
        }
        $done++
      }

      'service' {
        $name = Str (Field $e @('name'))
        $map = @{ 'Auto' = 'Automatic'; 'Automatic' = 'Automatic'; 'Manual' = 'Manual'; 'Disabled' = 'Disabled' }
        $old = Str (Field $e @('oldStartMode'))
        $target = $map[$old]
        if (-not $target) { $target = 'Manual' }
        if ($DryRun) { Write-Host "~ service $name -> $target" -ForegroundColor Yellow; break }
        Set-Service -Name $name -StartupType $target
        if ([bool](Field $e @('wasRunning'))) { Start-Service -Name $name -ErrorAction SilentlyContinue }
        Write-Host "+ service $name -> $target" -ForegroundColor Green
        $done++
      }

      'scheduledTask' {
        $tp = Str (Field $e @('taskPath','path'))
        $tn = Str (Field $e @('taskName','name'))
        if ($DryRun) { Write-Host "~ enable task $tn" -ForegroundColor Yellow; break }
        Enable-ScheduledTask -TaskPath $tp -TaskName $tn -ErrorAction Stop | Out-Null
        Write-Host "+ task $tn enabled" -ForegroundColor Green
        $done++
      }

      'env' {
        $name = Str (Field $e @('name'))
        if ($DryRun) { Write-Host "~ env $name revert" -ForegroundColor Yellow; break }
        if ([bool](Field $e @('hadValue'))) { [Environment]::SetEnvironmentVariable($name, (Field $e @('oldValue')), 'Machine') }
        else { [Environment]::SetEnvironmentVariable($name, $null, 'Machine') }
        Write-Host "+ env $name reverted" -ForegroundColor Green
        $done++
      }

      'appx'            { Write-Host "i reinstall from Store: $(Str (Field $e @('packageName')))" -ForegroundColor Cyan; $info++ }
      'appxProvisioned' { Write-Host "i reprovision needs image or Store: $(Str (Field $e @('displayName')))" -ForegroundColor Cyan; $info++ }
      'onedrive'        { Write-Host 'i reinstall OneDrive: https://aka.ms/OneDriveWin' -ForegroundColor Cyan; $info++ }
      'winget'          { Write-Host "i uninstall if unwanted: winget uninstall --id $(Str (Field $e @('id'))) --exact" -ForegroundColor Cyan; $info++ }
      'folder'          { Write-Host "i folder kept, no data deleted: $(Str (Field $e @('path')))" -ForegroundColor Cyan; $info++ }
      default           { Write-Host "? skipped unknown kind: $k" -ForegroundColor Yellow; $failed++ }
    }
  } catch {
    $failed++
    Write-Host "! $k : $($_.Exception.Message)" -ForegroundColor Red
  }
}
Write-Host ("reverted: {0} · informational: {1} · failed: {2}" -f $done, $info, $failed) -ForegroundColor Cyan
if ($failed -gt 0) { Write-Host 'انتهى العكس مع أخطاء. راجع الأسطر الحمراء. / undo finished with errors.' -ForegroundColor Red }
else { Write-Host 'انتهى العكس / undo complete. أعد تشغيل الجهاز.' -ForegroundColor Cyan }
