#requires -Version 5.1
<#
  Pester 5 و 6. اختبارات على المستودع نفسه: تعمل على أي جهاز أو عدّاء CI، بلا جهاز
  مُقسّى وبلا مجلة. كل حارس هنا يحرس عيباً وقع فعلاً على الجهاز الهدف، لا عيباً متخيَّلاً.

  Repo-level guards. Runnable on a bare CI runner: no hardened machine, no journal.
  Every guard here corresponds to a defect that actually occurred.

  Invoke-Pester .\tests\Repo.Tests.ps1 -Tag repo -Output Detailed
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

    $script:TextFiles = @(
        Get-ChildItem -Path $script:RepoRoot -Recurse -File |
            Where-Object {
                $_.FullName -notlike '*\.git\*' -and
                $_.Extension -in @('.ps1','.psd1','.psm1','.md','.json','.yml','.yaml','.txt')
            }
    )
}

Describe 'every script parses and declares its contract' -Tag 'repo' {

    It '<_.Name> parses with zero syntax errors' -ForEach $script:PsFiles {
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$errors) | Out-Null
        @($errors).Count | Should -Be 0
    }

    It '<_.Name> sets StrictMode' -ForEach $script:ToolFiles {
        (Get-Content -LiteralPath $_.FullName -Raw) | Should -Match 'Set-StrictMode'
    }
}

Describe 'culture and strict-mode regressions' -Tag 'repo' {

    It '<_.Name> does not build a stamp from the session calendar' -ForEach $script:ToolFiles {
        # وقع حياً: تحت تقويم أم القرى صار اسم الملف journal-14480315-013014.json.
        # Get-Date -Format follows the thread calendar. Stamps must be InvariantCulture.
        (Get-Content -LiteralPath $_.FullName -Raw) | Should -Not -Match '\$stamp\s*=\s*Get-Date\s+-Format'
    }

    It '<_.Name> pipes into a filter script block, not a bare property name' -ForEach $script:ToolFiles {
        # وقع حياً سبع مرات في الفحص: صيغة اسم الخاصية المجرّد تفشل تحت Set-StrictMode في PowerShell 7.
        # The bare-property form threw seven times under StrictMode in PowerShell 7.
        (Get-Content -LiteralPath $_.FullName -Raw) | Should -Not -Match 'Where-Object\s+(?![-{$(])'
    }
}

Describe 'no machine identifiers are committed' -Tag 'repo' {

    # أنماط لا قيم. كتابة المعرّف الحقيقي هنا تُفشل الغرض من الحارس نفسه.
    # Patterns, never literals: writing the real identifier here would defeat the guard.

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
