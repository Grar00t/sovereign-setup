# تدقيق حيّ بعد التطبيق — 2026-08-28 / Live post-apply audit

مصدر كل سطر هنا: تشغيل `tools/probe-live.ps1` و`scripts/sovereign-quick.ps1 -DryRun` على الجهاز المستهدف بعد التطبيق اليدوي.
معرّفات الجهاز (الاسم، MAC، IP، SID) محجوبة بالتصميم. Machine identifiers redacted by design.

## 1. بوابة التكرار — اجتازت

`sovereign-quick.ps1 -DryRun` أعاد `=` على كل بند خصوصية (33 قيمة سجل، خدمتان، 5 مهام، متغيّران، 4 مجلدات) و`~` على بندَي OneDrive فقط.
هذا هو الدليل الوحيد المقبول على أن التطبيق اليدوي والسكربت يقرآن الحالة نفسها.
`gpupdate /force` نجح لسياسة الجهاز وسياسة المستخدم.

## 2. خط الأساس المؤكَّد

| البند | القيمة |
|---|---|
| النظام | Windows 11 Pro، الإصدار 24H2، بناء **26100.2894** |
| ملاحظة | `HKLM\...\CurrentVersion\ProductName` يقول "Windows 10 Pro" — بقيّة معروفة في السجل، و`Win32_OperatingSystem.Caption` هو المعتمد |
| الشل | PowerShell 7.6.5 (مرتفع) |
| التقويم | أم القرى — أي `Get-Date -Format 'yyyyMMdd'` يعطي `14480315` لا `20260828` |
| جدار الحماية | Domain / Private / Public = Enabled |
| Defender | AntivirusEnabled = True، RealTimeProtection = True |
| Windows Update | wuauserv Running / Manual |
| DiagTrack · dmwappushservice | Stopped / Disabled |

## 3. سلسلة الأدوات ومخزن winget (قراءة حيّة)

| الأداة | المثبّت | آخر إصدار في winget |
|---|---|---|
| Git for Windows | 2.55.0.windows.3 | — |
| PowerShell | 7.6.5 | — |
| .NET SDK | 9.0.317 | 9.0.317 |
| CMake | 4.4.3 | — |
| Ninja | 1.13.2 | 1.13.2 |
| Python 3.12 | غير مثبّت | 3.12.10 |

`winget --version` = v1.29.290. لم تُسجَّل أي بصمة SHA-256 من صفحات `winget show`؛ البصمة تُؤخذ فقط بـ `Get-FileHash` على ملف نُزّل فعلاً.

`python` يظهر في `Get-Command` لكنه اختصار متجر بحجم صفر بايت تحت `WindowsApps` — ليس تثبيتاً. `py` غائب. الحد الأدنى في `config/tools.psd1` كان `Ninja 1.11.0`، وهو إصدار لم يُنشر في المخزن أصلاً؛ الأرضية الصحيحة `1.11.1`.

## 4. المهام المجدولة — الشجرة كاملة

| المسار | المهمة | الحالة |
|---|---|---|
| Application Experience | Microsoft Compatibility Appraiser | **Disabled** |
| Application Experience | Microsoft Compatibility Appraiser Exp | Ready |
| Application Experience | MareBackup | Ready |
| Application Experience | PcaPatchDbTask | Ready |
| Application Experience | SdbinstMergeDbTask | Ready |
| Application Experience | StartupAppTask | Ready |
| Application Experience | ProgramDataUpdater | **غير موجود على هذا البناء** |
| CEIP | Consolidator · UsbCeip | **Disabled** |
| Feedback\Siuf | DmClient · DmClientOnScenarioDownload | **Disabled** |

رسالة `!  task ProgramDataUpdater not present` كانت صحيحة: المهمة ليست في الشجرة على البناء 26100. هذا يُغلق الملاحظة رقم 1 في `docs/applied-2026-08-28.md`.

## 5. PATH

| النطاق | مدخلات | ميتة |
|---|---|---|
| Machine | 8 | 0 |
| User | 3 | 1 — `%USERPROFILE%\.dotnet\tools` |

المدخل الميت يُنشئه أول `dotnet tool install`؛ حذفه آمن وإبقاؤه غير ضار. `ninja` ليس مجلداً في PATH بل اختصار داخل `WinGet\Links`.

## 6. بدء التشغيل

| المصدر | البند | الحكم |
|---|---|---|
| HKLM Run | SecurityHealth | لا يُمَس — واجهة Defender |
| HKLM Run | RtkAudUService | لا يُمَس — مشغّل صوت |
| HKU S-1-5-19 / S-1-5-20 | OneDriveSetup /thfirstsetup | افتراضي في ويندوز — لا يُمَس |
| HKCU Run | MicrosoftEdgeAutoLaunch\_… | مرشّح للتعطيل بموافقة |
| HKCU Run | RobloxPlayerBeta | مرشّح للتعطيل بموافقة |

## 7. التخزين — أهم اكتشاف تشغيلي

| القرص | الوسيط | الحجم | يحمل |
|---|---|---|---|
| 1 — Lexar 256GB SSD | **SSD** | 238 GB | `C:` (النظام) |
| 0 — WDC WD10EZEX-00BBHA0 | **HDD** | 931 GB | `D:` (شجرة العمل) |

`D:\Dev\src` و`D:\Projects` على قرص ميكانيكي. البناء المتكرر (CMake + Ninja، وشِجر `node_modules`/`obj`) يفقد أضعافاً على HDD مقابل SSD.
الخيار الموصى به: يبقى المستودع البعيد كما هو، وتُنقل شجرة البناء النشطة إلى `C:\Dev` مع إبقاء `D:` للأرشيف والبيانات الكبيرة.

## 8. OneDrive — تصحيح

| الفحص | النتيجة |
|---|---|
| `%LOCALAPPDATA%\Microsoft\OneDrive\OneDrive.exe` | غير موجود |
| `System32\OneDriveSetup.exe` | موجود (يُشحن مع ويندوز) |
| مجلد `%USERPROFILE%\OneDrive` | موجود |
| العميل مثبّت؟ | **لا** |

الخلاصة: لا يوجد عميل OneDrive لإزالته. الباقي المفيد هو سياسة `DisableFileSyncNGSC = 1` فقط، وهي لم تُطبَّق بعد.

## 9. عيوب اكتشفها تشغيل المستودع على نفسه

| # | العيب | الخطورة | الحالة |
|---|---|---|---|
| L-01 | `Get-Date -Format 'yyyyMMdd-HHmmss'` يتبع تقويم النظام، فأنتج `journal-14480315-013014.json` | P0 — يكسر ترتيب السجلات والمقارنة الزمنية | أُصلح: `ToString(..., InvariantCulture)` |
| L-02 | `Where-Object DisplayName` رمى 7 مرات تحت PS7 + StrictMode أثناء تعداد التطبيقات | P0 — تعداد ناقص بصمت | أُصلح: شرط صريح على وجود الخاصية |
| L-03 | كشف OneDrive عبر `OneDriveSetup.exe` أعلن "would uninstall" مع أن العميل غير مثبّت | P1 — إجراء على أساس خاطئ | أُصلح: الكشف بملف العميل |
| L-04 | `Get-ComputerRestorePoint` عرض `CreationTime` فارغاً تحت PS7 | P2 — فقدان دليل التوقيت | أُصلح: CIM + تحويل DMTF صريح إلى UTC |
| L-05 | `Set-Task` كان يصمت عند غياب المهمة، والـ catch يطبع نفس نص "not present" لأي فشل | P2 — لبس بين الغياب والفشل | أُصلح: رسالتان مختلفتان |
| L-06 | `-DryRun` كان يُنشئ `C:\Backups\sovereign-setup\{logs,state}` وملف نسخة سجل | P2 — محاكاة ذات أثر | أُصلح: سجل المحاكاة إلى `%TEMP%` وبلا إنشاء مجلدات |
| L-07 | تاريخ توقيعات Defender ظهر `09/03/48` (هجري) | P2 — تقرير غير قابل للمقارنة | أُصلح: تنسيق ثابت |

## 10. ما لم يُنفَّذ بعد

1. `DisableFileSyncNGSC = 1`.
2. عشرة تطبيقات AppX استهلاكية — لم تُلمَس.
3. تقليم PATH — مدخل ميت واحد.
4. بدء التشغيل — Roblox و Edge AutoLaunch.
5. `Microsoft Compatibility Appraiser Exp` أُضيف إلى قائمة السكربت ولم يُطبَّق على الجهاز.
6. Pester لم يُشغَّل: `Install-Module Pester -Force -SkipPublisherCheck -Scope CurrentUser` ثم `Invoke-Pester .\tests\Smoke.Tests.ps1`.
7. لم يُختبر `undo/undo-from-json.ps1` ولو بـ `-DryRun`.
