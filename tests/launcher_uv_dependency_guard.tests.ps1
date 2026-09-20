# tests/launcher_uv_dependency_guard.tests.ps1
# Pester 6 idiom (Should -Be). Bead mcpw-a0g - the repowise uv-tool venv dependency
# guard in ###1.watchers_..._repowise.ps1.
#
# RUN IT WITH THE SUITE RUNNER:
#     python dev_tools/run_pester_suite.py tests/launcher_uv_dependency_guard.tests.ps1
# The runner sniffs `Should -` and wraps this file in Pester 6.1.0. Never trust the
# exit code - count the [-] lines (Pester 6.0.x dies in discovery yet exits 0).
#
# WHAT THIS LOCKS (mcpw-a0g)
#   The mcpw-qzm guard was a `Test-Path` sentinel over four DIRECT deps. It cannot see
#   a package that is present but broken: a site-packages directory whose
#   `__init__.py` has been removed still imports (Python resolves it as a NAMESPACE
#   package) and returns an empty module, so `import sqlalchemy` succeeds while
#   `from sqlalchemy import ColumnElement` fails - which is how `watch`, `update` and
#   `reindex` all died silently. It also missed the TRANSITIVE deps (greenlet via
#   `sqlalchemy[asyncio]`, aiosqlite) that the same import chain needs.
#   The replacement imports in the tool's OWN interpreter and walks the declared
#   requirement closure. These tests exercise the probe behaviourally.
#
# PESTER-6 CONSTRAINT THIS FILE IS SHAPED AROUND (measured on this box, Pester 6.1.0
# under Windows PowerShell 5.1): nothing defined at file scope is visible inside an
# It block - not plain variables, not `$script:` variables, not functions arriving
# from a dot-sourced .ps1, not even a scriptblock held in a file-scope variable.
# Only $PSScriptRoot and $PSCommandPath survive. So every It re-derives the launcher
# path, slices the guard region between its markers, and Invoke-Expressions it. Do
# not "tidy" that into a file-scope helper - it will silently stop working.
#
# NO UNINSTALL ANYWHERE: the "missing dependency" case is simulated by asking the
# probe for a module that is guaranteed absent, and the "healthy" case branches on
# whether the real repowise tool venv exists, so the suite stays honest on a box
# that has never had repowise installed instead of false-passing or false-failing.
#
# This file must NOT import the Pester module itself - not even inside a comment -
# because run_pester_suite.py's sniff is a plain substring test.

Describe 'mcpw-a0g uv-tool venv dependency guard' {

    It 'replaces the file-presence sentinel with a real import probe' {
        $root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
        $src = Get-Content -LiteralPath (Join-Path $root '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1') -Raw
        # The old mcpw-qzm sentinel must be gone: a Test-Path over four direct names.
        $src | Should -Not -Match ([regex]::Escape('foreach ($repowiseDep in @("sqlalchemy", "alembic", "uvicorn", "litellm"))'))
        $src | Should -Not -Match ([regex]::Escape('$repowiseSite = Join-Path $env:APPDATA "uv\tools\repowise\Lib\site-packages"'))
        # And the replacement must import in the tool's own interpreter.
        $begin = $src.IndexOf('# >>>>> mcpw-a0g repowise dependency guard (test-extracted region) >>>>>')
        $end = $src.IndexOf('# <<<<< mcpw-a0g repowise dependency guard (end) <<<<<')
        ($begin -ge 0 -and $end -gt $begin) | Should -BeTrue -Because 'the guard region markers must bound the code under test'
        $region = $src.Substring($begin, $end - $begin)
        $region | Should -Match 'importlib\.import_module'
        $region | Should -Match 'importlib\.metadata'
        $region | Should -Match 'function Invoke-ToolVenvDependencyProbe'
    }

    It 'defaults the import set to the transitive deps as well as the direct ones' {
        $root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
        $src = Get-Content -LiteralPath (Join-Path $root '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1') -Raw
        $begin = $src.IndexOf('# >>>>> mcpw-a0g repowise dependency guard (test-extracted region) >>>>>')
        $end = $src.IndexOf('# <<<<< mcpw-a0g repowise dependency guard (end) <<<<<')
        $region = $src.Substring($begin, $end - $begin)
        # The deps the bead measured as lost...
        foreach ($m in @('sqlalchemy', 'alembic', 'uvicorn')) {
            $region | Should -Match ([regex]::Escape("'" + $m + "'"))
        }
        # ...the exact import site that failed (`sqlalchemy.ext.asyncio`,
        # core/workspace/registry.py:19) and the two TRANSITIVE deps the old
        # four-name check could never have caught.
        $region | Should -Match ([regex]::Escape("'sqlalchemy.ext.asyncio'"))
        $region | Should -Match ([regex]::Escape("'greenlet'"))
        $region | Should -Match ([regex]::Escape("'aiosqlite'"))
    }

    It 'repair command names all five declared deps and scopes the reinstall' {
        $root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
        $src = Get-Content -LiteralPath (Join-Path $root '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1') -Raw
        $begin = $src.IndexOf('# >>>>> mcpw-a0g repowise dependency guard (test-extracted region) >>>>>')
        $end = $src.IndexOf('# <<<<< mcpw-a0g repowise dependency guard (end) <<<<<')
        Invoke-Expression $src.Substring($begin, $end - $begin)

        $cmd = Get-ToolVenvDependencyRepairCommand -PythonExe 'C:\some venv\python.exe'
        $cmd | Should -Match '^uv pip install --python '
        $cmd | Should -Match ([regex]::Escape('"C:\some venv\python.exe"'))
        foreach ($p in @('sqlalchemy', 'alembic', 'uvicorn', 'litellm', 'aiosqlite')) {
            $cmd | Should -Match ([regex]::Escape('--reinstall-package ' + $p + ' '))
        }
        # A bare `--reinstall` re-resolves the whole closure (measured: it upgraded
        # websockets 16.1.1 -> 17.1). The scoped form must be the one used.
        $cmd | Should -Not -Match ' --reinstall '
        $cmd | Should -Match ([regex]::Escape('"sqlalchemy[asyncio]<3,>=2.0"'))
    }

    It 'passes a healthy venv: imports verified and the declared closure complete' {
        $root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
        $src = Get-Content -LiteralPath (Join-Path $root '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1') -Raw
        $begin = $src.IndexOf('# >>>>> mcpw-a0g repowise dependency guard (test-extracted region) >>>>>')
        $end = $src.IndexOf('# <<<<< mcpw-a0g repowise dependency guard (end) <<<<<')
        Invoke-Expression $src.Substring($begin, $end - $begin)

        $py = Join-Path $env:APPDATA 'uv\tools\repowise\Scripts\python.exe'
        if (-not (Test-Path -LiteralPath $py)) {
            # Clean-room box: assert the honest "cannot verify" path instead of passing.
            $r = Invoke-ToolVenvDependencyProbe -PythonExe $py -Distribution 'repowise'
            $r.Ok | Should -BeFalse
            $r.Error | Should -Match 'interpreter not found'
        } else {
            $r = Invoke-ToolVenvDependencyProbe -PythonExe $py -Distribution 'repowise'
            $r.Probed | Should -BeTrue
            $r.Error | Should -Be ''
            # The whole point: Ok means the imports really ran, not that files exist.
            $r.Ok | Should -BeTrue -Because "probe detail: $($r.Detail -join ' | ')"
            ($r.ClosureInstalled -gt 0) | Should -BeTrue
            $r.ClosureMissing | Should -Be 0
        }
    }

    It 'detects a missing dependency and names it (no uninstall performed)' {
        $root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
        $src = Get-Content -LiteralPath (Join-Path $root '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1') -Raw
        $begin = $src.IndexOf('# >>>>> mcpw-a0g repowise dependency guard (test-extracted region) >>>>>')
        $end = $src.IndexOf('# <<<<< mcpw-a0g repowise dependency guard (end) <<<<<')
        Invoke-Expression $src.Substring($begin, $end - $begin)

        # A module name no environment can satisfy - so the detection path is
        # exercised WITHOUT uninstalling anything.
        $absent = 'mcpw_a0g_absent_dependency_probe'
        # Point the guard at a real interpreter (prefer the tool's own), else fall
        # back to whatever python this box has.
        $py = @(
            (Join-Path $env:APPDATA 'uv\tools\repowise\Scripts\python.exe')
            'C:/Users/yuni/.workbuddy-ai/binaries/python/envs/default/Scripts/python.exe'
        ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if (-not $py) {
            $c = Get-Command python -ErrorAction SilentlyContinue
            if ($c) { $py = $c.Source }
        }
        if (-not $py) {
            # No interpreter at all: assert the absent-interpreter contract, which
            # is the only honest verdict this box can produce.
            $r = Invoke-ToolVenvDependencyProbe -PythonExe 'C:\no\such\python.exe' -Distribution 'repowise'
            $r.Ok | Should -BeFalse
            $r.Error | Should -Match 'interpreter not found'
        } else {
            $r = Invoke-ToolVenvDependencyProbe -PythonExe $py -Distribution 'repowise' `
                -ImportModule @('sqlalchemy', $absent)
            $r.Probed | Should -BeTrue
            $r.Ok | Should -BeFalse
            ($r.FailedModules -contains $absent) | Should -BeTrue `
                -Because "FailedModules was [$($r.FailedModules -join ', ')]"
            # The failure must carry the interpreter's own error text, not a bare flag.
            (($r.Detail -join ' ') -match [regex]::Escape($absent)) | Should -BeTrue
        }
    }

    It 'reports an absent interpreter instead of silently passing' {
        $root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
        $src = Get-Content -LiteralPath (Join-Path $root '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1') -Raw
        $begin = $src.IndexOf('# >>>>> mcpw-a0g repowise dependency guard (test-extracted region) >>>>>')
        $end = $src.IndexOf('# <<<<< mcpw-a0g repowise dependency guard (end) <<<<<')
        Invoke-Expression $src.Substring($begin, $end - $begin)

        $missing = Join-Path ([System.IO.Path]::GetTempPath()) ('mcpw-a0g-absent-' + [guid]::NewGuid().ToString('N') + '\python.exe')
        $r = Invoke-ToolVenvDependencyProbe -PythonExe $missing -Distribution 'repowise'
        $r.Probed | Should -BeFalse
        $r.Ok | Should -BeFalse
        $r.Error | Should -Match 'interpreter not found'
    }

    It 'the warning names the broken dependency and the exact repair command' {
        $root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
        $src = Get-Content -LiteralPath (Join-Path $root '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1') -Raw
        $begin = $src.IndexOf('# >>>>> mcpw-a0g repowise dependency guard (test-extracted region) >>>>>')
        $end = $src.IndexOf('# <<<<< mcpw-a0g repowise dependency guard (end) <<<<<')
        Invoke-Expression $src.Substring($begin, $end - $begin)

        # A hand-built report keeps this deterministic: it asserts the rendering
        # contract ("detected AND reported"), independent of any live venv.
        $report = [pscustomobject]@{
            PythonExe                = 'C:\fake\python.exe'
            Distribution             = 'repowise'
            Probed                   = $true
            Ok                       = $false
            FailedModules            = @('sqlalchemy.ext.asyncio')
            MissingDistributions     = @('aiosqlite')
            UnlocatableDistributions = @()
            ClosureInstalled         = 129
            ClosureMissing           = 1
            Detail                   = @()
            Error                    = ''
        }
        $cmd = Get-ToolVenvDependencyRepairCommand -PythonExe 'C:\fake\python.exe'
        $msg = Get-ToolVenvDependencyWarning -Report $report -RepairCommand $cmd

        $msg | Should -Match 'BROKEN'
        $msg | Should -Match ([regex]::Escape('sqlalchemy.ext.asyncio'))
        $msg | Should -Match ([regex]::Escape('aiosqlite'))
        $msg | Should -Match ([regex]::Escape('129'))
        # The exact repair command must be in the message, and it must warn that a
        # live watcher has to be stopped first (the measured "Access is denied").
        $msg | Should -Match ([regex]::Escape($cmd))
        $msg | Should -Match 'STOPPED'
    }
}
