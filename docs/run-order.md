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

تحقيق واحد مهم: وجود الأمر لا يعني وجود الأداة. `python` في `WindowsApps` قد يكون كعب Microsoft Store بحجم صفر بايت يطبع إصداراً فارغاً. `tools/probe-live.ps1` يميّز هذه الحالة ويطبع `[~]` لا `[x]`.

## 2. نقطة الاستعادة — السكربت يتولّاها

`Checkpoint-Computer` و`Enable-ComputerRestore` و`Get-ComputerRestorePoint` غير موجودة في PowerShell 7. لذلك `scripts/sovereign-quick.ps1`:

1. يقرأ أعلى `SequenceNumber` من صنف `SystemRestore` عبر CIM (يعمل في 5.1 وفي 7).
2. يرفع `SystemRestorePointCreationFrequency = 0` مؤقتاً، ويعيده إلى ما كان في `finally`.
3. ينادي محرّك 5.1 لـ `Enable-ComputerRestore` و`Checkpoint-Computer` وحدهما.
4. يقرأ الرقم مرة أخرى. لو لم يزد، فلم تُنشأ نقطة، ويتوقف التطبيق إلا مع `-NoRestorePoint`.

الطريقة اليدوية ما زالت صحيحة لو أردتها خارج السكربت:

```powershell
$k = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
(Get-ItemProperty -Path $k -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue).SystemRestorePointCreationFrequency
New-ItemProperty -Path $k -Name SystemRestorePointCreationFrequency -PropertyType DWord -Value 0 -Force | Out-Null
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -Command "Enable-ComputerRestore -Drive 'C:\'; Checkpoint-Computer -Description 'sovereign-pre' -RestorePointType MODIFY_SETTINGS"
Remove-ItemProperty -Path $k -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue
Get-CimInstance -Namespace 'root/default' -ClassName 'SystemRestore' | Select-Object SequenceNumber, Description, CreationTime
```

حد الـ 1440 دقيقة هو السبب المعتاد لرفض إنشاء نقطة جديدة في نفس اليوم.

## 3. التقسية

في PowerShell 7 مرتفع الصلاحية. النطاق: 33 قيمة سجل، خدمتا DiagTrack وdmwappushservice، مهام CEIP/Feedback، متغيرا إيقاف تتبع الأدوات، مجلدات العمل.

```powershell
.\scripts\sovereign-quick.ps1 -DryRun
.\scripts\sovereign-quick.ps1
```

كل تغيير يُكتب فوراً في `C:\Backups\sovereign-setup\state\journal-<stamp>.json`، والـ stamp بتوقيت UTC وتقويم ثابت (`20260827-221805Z`). تحت تقويم أم القرى كان `Get-Date -Format` يكتب `journal-14480315-013014.json`، وهو اسم لا يُرتّب ولا يُقارن.

## 4. التحقق

القسم 6 من السكربت يطبع أسطر `PASS` / `FAIL` صريحة، ويعدّ الفاشل منها. الثوابت مقيسة على `StartMode` لا على `Status`، لأن `wuauserv` خدمة عند الطلب وتبدّلت فعلاً بين `Running` و`Stopped` بين تشغيلين متتاليين.

```powershell
.\tools\probe-live.ps1
Get-CimInstance Win32_Service -Filter "Name='wuauserv'" | Select-Object Name, StartMode, State
Get-NetFirewallProfile | Select-Object Name, Enabled
(Get-MpComputerStatus).AntivirusEnabled
Get-ScheduledTask | Where-Object { $_.TaskPath -match 'Application Experience|Customer Experience|Feedback' } | Select-Object TaskName, State
```

المتوقع: DiagTrack وdmwappushservice = Disabled؛ wuauserv ليس Disabled؛ WinDefend وmpssvc = Auto؛ `HideFileExt = 0`؛ ملفات الجدار الثلاثة Enabled.

Pester 5 لا يأتي مع النطام، والاختبارات موسومة:

```powershell
Install-Module Pester -Force -SkipPublisherCheck -Scope CurrentUser
Invoke-Pester .\tests\Smoke.Tests.ps1 -Tag repo      # لا يحتاج جهازاً مُقسّى
Invoke-Pester .\tests\Smoke.Tests.ps1 -Tag machine   # يفحص الجهاز بعد التطبيق
```

مسارات الاختبارات تُقرأ من `SOVEREIGN_DEV_ROOT` و`SOVEREIGN_BACKUP_ROOT` إن وُجدا، لا من مسارات جهاز واحد مدفونة في الملف.

## 5. العكس

الفحص قبل أي تغيير، دائماً. `-Validate` يطبع جدولاً بكل مدخل وهل هو قابل للعكس ولماذا لا، ولا يلمس شيئاً:

```powershell
.\undo\sovereign-undo.ps1 -JournalPath 'C:\Backups\sovereign-setup\state\journal-<stamp>.json' -Validate
.\undo\sovereign-undo.ps1 -JournalPath 'C:\Backups\sovereign-setup\state\journal-<stamp>.json' -DryRun
.\undo\sovereign-undo.ps1 -JournalPath 'C:\Backups\sovereign-setup\state\journal-<stamp>.json'
```

لو وجد مدخلاً غير قابل للعكس، يتوقف قبل أن يغير شيئاً، ولا يكمل إلا بـ `-Force`. هذا أفضل من أن يتوقف في منتصف الطريق ويترك الجهاز معكوساً نصفياً.

للـ journal اليدوي مثل `C:\Backups\sovereign-undo.json` — أسماء PascalCase، بلا حقل `type`، والمهام بـ `Kind='task'` و`Path`/`Name`:

```powershell
.\undo\undo-from-json.ps1 -JsonPath 'C:\Backups\sovereign-undo.json' -Validate
.\undo\undo-from-json.ps1 -JsonPath 'C:\Backups\sovereign-undo.json'
```

يحوّله إلى المخطط القياسي، يكتب الملف المحوّل للسجل، ثم ينادي `sovereign-undo.ps1`. و`sovereign-undo.ps1` نفسه أصبح يتحمل المخططين، فلا ضرر لو مرّرته الملف مباشرة، لكن المحوّل يترك أثراً مكتوباً.

## 6. CI

`.github/workflows/check.yml` على `windows-latest`: تحليل نصي لكل `.ps1`، PSScriptAnalyzer، اختبارات وسم `repo`، تشغيل جاف كامل، ثم `-Validate` على أي journal نتج عنه.

ما يُثبته CI: أن الملفات تُحلّل وتُشغّل، وأن كل مسار مذكور في المستندات موجود فعلاً.

ما لا يُثبته: أن التقسية تعمل على جهازك. الوكيل غير مُقسّى، ولا يحتوي winget، ولا يُنشئ نقاط استعادة. الـ `machine` وسمٌ يُشغّل محلياً وحسب.
