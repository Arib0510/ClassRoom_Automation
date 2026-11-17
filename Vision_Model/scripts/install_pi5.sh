#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ $EUID -eq 0 ]]; then
  echo 'Run as the Desktop application user; the script uses sudo only for apt.' >&2
  exit 1
fi
if [[ "$(uname -m)" != "aarch64" || "$(getconf LONG_BIT)" != "64" ]]; then
  echo 'This deployment requires a 64-bit ARM (aarch64) userland.' >&2
  exit 1
fi
if ! grep -Eq 'Raspberry Pi OS|Debian GNU/Linux' /etc/os-release; then
  echo 'Expected Raspberry Pi OS (Debian-based). See README_DEPLOYMENT.md.' >&2
  exit 1
fi

sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  python3-venv python3-pip python3-numpy python3-opencv python3-picamera2

if [[ -e .venv-pi5 ]]; then
  echo 'Existing .venv-pi5 preserved. Remove it yourself only if you intend to replace it.' >&2
  exit 1
fi
python3 -m venv --system-site-packages .venv-pi5
if ! .venv-pi5/bin/python -m pip install --upgrade pip; then
  echo 'pip upgrade failed. Venv is preserved; verify internet access and retry:' >&2
  echo '  .venv-pi5/bin/python -m pip install --upgrade pip' >&2
  exit 1
fi
if ! .venv-pi5/bin/python -m pip install --only-binary=:all: --no-deps -r requirements-pi5.txt; then
  cat >&2 <<'RECOVERY'
Core dependency installation failed after creating .venv-pi5.
The system packages and venv were left in place; no camera or MQTT was started.
Inspect the wheel/error output, confirm network access and free disk space, then retry:
  .venv-pi5/bin/python -m pip install --upgrade pip
  .venv-pi5/bin/python -m pip install --only-binary=:all: --no-deps -r requirements-pi5.txt
If the venv is damaged, preserve logs and rename it before deliberately recreating:
  mv .venv-pi5 .venv-pi5.failed
  python3 -m venv --system-site-packages .venv-pi5
RECOVERY
  exit 1
fi
if ! .venv-pi5/bin/python -m pip install --only-binary=:all: -r requirements-pi5-support.txt; then
  cat >&2 <<'RECOVERY'
Support dependency installation failed. Core wheels are already installed.
Review the wheel error and confirm network access, free space, CPython 3.13 aarch64.
Retry with:
  .venv-pi5/bin/python -m pip install --only-binary=:all: -r requirements-pi5-support.txt
Do not install opencv-python or opencv-python-headless: they shadow apt OpenCV
used by the RDP Desktop preview. The venv uses --system-site-packages for camera,
NumPy, and OpenCV packages from Raspberry Pi OS.
RECOVERY
  exit 1
fi
.venv-pi5/bin/python scripts/check_pi5_environment.py
.venv-pi5/bin/python scripts/smoke_test_pi5_inference.py
echo 'Install complete. No camera, broker, or appliance command was started.'
