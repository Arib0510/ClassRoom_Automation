#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
if [[ ! -f config/mqtt.env ]]; then
  echo 'Copy config/mqtt.env.example to config/mqtt.env and add the pi-vision password.' >&2
  exit 1
fi
chmod 600 config/mqtt.env
set -a
# shellcheck disable=SC1091
. config/mqtt.env
set +a
: "${CLASSROOM_MQTT_HOST:?Set broker host in config/mqtt.env}"
: "${CLASSROOM_MQTT_USERNAME:?Set pi-vision username in config/mqtt.env}"
: "${CLASSROOM_MQTT_PASSWORD:?Set pi-vision password in config/mqtt.env}"
exec .venv-pi5/bin/python scripts/run_classroom_vision.py \
  --model models/classroom_yolo_best.pt \
  --broker "$CLASSROOM_MQTT_HOST" --port 1883 --room reb_room_301 \
  --mode DRY_RUN --dry-run-only --source picam
