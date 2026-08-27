#requires -Version 5.1
<#
  يحوّل journal مكتوباً بأسماء PascalCase مثل C:\Backups\sovereign-undo.json
  إلى مخطط sovereign-undo.ps1، يكتبه إلى ملف، ثم ينفّذ العكس منه.
  السبب: المخطط اليدوي لا يحمل حقل type، ويسمّي المهام Kind='task' مع Path/Name،
  فكان يمرّ على العكس كنوع مجهول ولا تُعاد أي مهمة.

  Converts an ad-hoc PascalCase journal to the canonical schema, writes it, then reverses it.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$JsonPath,
  [string]$OutJournal,
  [switch]$DryRun,
  [switch]$Validate,
  [switch]$Force
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Inv = [Globalization.CultureInfo]::InvariantCulture

function Field($obj, [string[]]$names) {
  if ($null -eq $obj) { return $null }
  $have = $obj.PSObject.Properties.Name
  foreach ($n in $names) {
    if ($have -contains $n) { return $obj.$n }
  }
  return $null
}
function Str($v) { if ($null -eq $v) { return '' } return "$v" }

$raw = @(Get-Content -Path $JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json)
$out = New-Object System.Collections.ArrayList
foreach ($e in $raw) {
  $kind = Str (Field $e @('kind'))
  switch ($kind) {
    'registry' {
      [void]$out.Add([pscustomobject]@{
        schema     = 2
        kind       = 'registry'
        path       = Str (Field $e @('path'))
        name       = Str (Field $e @('name'))
        type       = 'DWord'
        keyExisted = [bool](Field $e @('keyExisted'))
        hadValue   = [bool](Field $e @('hadValue'))
        oldValue   = (Field $e @('oldValue'))
      })
    }
    'service' {
      [void]$out.Add([pscustomobject]@{
        schema         = 2
        kind           = 'service'
        name           = Str (Field $e @('name'))
        oldStartMode   = Str (Field $e @('oldStartMode'))
        newStartupType = 'Disabled'
        wasRunning     = [bool](Field $e @('wasRunning'))
      })
    }
    { $_ -eq 'task' -or $_ -eq 'scheduledTask' } {
      [void]$out.Add([pscustomobject]@{
        schema   = 2
        kind     = 'scheduledTask'
        taskPath = Str (Field $e @('taskPath','path'))
        taskName = Str (Field $e @('taskName','name'))
        oldState = Str (Field $e @('oldState'))
        newState = 'Disabled'
      })
    }
    'env' {
      [void]$out.Add([pscustomobject]@{
        schema   = 2
        kind     = 'env'
        name     = Str (Field $e @('name'))
        scope    = 'Machine'
        hadValue = [bool](Field $e @('hadValue'))
        oldValue = (Field $e @('oldValue'))
      })
    }
    'folder' {
      [void]$out.Add([pscustomobject]@{ schema = 2; kind = 'folder'; path = Str (Field $e @('path')) })
    }
    default {
      # يُمرَّر كما هو ليبلّغ عنه العكس بدل أن يُخفى / passed through so undo reports it
      [void]$out.Add($e)
    }
  }
}

if (-not $OutJournal) {
  $stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss', $Inv) + 'Z'
  $dir = Split-Path -Parent $JsonPath
  if (-not $dir) { $dir = '.' }
  $OutJournal = Join-Path $dir "journal-converted-$stamp.json"
}
($out | ConvertTo-Json -Depth 6) | Set-Content -Path $OutJournal -Encoding UTF8
Write-Host "مخطط قياسي / canonical journal: $OutJournal" -ForegroundColor Cyan
Write-Host ("converted entries: {0}" -f $out.Count) -ForegroundColor Cyan

& (Join-Path $PSScriptRoot 'sovereign-undo.ps1') -JournalPath $OutJournal -DryRun:$DryRun -Validate:$Validate -Force:$Force
