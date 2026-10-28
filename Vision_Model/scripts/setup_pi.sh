#!/usr/bin/env bash
# Bookworm 32-bit setup. No camera access, inference, broker connection or service start.
set -euo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
if [[ ${EUID} -eq 0 ]]; then
  echo 'Run as the application user, not root. sudo is used only for OS packages.' >&2
  exit 1
fi
/usr/bin/python3 - <<'PY'
import pathlib, platform, struct, sys
assert sys.version_info[:2] == (3, 11), 'Requires Bookworm CPython 3.11'
assert struct.calcsize('P') == 4, 'Requires 32-bit Raspberry Pi OS'
assert platform.machine() in ('armv7l', 'armv8l'), 'Requires ARMv7-compatible userland'
assert 'VERSION_CODENAME=bookworm' in pathlib.Path('/etc/os-release').read_text(), 'Requires Bookworm'
PY
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  python3-venv python3-pip python3-picamera2 python3-numpy python3-pil python3-yaml
if [[ ! -x .venv/bin/python ]]; then
  /usr/bin/python3 -m venv --system-site-packages .venv
fi
grep -q 'include-system-site-packages = true' .venv/pyvenv.cfg || {
  echo 'Existing .venv must use --system-site-packages; use a fresh Pi checkout.' >&2
  exit 1
}
# Never build heavyweight packages on a 512 MB Pi; fail if a wheel is unavailable.
.venv/bin/python -m pip install --no-cache-dir --only-binary=:all: -r requirements-pi.txt
.venv/bin/python -m pip install --no-cache-dir --no-deps -e .
.venv/bin/python scripts/fetch_model.py
.venv/bin/python scripts/check_environment.py --pi
echo 'Pi packages prepared. Calibrate zones and configure MQTT before live run.'
