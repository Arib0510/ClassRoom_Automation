# Repository instructions

- Target Raspberry Pi Zero 2 W, Raspberry Pi OS Bookworm 32-bit, Python 3.11.
- Keep changes within this repository. Do not access cameras, benchmark inference,
  train models, or operate ESP32 hardware unless the user explicitly requests it.
- Keep Pi dependencies lightweight: NumPy, Pillow, PyYAML, Paho MQTT,
  tflite-runtime, and the OS Picamera2/libcamera packages. No full TensorFlow.
- Preserve explicit SSD output mapping, quantization checks, and model provenance.
  Never identify output tensors or class IDs by guesswork.
- Four zones represent physical room quadrants. Example image polygons require
  on-site calibration; never claim a geometric image split is physically calibrated.
- Preserve unknown/stale occupancy semantics, MQTT expiry, and bounded buffering.
- Run `python -m pytest`, `ruff check .`, `ruff format --check .`, and
  `python scripts/check_environment.py --static` after meaningful code changes.
- Software validation is not camera, accuracy, latency, or hardware validation.
