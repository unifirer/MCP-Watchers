# tests/launcher_gm_semantic_threadjob.tests.ps1
# Pester 3.4.0 idiom (same as launcher_gm_semantic_build.tests.ps1). Run:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/launcher_gm_semantic_threadjob.tests.ps1
#
# Regression lock for beads VAD-3apv (gm-semantic thread job dead on arrival):
#   1. param($State, $BuildSrc, ...) MUST be the FIRST statement of the
#      Start-ThreadJob scriptblock that drives the live incremental build.
#      Statements before param() parse fine but throw at runtime ("The term
#      'param' is not recognized as a name of a cmdlet"), killing the job
#      silently on its first tick.
#   2. The shared $global:gmSemState hashtable must be defined EXACTLY ONCE.
#      The duplicate second definition overwrote the first and dropped the
#      PopupShown key that Invoke-GmSemanticBuild's popup gate depends on.
#   3. Job failure must not be discarded: the controller loop drains/warns
#      when the job stops while the launcher is still running, and the
#      incremental loop's repeated-failure flag ($State.Failed) has a consumer.

Import-Module Pester -RequiredVersion 3.4.0 -ErrorAction Stop

$repo = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')
$launcher = Join-Path $repo '###1.watchers_for_memtrace_grepai_graphenium_graphify-rs_repowise.ps1'

$parseTokens = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$parseTokens, [ref]$parseErrors)

# The gm-semantic job is the Start-ThreadJob call whose extent binds gmSemState.
$jobCalls = @($ast.FindAll({ param($a)
    ($a -is [System.Management.Automation.Language.CommandAst]) -and
    ($a.GetCommandName() -eq 'Start-ThreadJob') -and
    ($a.Extent.Text -match 'gmSemState')
}, $true))

function Get-ScriptBlockArg {
    param($CommandAst)
    for ($i = 1; $i -lt $CommandAst.CommandElements.Count; $i++) {
        $el = $CommandAst.CommandElements[$i]
        if (($el -is [System.Management.Automation.Language.CommandParameterAst]) -and ($el.ParameterName -eq 'ScriptBlock')) {
            $next = $CommandAst.CommandElements[$i + 1]
            if ($next -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { return $next }
        }
    }
    return $null
}

Describe 'gm-semantic thread job regression lock (VAD-3apv)' {
    It 'launcher parses without syntax errors' {
        $parseErrors.Count | Should Be 0
    }

    It 'has exactly one Start-ThreadJob that binds gmSemState' {
        $jobCalls.Count | Should Be 1
    }

    It 'thread-job scriptblock starts with param() as its FIRST statement' {
        $sb = Get-ScriptBlockArg $jobCalls[0]
        $sb | Should Not Be $null
        $sast = $sb.ScriptBlock
        $sast | Should Not Be $null
        # A leading param() is exposed as ScriptBlockAst.ParamBlock; the parser
        # only sets it when param is the FIRST statement. The VAD-3apv bug had
        # statements before param(), which turned param into a runtime command
        # (ParamBlock null + a 'param' CommandAst in the statement list).
        $sast.ParamBlock | Should Not Be $null
        $names = @($sast.ParamBlock.Parameters | ForEach-Object { $_.Name.Extent.Text })
        # NOTE: boolean checks, not Pester 3 'Should Contain' (that operator
        # treats a string actual as a file path and mis-reports array actuals).
        ($names -ccontains '$State') | Should Be $true
        # VAD-lnhe follow-up (2026-09-06): the job now receives the build/probe
        # functions as SOURCE TEXT ($BuildSrc/$ProbeSrc) and rebuilds them with
        # [scriptblock]::Create inside the job runspace (a function passed as an
        # argument is parent-session-bound; its cmdlets do not resolve across
        # the runspace hop). Paths ride in as plain strings ($BuildDir/$RunLog).
        ($names -ccontains '$BuildSrc') | Should Be $true
        ($names -ccontains '$ProbeSrc') | Should Be $true
        ($names -ccontains '$BuildDir') | Should Be $true
        ($names -ccontains '$RunLog') | Should Be $true
        # Belt and braces: no top-level statement may invoke 'param' as a
        # command (that is exactly what the pre-param statements produced).
        $paramCmds = @($sast.EndBlock.Statements | Where-Object {
            ($_ -is [System.Management.Automation.Language.CommandAst]) -and
            ($_.GetCommandName() -eq 'param')
        })
        $paramCmds.Count | Should Be 0
    }

    It 'defines $global:gmSemState exactly once, with every consumer key' {
        $defs = @($ast.FindAll({ param($a)
            ($a -is [System.Management.Automation.Language.AssignmentStatementAst]) -and
            ($a.Left.Extent.Text -eq '$global:gmSemState')
        }, $true))
        $defs.Count | Should Be 1
        $text = $defs[0].Right.Expression.Extent.Text
        foreach ($key in @('Live', 'Changed', 'LastBuild', 'PopupShown')) {
            ($text -match ('\b' + $key + '\b\s*=')) | Should Be $true
        }
    }

    It 'surfaces job failure (controller loop drains a stopped job; Failed flag has a consumer)' {
        $c = Get-Content -LiteralPath $launcher -Raw
        $c | Should Match 'gmSemJob\.State'
        $c | Should Match 'Receive-Job -Job \$gmSemJob'
        $c | Should Match 'gmSemState\.Failed'
    }
}

# Pester 3.x re-runs this very file when Invoke-Pester scans the parent dir,
# because a *.tests.ps1 that itself calls Invoke-Pester loops forever. Guard
# with an env var (same pattern as launcher_gm_semantic_build.tests.ps1).
if (-not $env:GM_SEM_THREADJOB_TEST_RAN) {
    $env:GM_SEM_THREADJOB_TEST_RAN = '1'
    Invoke-Pester -Path $MyInvocation.MyCommand.Path
}
