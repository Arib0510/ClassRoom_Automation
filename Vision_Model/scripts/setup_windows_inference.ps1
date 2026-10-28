# Optional heavyweight CPU runtime, kept entirely in its own local environment.
[CmdletBinding()]
param([string]$Python = 'python')
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$InferencePython = Join-Path $RepoRoot '.venv-inference\Scripts\python.exe'

function Invoke-Checked {
    param([string]$Executable, [string[]]$Arguments)
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Command failed: $Executable ($LASTEXITCODE)" }
}

Push-Location -LiteralPath $RepoRoot
try {
    $CheckHost = 'import sys,struct,platform; assert sys.platform == "win32" and struct.calcsize("P") == 8 and platform.machine() == "AMD64", "Requires native Windows x86-64"; assert sys.version_info[:2] == (3,12), "Use CPython 3.12 for this validated environment"'
    Invoke-Checked $Python @('-c', $CheckHost)
    if (-not (Test-Path -LiteralPath $InferencePython)) {
        Invoke-Checked $Python @('-m', 'venv', (Join-Path $RepoRoot '.venv-inference'))
    }
    Invoke-Checked $InferencePython @('-c', $CheckHost)
    Invoke-Checked $InferencePython @('-m', 'pip', 'install', '--no-cache-dir', '--only-binary=:all:', '-r', 'requirements-windows-inference-lock.txt')
    Invoke-Checked $InferencePython @('-m', 'pip', 'install', '--no-cache-dir', '--no-deps', '-e', '.')
    Invoke-Checked $InferencePython @('-m', 'pip', 'check')
    Invoke-Checked $InferencePython @('scripts/check_environment.py', '--static')
    Invoke-Checked $InferencePython @('scripts/inspect_allocated_model.py', '--runtime', 'tensorflow', '--output', 'outputs/windows_allocation.json')
    Write-Output 'Native Windows model allocated. Run infer-images explicitly to process photos.'
} finally {
    Pop-Location
}
