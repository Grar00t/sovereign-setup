# CHANGELOG

كل بند مصحوب بأمر العكس الخاص به. الـ journal في `C:\Backups\sovereign-setup\state\journal-<stamp>.json` هو المصدر الرسمي لما طُبِّق فعلاً.

Every entry ships its undo command. The journal at `C:\Backups\sovereign-setup\state\journal-<stamp>.json` is the authoritative record of what was actually applied.

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
| إظهار امتدادات الملفات `HideFileExt=0` | نفس المسار |
| اختياري `-RemoveApps`: إزالة 10 تطبيقات استهلاكية + إلغاء تزويدها | إعادة التثبيت من Microsoft Store |

### Not changed

Windows Update، Defender، جدار الحماية، Store، المشغّلات، PATH، الشبكة، وتطبيقات الطرف الثالث المثبتة مسبقاً.
