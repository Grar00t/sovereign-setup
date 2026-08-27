#requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$JournalPath,
  [switch]$DryRun
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'شغّل PowerShell كمسؤول / Run as administrator.' }

$entries = @(Get-Content -Path $JournalPath -Raw -Encoding UTF8 | ConvertFrom-Json)
[array]::Reverse($entries)

function Field($obj, [string]$name) {
  if ($obj.PSObject.Properties.Name -contains $name) { return $obj.$name }
  return $null
}

foreach ($e in $entries) {
  switch ($e.kind) {

    'registry' {
      $had = [bool](Field $e 'hadValue')
      if ($DryRun) { Write-Host "~ revert $($e.path)\$($e.name) (had=$had)" -ForegroundColor Yellow; break }
      if ($had) {
        New-ItemProperty -Path $e.path -Name $e.name -PropertyType $e.type -Value (Field $e 'oldValue') -Force | Out-Null
        Write-Host "+ restored $($e.path)\$($e.name)" -ForegroundColor Green
      } else {
        Remove-ItemProperty -Path $e.path -Name $e.name -ErrorAction SilentlyContinue
        if (-not [bool](Field $e 'keyExisted')) {
          $k = Get-Item -Path $e.path -ErrorAction SilentlyContinue
          if ($k -and $k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0) { Remove-Item -Path $e.path -Force }
        }
        Write-Host "- removed $($e.path)\$($e.name)" -ForegroundColor Green
      }
    }

    'service' {
      $map = @{ 'Auto' = 'Automatic'; 'Manual' = 'Manual'; 'Disabled' = 'Disabled' }
      $target = $map["$($e.oldStartMode)"]
      if (-not $target) { $target = 'Manual' }
      if ($DryRun) { Write-Host "~ service $($e.name) -> $target" -ForegroundColor Yellow; break }
      Set-Service -Name $e.name -StartupType $target
      if ([bool](Field $e 'wasRunning')) { Start-Service -Name $e.name -ErrorAction SilentlyContinue }
      Write-Host "+ service $($e.name) -> $target" -ForegroundColor Green
    }

    'scheduledTask' {
      if ($DryRun) { Write-Host "~ enable task $($e.taskName)" -ForegroundColor Yellow; break }
      try {
        Enable-ScheduledTask -TaskPath $e.taskPath -TaskName $e.taskName | Out-Null
        Write-Host "+ task $($e.taskName) enabled" -ForegroundColor Green
      } catch { Write-Host "! task $($e.taskName): $($_.Exception.Message)" -ForegroundColor Yellow }
    }

    'env' {
      if ($DryRun) { Write-Host "~ env $($e.name) revert" -ForegroundColor Yellow; break }
      if ([bool](Field $e 'hadValue')) { [Environment]::SetEnvironmentVariable($e.name, (Field $e 'oldValue'), 'Machine') }
      else { [Environment]::SetEnvironmentVariable($e.name, $null, 'Machine') }
      Write-Host "+ env $($e.name) reverted" -ForegroundColor Green
    }

    'appx'            { Write-Host "i reinstall from Store: $($e.packageName)" -ForegroundColor Cyan }
    'appxProvisioned' { Write-Host "i reprovision needs image or Store: $($e.displayName)" -ForegroundColor Cyan }
    'onedrive'        { Write-Host 'i reinstall OneDrive: https://aka.ms/OneDriveWin' -ForegroundColor Cyan }
    'winget'          { Write-Host "i uninstall if unwanted: winget uninstall --id $($e.id) --exact" -ForegroundColor Cyan }
    'folder'          { Write-Host "i folder kept, no data deleted: $($e.path)" -ForegroundColor Cyan }
    default           { Write-Host "? unknown entry kind: $($e.kind)" -ForegroundColor Yellow }
  }
}
Write-Host 'انتهى العكس / undo complete. أعد تشغيل الجهاز.' -ForegroundColor Cyan
