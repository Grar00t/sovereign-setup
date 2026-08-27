# sovereign-setup

خط إعداد لـ Windows 11 Pro: محلي أولاً، أدنى تلمتري استهلاكي، متكرر التنفيذ بلا أثر جانبي، مسجَّل بالكامل، وقابل للعكس.

## المبادئ

1. **الملكية للمالك.** كل مخرجات المستخدم ثنائية اللغة: العربية أولاً ثم الإنجليزية.
2. **موافقة وقابلية عكس.** نقطة استعادة قبل التغيير، و`undo` مقابل لكل خطوة، ولا شيء غير قابل للتراجع. وإن لم تُنشأ النقطة يتوقف الخط ولا يُكمل إلا بـ `-NoRestorePoint`.
3. **تكرار آمن.** يقرأ الحالة أولاً ويعمل على الفرق فقط؛ التشغيل مرتين بلا ضرر.
4. **لا اتصال خفي.** لا تلمتري ولا تحليلات من الخط نفسه؛ الاتصال الخارجي الوحيد هو مستودع winget ومواقع الموردين الرسمية عند التركيب.
5. **الأمان يبقى مفعّلاً.** Windows Update وDefender وجدار الحماية لا تُمَس إطلاقاً.

## البنية

| المسار | الغرض |
|---|---|
| `scripts/sovereign-quick.ps1` | التطبيق: نقطة استعادة، سلسلة الأدوات، الخصوصية، شجرة العمل، تحقق |
| `undo/sovereign-undo.ps1` | العكس: يعيد تشغيل الـ journal بالمقلوب، وفيه `-Validate` للفحص قبل أي تغيير |
| `undo/undo-from-json.ps1` | يحوّل journal مكتوباً بأسماء PascalCase (مثل `sovereign-undo.json`) إلى المخطط القياسي ثم يعكسه |
| `tools/probe-live.ps1` | فحص للقراءة فقط، صفر تغييرات |
| `tests/Smoke.Tests.ps1` | اختبارات Pester بوسمين: `repo` للمستودع نفسه، و`machine` للجهاز بعد التطبيق |
| `.github/workflows/check.yml` | CI: تحليل وتحليل ساكن واختبارات `repo` وتشغيل جاف على windows-latest |
| `docs/` | تقرير التدقيق، ترتيب التشغيل، سجل الملاحظات |

## خط الأساس للجهاز المستهدف

| العنصر | القيمة |
|---|---|
| النطام | Windows 11 Pro، 10.0.26100، 64-bit (مفتاح `ProductName` في السجل ما زال يقول Windows 10 Pro) |
| الشل قبل التطبيق | Windows PowerShell 5.1.26100.2161 ولا PowerShell 7 |
| الشل بعد التطبيق | PowerShell 7.6.5 |
| المعالج | Intel Core i5-10400F، 6 أنوية / 12 خيط |
| الذاكرة | 16 GB DDR4-2666 (2×8 GB) |
| الرسوم | NVIDIA GeForce RTX 3060 12 GB، مشغّل 591.86، CUDA 13.1 |
| الأقراص | `C:` 237.73 GB نطام، `D:` 931.5 GB بيانات |
| الشبكة | محول WiFi 6 عبر USB، DHCP، لا Ethernet موصول |
| تقويم النطام | أم القرى — لذلك كل طابع زمني في السكربتات InvariantCulture وبتوقيت UTC |

معرّفات الجهاز (الاسم، MAC، IP) محجوبة في هذا المستودع بالتصميم.

## ترتيب التشغيل

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\tools\probe-live.ps1 -OutFile 'C:\Backups\sovereign-setup\logs\probe-initial.log'
.\scripts\sovereign-quick.ps1 -DryRun
.\scripts\sovereign-quick.ps1
.\scripts\sovereign-quick.ps1 -IncludeOptionalTools
.\scripts\sovereign-quick.ps1 -RemoveApps -DryRun
```

العكس — الفحص أولاً دائماً:

```powershell
.\undo\sovereign-undo.ps1 -JournalPath 'C:\Backups\sovereign-setup\state\journal-<stamp>.json' -Validate
.\undo\sovereign-undo.ps1 -JournalPath 'C:\Backups\sovereign-setup\state\journal-<stamp>.json' -DryRun
.\undo\sovereign-undo.ps1 -JournalPath 'C:\Backups\sovereign-setup\state\journal-<stamp>.json'
```

للـ journal اليدوي (`Kind`، `Path`، `Name` بلا حقل `type`):

```powershell
.\undo\undo-from-json.ps1 -JsonPath 'C:\Backups\sovereign-undo.json' -Validate
.\undo\undo-from-json.ps1 -JsonPath 'C:\Backups\sovereign-undo.json'
```

## قيود معروفة

1. `AllowTelemetry = 1` هو الحد الأدنى المدعوم في Pro. القيمة 0 تُقبل شكلاً وتُعامل كـ 1 خارج Enterprise/Education.
2. مفاتيح `HKCU` تُطبَّق على المستخدم الحالي وحده. كل حساب أخر يحتاج تشغيلاً منفصلاً.
3. `Checkpoint-Computer` و`Enable-ComputerRestore` غير موجودة في PowerShell 7؛ السكربت ينادي محرّك 5.1 لهذه الخطوة وحدها، ويرفع `SystemRestorePointCreationFrequency` مؤقتاً ثم يعيده فوراً.
4. `System32\OneDriveSetup.exe` يبقى بعد الإزالة، فالحكم على وجود OneDrive يعتمد على عميل المستخدم لا على المُنزّل.
5. المهام تختلف بين الإصدارات: `ProgramDataUpdater` غير موجودة على 26100، وتُترك بقصد `PcaPatchDbTask` و`SdbinstMergeDbTask` و`StartupAppTask` و`CloudExperienceHost\CreateObjectTask`.
6. وسم `machine` في الاختبارات يفترض جهازاً مُقسّى بالفعل؛ CI يشغّل وسم `repo` فقط.

## ما لا يُمَس

Windows Update، Defender، جدار الحماية، Microsoft Store، مشغّلات NVIDIA وRealtek، Chrome، Spotify، Teams، Edge، متغيّر PATH، إعدادات الشبكة، ملفات OneDrive المحلية، ومكوّنات النطام `MicrosoftWindows.Client.AIX` و`Client.CBS`.

---

# sovereign-setup (EN)

A local-first, telemetry-minimal setup pipeline for Windows 11 Pro. Idempotent, journaled, and reversible.

**Principles.** Owner sovereignty with Arabic-first bilingual output; a verified restore point plus a matching undo for every step, and the pipeline stops rather than proceeding without one unless `-NoRestorePoint` is passed; read-then-act so a second run is harmless; no pipeline telemetry, with outbound traffic limited to winget and official vendor endpoints; Windows Update, Defender, and the firewall are never touched.

**Layout.** `scripts/sovereign-quick.ps1` applies, `undo/sovereign-undo.ps1` reverses from a JSON journal and offers `-Validate` for a read-only pre-flight, `undo/undo-from-json.ps1` converts an ad-hoc PascalCase journal to the canonical schema first, `tools/probe-live.ps1` is read-only, `tests/Smoke.Tests.ps1` carries `repo` and `machine` tags, `.github/workflows/check.yml` runs parse, analyzer, `repo` tests, and a dry run on windows-latest, `docs/` holds the audit, run order, and applied log.

**Run order.** Probe, dry run, apply, optional tools, then review consumer-app removal with `-RemoveApps -DryRun` before removing anything. Undo with `-Validate` first, then `-DryRun`, then for real.

**Known limits.** `AllowTelemetry = 1` is the Pro floor; `HKCU` values apply to the current user only; restore-point cmdlets exist only in the 5.1 engine, which the script invokes for that step; `System32\OneDriveSetup.exe` survives uninstall so presence is judged by the per-user client; scheduled-task names differ across builds and four Application Experience tasks are deliberately left alone; the `machine` test tag assumes an already-hardened machine.

**Scope guard.** Nothing installed by a third party is removed without an explicit switch, and machine identifiers are redacted from all committed documents.
