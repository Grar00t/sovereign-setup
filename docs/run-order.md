# RUN ORDER / VERIFY / UNDO

ما تم تنفيذه فعلاً على جهاز واحد بتاريخ 2026-08-28. This is the sequence that was actually executed.

## 1. الأدوات — PowerShell كمسؤول

```powershell
'Git.Git','Microsoft.PowerShell','Microsoft.DotNet.SDK.9','Kitware.CMake','Ninja-build.Ninja' |
  ForEach-Object { winget install --id $_ --exact --source winget --accept-package-agreements --accept-source-agreements --silent }
```

ثم افتح نافذة جديدة ليُحدّث `PATH`، وتحقق:

```powershell
foreach ($c in 'git','pwsh','dotnet','cmake','ninja') { "$c -> $((& $c --version 2>&1 | Select-Object -First 1))" }
```

## 2. نقطة الاستعادة — محرّك 5.1 فقط

`Checkpoint-Computer` و`Enable-ComputerRestore` و`Get-ComputerRestorePoint` غير موجودة في PowerShell 7:

```powershell
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -Command "Enable-ComputerRestore -Drive 'C:\'; Checkpoint-Computer -Description 'sovereign-pre' -RestorePointType MODIFY_SETTINGS; Get-ComputerRestorePoint | Select-Object -Last 1 | Format-List SequenceNumber, Description, CreationTime"
```

لو رفض بسبب حد الـ 1440 دقيقة، عطّل القيد مؤقتاً ثم **احذف القيمة فوراً**:

```powershell
$k = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
(Get-ItemProperty -Path $k -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue).SystemRestorePointCreationFrequency
New-ItemProperty -Path $k -Name SystemRestorePointCreationFrequency -PropertyType DWord -Value 0 -Force | Out-Null
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -Command "Checkpoint-Computer -Description 'sovereign-pre' -RestorePointType MODIFY_SETTINGS"
Remove-ItemProperty -Path $k -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue
```

## 3. التقسية

في PowerShell 7 مرتفع الصلاحية. النطاق: 33 قيمة سجل، خدمتا DiagTrack وdmwappushservice، مهام CEIP/Feedback، متغيرا إيقاف تتبع الأدوات، مجلدات العمل. كل قيمة سابقة تُكتب في `C:\Backups\sovereign-undo.json`.

## 4. التحقق

```powershell
Get-Service DiagTrack, dmwappushservice, wuauserv, WinDefend, mpssvc | Select-Object Name, Status, StartType
Get-NetFirewallProfile | Select-Object Name, Enabled
(Get-MpComputerStatus).AntivirusEnabled
[int](Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name HideFileExt).HideFileExt
Get-ScheduledTask | Where-Object { $_.TaskPath -match 'Application Experience|Customer Experience|Feedback' } | Select-Object TaskName, State
Invoke-Pester .\tests\Smoke.Tests.ps1
```

المتوقع: DiagTrack وdmwappushservice = Stopped/Disabled؛ wuauserv ليس Disabled؛ WinDefend وmpssvc = Running/Automatic؛ `HideFileExt = 0`؛ ملفات الجدار الثلاثة Enabled.

Pester 5 لا يأتي مع النطام:

```powershell
Install-Module Pester -Force -SkipPublisherCheck -Scope CurrentUser
```

## 5. العكس

```powershell
.\undo\undo-from-json.ps1 -JsonPath 'C:\Backups\sovereign-undo.json' -DryRun
.\undo\undo-from-json.ps1 -JsonPath 'C:\Backups\sovereign-undo.json'
```

`undo/sovereign-undo.ps1` خاص بمخطط journal الـ `scripts/sovereign-quick.ps1`، وليس ملف `sovereign-undo.json`. لا تخلط بينهما.
