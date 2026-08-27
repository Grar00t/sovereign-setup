# sovereign-setup

خط إعداد لـ Windows 11 Pro: محلي أولاً، أدنى تلمتري استهلاكي، متكرر التنفيذ بلا أثر جانبي، مسجَّل بالكامل، وقابل للعكس.

## المبادئ

1. **الملكية للمالك.** كل مخرجات المستخدم ثنائية اللغة: العربية أولاً ثم الإنجليزية.
2. **موافقة وقابلية عكس.** نقطة استعادة قبل التغيير، و`undo` مقابل لكل خطوة، ولا شيء غير قابل للتراجع.
3. **تكرار آمن.** يقرأ الحالة أولاً ويعمل على الفرق فقط؛ التشغيل مرتين بلا ضرر.
4. **لا اتصال خفي.** لا تلمتري ولا تحليلات من الخط نفسه؛ الاتصال الخارجي الوحيد هو مستودع winget ومواقع الموردين الرسمية عند التثبيت.
5. **الأمان يبقى مفعّلاً.** Windows Update وDefender وجدار الحماية لا تُمَس إطلاقاً.

## البنية

| المسار | الغرض |
|---|---|
| `scripts/sovereign-quick.ps1` | التطبيق: نقطة استعادة، سلسلة الأدوات، الخصوصية، شجرة العمل، تحقق |
| `undo/sovereign-undo.ps1` | العكس: يعيد تشغيل الـ journal بالمقلوب |
| `tools/probe-live.ps1` | فحص للقراءة فقط، صفر تغييرات |
| `tests/Smoke.Tests.ps1` | اختبارات Pester: الأدوات، الخدمات، ثوابت الأمان، المجلدات |
| `docs/` | تقرير التدقيق، ترتيب التشغيل، سجل الملاحظات |

## خط الأساس للجهاز المستهدف

| العنصر | القيمة |
|---|---|
| النظام | Windows 11 Pro، 10.0.26100، 64-bit |
| الشل | Windows PowerShell 5.1.26100.2161 (PowerShell 7 غير مثبت قبل التطبيق) |
| المعالج | Intel Core i5-10400F، 6 أنوية / 12 خيط |
| الذاكرة | 16 GB DDR4-2666 (2×8 GB) |
| الرسوم | NVIDIA GeForce RTX 3060 12 GB، مشغّل 591.86، CUDA 13.1 |
| الأقراص | `C:` 237.73 GB نظام، `D:` 931.5 GB بيانات |
| الشبكة | محول WiFi 6 عبر USB، DHCP، لا Ethernet موصول |

معرّفات الجهاز (الاسم، MAC، IP) محجوبة في هذا المستودع بالتصميم.

## ترتيب التشغيل

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\scripts\sovereign-quick.ps1 -DryRun
.\scripts\sovereign-quick.ps1
.\scripts\sovereign-quick.ps1 -IncludeOptionalTools
.\scripts\sovereign-quick.ps1 -RemoveApps -DryRun
```

العكس:

```powershell
.\undo\sovereign-undo.ps1 -JournalPath 'C:\Backups\sovereign-setup\state\journal-<stamp>.json'
```

## ما لا يُمَس

Windows Update، Defender، جدار الحماية، Microsoft Store، مشغّلات NVIDIA وRealtek، Chrome، Spotify، Teams، Edge، متغيّر PATH، إعدادات الشبكة، ملفات OneDrive المحلية، ومكوّنات النظام `MicrosoftWindows.Client.AIX` و`Client.CBS`.

---

# sovereign-setup (EN)

A local-first, telemetry-minimal setup pipeline for Windows 11 Pro. Idempotent, journaled, and reversible.

**Principles.** Owner sovereignty with Arabic-first bilingual output; restore point plus a matching undo for every step; read-then-act so a second run is harmless; no pipeline telemetry, with outbound traffic limited to winget and official vendor endpoints; Windows Update, Defender, and the firewall are never touched.

**Layout.** `scripts/sovereign-quick.ps1` applies, `undo/sovereign-undo.ps1` reverses from the JSON journal, `tools/probe-live.ps1` is read-only, `tests/Smoke.Tests.ps1` asserts tools, service states, security invariants, and workspace paths, `docs/` holds the audit and run order.

**Run order.** Dry run first, then apply, then optional tools, then review consumer-app removal with `-RemoveApps -DryRun` before removing anything.

**Scope guard.** Nothing installed by a third party is removed without an explicit switch, and machine identifiers are redacted from all committed documents.
