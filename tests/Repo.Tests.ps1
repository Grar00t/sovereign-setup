#requires -Version 5.1
<#
  Pester 5 و 6. حراس على مستوى المستودع: تعمل على أي عدّاء CI، بلا جهاز مُقسّى وبلا مجلة.
  كل حارس هنا يحرس عيباً وقع فعلاً، لا عيباً متخيَّلاً.

  Repo-level guards. Runnable on a bare CI runner: no hardened machine, no journal.
  Every guard corresponds to a defect that actually occurred.

  Invoke-Pester .\tests\Repo.Tests.ps1 -Tag repo -Output Detailed

  تُقرأ الحراس من شجرة النحو لا من نص الملف. النسخة الأولى طابقت النص الخام فأفشلت
  tools\probe-live.ps1 بسبب تعليقين يشرحان العيب نفسه. الحارس النصي ينكسر في الاتجاهين:
  تعليق يذكر العيب يُفشل ملفاً سليماً، وتعليق يذكر الإصلاح يُنجح ملفاً مخالفاً.

  Guards read the AST, not raw text. v1 matched raw text and failed the probe over two
  comments documenting the defect itself. Text guards break in both directions.
#>

BeforeDiscovery {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

    $script:PsFiles = @(
        Get-ChildItem -Path $script:RepoRoot -Recurse -File -Filter *.ps1 |
            Where-Object { $_.FullName -notlike '*\.git\*' }
    )

    # سكربتات التشغيل وحدها: ملفات الاختبار لا تضبط StrictMode وتحتوي أنماطاً كنصوص.
    # Production scripts only: test files do not set StrictMode and hold patterns as text.
    $script:ToolFiles = @($script:PsFiles | Where-Object { $_.FullName -notlike '*\tests\*' })
    $script:TestFiles = @($script:PsFiles | Where-Object { $_.FullName -like '*\tests\*' })

    $script:TextFiles = @(
        Get-ChildItem -Path $script:RepoRoot -Recurse -File |
            Where-Object {
                $_.FullName -notlike '*\.git\*' -and
                $_.Extension -in @('.ps1','.psd1','.psm1','.md','.json','.yml','.yaml','.txt')
            }
    )
}

BeforeAll {

    function Get-ScriptModel {
        # ParseInput على النص نفسه الذي نحمله، فتبقى المواضع صحيحة مع BOM أو بدونه.
        # ParseInput over the same string we hold, so offsets stay valid with or without a BOM.
        param([string]$Path)
        $raw = Get-Content -LiteralPath $Path -Raw
        if ($null -eq $raw) { $raw = '' }
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($raw, [ref]$tokens, [ref]$errors)
        [pscustomobject]@{ Raw = $raw; Ast = $ast; Tokens = @($tokens); Errors = @($errors) }
    }

    function Get-CodeText {
        # النص بعد تعمية مواضع التعليقات في مكانها: الأسطر والمواضع تبقى كما هي.
        # Source with comment extents blanked in place: lines and offsets are preserved.
        param([string]$Path)
        $model = Get-ScriptModel -Path $Path
        $buffer = [System.Text.StringBuilder]::new($model.Raw)
        $lf = [char]10
        $cr = [char]13
        $space = [char]32
        foreach ($token in $model.Tokens) {
            if ($token.Kind -ne [System.Management.Automation.Language.TokenKind]::Comment) { continue }
            $from = $token.Extent.StartOffset
            $to = $token.Extent.EndOffset
            if ($from -lt 0 -or $to -gt $buffer.Length) { continue }
            for ($i = $from; $i -lt $to; $i++) {
                if ($buffer[$i] -ne $lf -and $buffer[$i] -ne $cr) { $buffer[$i] = $space }
            }
        }
        $buffer.ToString()
    }

    function Get-BarePropertyWhere {
        # الصيغة المخالفة: أول عنصر موضعي ليس كتلة نص ولا معامَلاً ولا متغيّراً، أي اسم
        # خاصية مجرّد يرفع خطأً تحت StrictMode عند أول عنصر لا يملك تلك الخاصية.
        # The defect: a first positional element that is not a script block, a parameter or a
        # variable, i.e. a bare property name, which throws under StrictMode.
        param([string]$Path)
        $model = Get-ScriptModel -Path $Path
        $hits = [System.Collections.Generic.List[string]]::new()
        $commands = $model.Ast.FindAll(
            { param($node) $node -is [System.Management.Automation.Language.CommandAst] },
            $true)
        foreach ($command in $commands) {
            $name = $command.GetCommandName()
            if ([string]::IsNullOrEmpty($name)) { continue }
            if (@('Where-Object', 'where', '?') -notcontains $name) { continue }
            $elements = @($command.CommandElements)
            if ($elements.Count -lt 2) { continue }
            $first = $elements[1]
            if ($first -is [System.Management.Automation.Language.CommandParameterAst]) { continue }
            if ($first -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { continue }
            if ($first -is [System.Management.Automation.Language.VariableExpressionAst]) { continue }
            $hits.Add(('line {0}: {1}' -f $command.Extent.StartLineNumber, $first.Extent.Text))
        }
        $hits.ToArray()
    }

    function Get-FileEncodingFacts {
        param([string]$Path)
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $nonAscii = $false
        foreach ($b in $bytes) { if ($b -gt 127) { $nonAscii = $true; break } }
        $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        [pscustomobject]@{ NonAscii = $nonAscii; Bom = $bom }
    }
}

Describe 'every script parses and declares its contract' -Tag 'repo' {

    It '<_.Name> parses with zero syntax errors' -ForEach $script:PsFiles {
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$errors) | Out-Null
        @($errors).Count | Should -Be 0
    }

    It '<_.Name> sets StrictMode' -ForEach $script:ToolFiles {
        (Get-CodeText -Path $_.FullName) | Should -Match 'Set-StrictMode'
    }

    It '<_.Name> declares at least one tag so a filtered CI run can never be empty' -ForEach $script:TestFiles {
        # وقع حياً: CI يرشّح Tag = repo وشجرة الاختبارات بلا وسوم، فنفّذ صفر اختبارات ونجح.
        # Observed live: CI filtered Tag = repo against untagged tests, ran zero tests, passed.
        (Get-CodeText -Path $_.FullName) | Should -Match '-Tag'
    }
}

Describe 'culture and strict-mode regressions' -Tag 'repo' {

    It '<_.Name> does not build a stamp from the session calendar' -ForEach $script:ToolFiles {
        # وقع حياً: تحت تقويم أم القرى صار اسم الملف journal-14480315-013014.json.
        # Get-Date -Format follows the thread calendar. Stamps must be InvariantCulture.
        (Get-CodeText -Path $_.FullName) | Should -Not -Match '\$stamp\s*=\s*Get-Date\s+-Format'
    }

    It '<_.Name> pipes into a filter script block, not a bare property name' -ForEach $script:ToolFiles {
        # وقع حياً سبع مرات في الفحص، ثم أفشل الحارس النصي ملفاً سليماً بسبب تعليقه.
        # Seven live StrictMode failures, then the text guard failed a clean file over its comment.
        $hits = @(Get-BarePropertyWhere -Path $_.FullName)
        ($hits -join ' ; ') | Should -BeNullOrEmpty
    }
}

Describe 'files stay readable under Windows PowerShell 5.1' -Tag 'repo' {

    It '<_.Name> carries a UTF-8 BOM if it holds non-ASCII text' -ForEach $script:PsFiles {
        # 5.1 يقرأ UTF-8 بلا BOM كـ ANSI فتتشوّه السطور العربية. جُرد بالبايت أولاً: 8/8 تحمل BOM.
        # 5.1 reads BOM-less UTF-8 as ANSI and mangles the Arabic lines. Byte-audited first: 8/8 carry it.
        $facts = Get-FileEncodingFacts -Path $_.FullName
        ($facts.Bom -or -not $facts.NonAscii) | Should -BeTrue
    }
}

Describe 'no machine identifiers are committed' -Tag 'repo' {

    # أنماط لا قيم، ويُقرأ النص الخام كاملاً: معرّف مُسرَّب في تعليق يبقى مُسرَّباً.
    # Patterns not literals, over raw text including comments: a leak in a comment is a leak.

    It '<_.Name> contains no account SID' -ForEach $script:TextFiles {
        (Get-Content -LiteralPath $_.FullName -Raw) | Should -Not -Match 'S-1-5-21(-\d+){4}'
    }

    It '<_.Name> contains no MAC address' -ForEach $script:TextFiles {
        (Get-Content -LiteralPath $_.FullName -Raw) | Should -Not -Match '\b([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b'
    }

    It '<_.Name> contains no default computer name' -ForEach $script:TextFiles {
        (Get-Content -LiteralPath $_.FullName -Raw) | Should -Not -Match '\bDESKTOP-[A-Z0-9]{7}\b'
    }
}
