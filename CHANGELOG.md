# CHANGELOG

كل بند مصحوب بأمر العكس الخاص به. الـ journal في `C:\Backups\sovereign-setup\state\journal-<stamp>.json` هو المصدر الرسمي لما طُبِّق فعلاً.

Every entry ships its undo command. The journal at `C:\Backups\sovereign-setup\state\journal-<stamp>.json` is the authoritative record of what was actually applied.

## [0.2.0] — 2026-08-28

إصلاحات مبنية على تشغيل حيّ على Windows 11 Pro 26100.2894 تحت PowerShell 7.6.5 وتقويم أم القرى.
Fixes driven by a live run; each line names the observed symptom.

### Fixed

| الإصلاح | العرض المرصود |
|---|---|
| طوابع الـ journal والسجل بتوقيت UTC و`InvariantCulture` | `journal-14480315-013014.json` |
| نقطة استعادة حقيقية عبر محرّك 5.1، مع تحقق من `SequenceNumber` وتوقف إلا مع `-NoRestorePoint` | `Checkpoint-Computer` غير موجود في pwsh 7، وحد الـ 1440 دقيقة |
| خطوة OneDrive أصبحت متكررة بأمان | `~ would uninstall OneDrive` يتكرر في كل تشغيل |
| تقرير المهمة الغائبة وتوسيع قائمة مهام 26100 | `! task ProgramDataUpdater not present` |
| ثوابت التحقق على `StartMode` بأسطر PASS/FAIL | `wuauserv` طبع Running ثم Stopped |
| `undo` يقرأ كل حقل دفاعياً، ويقبل المخطط اليدوي، وفيه `-Validate` وتوقف قبل أي تغيير | `$e.type` و`$e.taskPath` تحت `Set-StrictMode` على `journal-manual.json` |
| مرشح `DisplayName` صريح في الفحص | سبع أخطاء `Where-Object` في `probe-live.ps1:34` |
| عائلة النطام من `CurrentBuild` | `Windows 10 Pro 24H2 build 26100.2894` |
| كشف كعب Microsoft Store بحجم صفر بايت | `[x] python ->` بلا إصدار |
| تواريخ الفحص بتقويم ثابت، ونقاط الاستعادة عبر CIM | `09/03/48` لتوقيعات Defender، و`CreationTime` فارغ |
| BOM لملفات `.ps1` | النصوص العربية تتشوّه في محرّك 5.1 المعلَن في `#requires` |

### Added

| البند | التفاصيل |
|---|---|
| `undo/undo-from-json.ps1` | كان مذكوراً في المستندات وغير موجود؛ يحوّل المخطط اليدوي ثم يعكس |
| `.github/workflows/check.yml` | أول CI لهذا المستودع: تحليل، PSScriptAnalyzer، اختبارات `repo`، تشغيل جاف، `-Validate` |
| اختبارات موسومة `repo` / `machine` | تحليل كل `.ps1`، ووجود كل مسار مذكور في المستندات، ومنع رجوع العلل أعلاه |
| `schema = 2` في كل مدخل journal | ليميّز العكس المخططات |
| `SOVEREIGN_DEV_ROOT` و `SOVEREIGN_BACKUP_ROOT` | لإخراج مسارات جهاز واحد من الاختبارات |

### Changed

المهام المُعطّلة أصبحت ثماني: أُضيف `Microsoft Compatibility Appraiser Exp` و`MareBackup`. وتُترك بقصد `PcaPatchDbTask` و`SdbinstMergeDbTask` و`StartupAppTask` و`CloudExperienceHost\CreateObjectTask`. العكس: `Enable-ScheduledTask -TaskPath <p> -TaskName <n>`، وهو مسجل في الـ journal.

## [0.1.0] — 2026-08-28

### Added

| البند | العكس |
|---|---|
| نقطة استعادة قبل التطبيق | `rstrui.exe` أو `Get-ComputerRestorePoint` |
| تثبيت Git، PowerShell 7، .NET SDK 9، CMake، Ninja عبر winget | `winget uninstall --id <id> --exact` |
| إزالة عميل OneDrive + `DisableFileSyncNGSC=1` | إعادة التثبيت من `https://aka.ms/OneDriveWin` + حذف القيمة |
| `AllowTelemetry=1`، `AllowDeviceNameInTelemetry=0`، `DoNotShowFeedbackNotifications=1` | `undo/sovereign-undo.ps1` يعيد القيم السابقة أو يحذفها |
| `TurnOffWindowsCopilot=1` (HKLM+HKCU)، `DisableAIDataAnalysis=1`، `ShowCopilotButton=0` | نفس المسار |
| `DisableWindowsConsumerFeatures=1`، `DisableCloudOptimizedContent=1`، `DisableConsumerAccountStateContent=1` | نفس المسار |
| تعطيل معرّف الإعلانات (HKLM policy + HKCU value) | نفس المسار |
| `DisableWebSearch=1`، `ConnectedSearchUseWeb=0`، `EnableDynamicContentInWSB=0`، `AllowNewsAndInterests=0` | نفس المسار |
| 12 قيمة ContentDeliveryManager إلى 0 | نفس المسار |
| خصوصية الإدخال: `RestrictImplicitTextCollection=1`، `RestrictImplicitInkCollection=1`، `AllowLinguisticDataCollection=0` | نفس المسار |
| تعطيل خدمتي `DiagTrack` و`dmwappushservice` | `Set-Service -Name <n> -StartupType <old>` |
| تعطيل 6 مهام مجدولة للتلمتري | `Enable-ScheduledTask -TaskPath <p> -TaskName <n>` |
| `DOTNET_CLI_TELEMETRY_OPTOUT=1`، `POWERSHELL_TELEMETRY_OPTOUT=1` (Machine) | حذف المتغيّرين |
| شجرة العمل `D:\Dev\src`، `D:\Dev\tools`، `D:\Projects`، `C:\Backups\sovereign-setup` | المجلدات تُترك؛ لا يُحذف أي بيانات |
| إطهار امتدادات الملفات `HideFileExt=0` | نفس المسار |
| اختياري `-RemoveApps`: إزالة 10 تطبيقات استهلاكية + إلغاء تزويدها | إعادة التثبيت من Microsoft Store |

### Not changed

Windows Update، Defender، جدار الحماية، Store، المشغّلات، PATH، الشبكة، وتطبيقات الطرف الثالث المثبتة مسبقاً.
