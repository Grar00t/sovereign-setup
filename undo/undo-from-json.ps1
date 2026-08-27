#requires -Version 5.1
<#
  يعكس ما طُبّق فعلاً من ملف C:\Backups\sovereign-undo.json
  Reverses the applied run recorded in C:\Backups\sovereign-undo.json
  Schema: Kind = registry | service | task | env | folder
#>
[CmdletBinding()]
param(
  [string]$JsonPath = 'C:\Backups\sovereign-undo.json',
  [switch]$DryRun
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'شغّل PowerShell كمسؤول / Run as administrator.' }
if (-not (Test-Path $JsonPath)) { throw "not found: $JsonPath" }

$entries = @(Get-Content -Path $JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json)
if ($entries.Count -eq 0) { Write-Host 'nothing to undo' -ForegroundColor Cyan; return }
[array]::Reverse($entries)
Write-Host ("entries to reverse: {0}" -f $entries.Count) -ForegroundColor Cyan

function Field($obj, [string]$name) {
  if ($obj.PSObject.Properties.Name -contains $name) { return $obj.$name }
  return $null
}

$serviceMap = @{ 'Auto' = 'Automatic'; 'Automatic' = 'Automatic'; 'Manual' = 'Manual'; 'Disabled' = 'Disabled' }

foreach ($e in $entries) {
  $kind = "$(Field $e 'Kind')"
  try {
    if ($kind -eq 'registry') {
      $p = "$(Field $e 'Path')"
      $n = "$(Field $e 'Name')"
      $had = [bool](Field $e 'HadValue')
      $keyExisted = [bool](Field $e 'KeyExisted')
      $old = Field $e 'OldValue'
      if ($DryRun) {
        Write-Host "~ registry $p\$n  had=$had old=$old keyExisted=$keyExisted" -ForegroundColor Yellow
      } elseif ($had) {
        New-ItemProperty -Path $p -Name $n -PropertyType DWord -Value $old -Force | Out-Null
        Write-Host "+ restored $p\$n = $old" -ForegroundColor Green
      } else {
        Remove-ItemProperty -Path $p -Name $n -ErrorAction SilentlyContinue
        if (-not $keyExisted) {
          $k = Get-Item -Path $p -ErrorAction SilentlyContinue
          if ($k -and $k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0) { Remove-Item -Path $p -Force }
        }
        Write-Host "- removed $p\$n" -ForegroundColor Green
      }
    }
    elseif ($kind -eq 'service') {
      $n = "$(Field $e 'Name')"
      $mode = "$(Field $e 'OldStartMode')"
      $wasRunning = [bool](Field $e 'WasRunning')
      $target = $serviceMap[$mode]
      if (-not $target) { $target = 'Manual' }
      if ($DryRun) {
        Write-Host "~ service $n -> $target (wasRunning=$wasRunning)" -ForegroundColor Yellow
      } else {
        Set-Service -Name $n -StartupType $target
        if ($wasRunning) { Start-Service -Name $n -ErrorAction SilentlyContinue }
        Write-Host "+ service $n -> $target" -ForegroundColor Green
      }
    }
    elseif ($kind -eq 'task') {
      $tp = "$(Field $e 'Path')"
      $tn = "$(Field $e 'Name')"
      if ($DryRun) {
        Write-Host "~ enable task $tp$tn" -ForegroundColor Yellow
      } else {
        Enable-ScheduledTask -TaskPath $tp -TaskName $tn | Out-Null
        Write-Host "+ task $tn enabled" -ForegroundColor Green
      }
    }
    elseif ($kind -eq 'env') {
      $n = "$(Field $e 'Name')"
      $had = [bool](Field $e 'HadValue')
      $old = Field $e 'OldValue'
      if ($DryRun) {
        Write-Host "~ env $n  had=$had old=$old" -ForegroundColor Yellow
      } elseif ($had) {
        [Environment]::SetEnvironmentVariable($n, $old, 'Machine')
        Write-Host "+ env $n restored" -ForegroundColor Green
      } else {
        [Environment]::SetEnvironmentVariable($n, $null, 'Machine')
        Write-Host "- env $n removed" -ForegroundColor Green
      }
    }
    elseif ($kind -eq 'folder') {
      Write-Host "i folder kept, no data deleted: $(Field $e 'Path')" -ForegroundColor Cyan
    }
    else {
      Write-Host "? unknown kind: $kind" -ForegroundColor Yellow
    }
  } catch {
    Write-Host "! $kind $(Field $e 'Name') : $($_.Exception.Message)" -ForegroundColor Yellow
  }
}

Write-Host ''
Get-Service DiagTrack, dmwappushservice, wuauserv, WinDefend, mpssvc |
  Select-Object Name, Status, StartType | Format-Table -AutoSize
Write-Host 'انتهى العكس / undo complete. أعد تشغيل explorer.exe أو الجهاز.' -ForegroundColor Cyan
