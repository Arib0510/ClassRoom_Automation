param([string]$Python = "C:/Program Files/Python312/python.exe")
$ErrorActionPreference = "Stop"
Set-Location (Split-Path $PSScriptRoot -Parent)
function Check-Native { if ($LASTEXITCODE -ne 0) { throw "Native command failed: $LASTEXITCODE" } }
if (-not (Test-Path .venv-yolov5/Scripts/python.exe)) {
    & $Python -m venv .venv-yolov5
    Check-Native
}
$ExperimentPython = Join-Path (Get-Location) '.venv-yolov5/Scripts/python.exe'
& $ExperimentPython -c 'import sys, struct; assert sys.platform == "win32" and struct.calcsize("P") == 8 and sys.version_info[:2] == (3, 12), "Use native Windows x64 CPython 3.12"'
Check-Native
$Requirements = 'requirements-windows-yolov5.txt'
if (Test-Path requirements-windows-yolov5-lock.txt) { $Requirements = 'requirements-windows-yolov5-lock.txt' }
& $ExperimentPython -m pip install -r $Requirements
Check-Native
& $ExperimentPython scripts/fetch_yolov5.py
Check-Native
& $ExperimentPython -m pytest tests/integration/test_phase4_real.py --run-real-inference -k 'not all_saved'
Check-Native
