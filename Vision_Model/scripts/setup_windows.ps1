# Run from any directory. Installs only into the repository .venv.
[CmdletBinding()]
param([string]$Python = 'python')
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$VenvPython = Join-Path $RepoRoot '.venv\Scripts\python.exe'

function Invoke-Checked {
    param([string]$Executable, [string[]]$Arguments)
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Command failed: $Executable ($LASTEXITCODE)" }
}

Push-Location -LiteralPath $RepoRoot
try {
    Invoke-Checked $Python @('-c', 'import sys; assert (3,11) <= sys.version_info[:2] < (3,13), "Use Python 3.11 or 3.12"')
    if (-not (Test-Path -LiteralPath $VenvPython)) {
        Invoke-Checked $Python @('-m', 'venv', (Join-Path $RepoRoot '.venv'))
    }
    Invoke-Checked $VenvPython @('-m', 'pip', 'install', '--no-cache-dir', '-r', 'requirements-windows.txt')
    Invoke-Checked $VenvPython @('-m', 'pip', 'install', '--no-cache-dir', '--no-deps', '-e', '.')
    Invoke-Checked $VenvPython @('scripts/fetch_model.py')
    Invoke-Checked $VenvPython @('scripts/check_environment.py', '--static')
    Invoke-Checked $VenvPython @('-m', 'pytest')
    Invoke-Checked $VenvPython @('-m', 'ruff', 'check', '.')
    Invoke-Checked $VenvPython @('-m', 'ruff', 'format', '--check', '.')
    Write-Output 'Windows software workspace ready. No hardware tests performed.'
} finally {
    Pop-Location
}
