#!/usr/bin/env bash
# Run in a NEW verified release directory as its application owner. Does not start services.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
if [[ $EUID -eq 0 ]]; then
  echo 'Run as the application user; sudo is used only for additive OS packages.' >&2
  exit 1
fi
/usr/bin/python3 - <<'PY'
import pathlib, platform, struct, sys
assert sys.version_info[:2] == (3,11), 'Use Bookworm Python 3.11'
assert struct.calcsize('P') == 4 and platform.machine() in ('armv7l','armv8l'), 'Use armhf 32-bit'
assert 'VERSION_CODENAME=bookworm' in pathlib.Path('/etc/os-release').read_text(), 'Use Bookworm'
PY
/usr/bin/python3 scripts/build_phase5_package.py verify --root .
sudo apt-get update
sudo apt-get install -y --no-remove --no-install-recommends \
  python3-venv python3-pip python3-numpy python3-pil python3-yaml python3-picamera2
if [[ -e .venv-phase5 ]]; then
  echo 'Existing environment preserved; use a new release directory.' >&2
  exit 1
fi
/usr/bin/python3 -m venv --system-site-packages .venv-phase5
.venv-phase5/bin/python -m pip install --only-binary=:all: -r requirements-pi.txt
.venv-phase5/bin/python scripts/check_environment.py --pi
.venv-phase5/bin/python -m src.phase5_runtime check
echo 'Prepared OBSERVE package; no camera, MQTT connection or service was started.'
echo 'Review phase5_pi_deployment.md before explicitly running hardware tests.'
