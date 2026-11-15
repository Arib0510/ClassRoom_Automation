#!/usr/bin/env python3
"""
ClassPulse Classroom Vision Training Data Collector (True-Color Edition).

Fixes classroom color cast:
  • Corrects Auto White Balance (AWB) under fluorescent/LED classroom lights.
  • Removes the greenish-yellow tint caused by green curtains & mercury light spikes.
  • Provides live White Balance presets (Fluorescent, Indoor, Daylight, Auto) switchable from the browser.
  • Retains max resolution (1920x1440 or sensor native) and lossless PNG / 100% JPEG saving.
"""

import argparse
import glob
import io
import json
import logging
import os
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
LOG = logging.getLogger("ColorCollector")

SAVE_DIR = os.path.expanduser("~/Desktop/images")
os.makedirs(SAVE_DIR, exist_ok=True)

SESSION_ID = uuid.uuid4().hex[:8]


class ColorCorrectedCollector:
    def __init__(self, port: int = 8000, target_res: tuple[int, int] | None = None, invert: bool = True):
        self.port = port
        self.invert = invert
        self.frame_idx = 1
        self.lock = threading.Lock()
        self.latest_full_rgb = None
        self.latest_preview_jpeg = None
        self.running = True
        self.current_awb = "fluorescent" # Default to fluorescent to remove classroom green tint

        self._init_camera(target_res)

        self.capture_thread = threading.Thread(target=self._loop, daemon=True)
        self.capture_thread.start()

    def _init_camera(self, target_res: tuple[int, int] | None):
        try:
            from picamera2 import Picamera2

            self.cam = Picamera2()

            if target_res is not None:
                self.max_w, self.max_h = target_res
            else:
                try:
                    s_res = self.cam.sensor_resolution
                    self.max_w, self.max_h = int(s_res[0]), int(s_res[1])
                except Exception:
                    self.max_w, self.max_h = 1920, 1440

            # Cap stream size to 1920x1440 for optimal frame rate & color processing
            if self.max_w > 2304:
                self.max_w, self.max_h = 2304, 1728

            self.mp = (self.max_w * self.max_h) / 1_000_000.0
            LOG.info(f"Setting Resolution: {self.max_w}x{self.max_h} ({self.mp:.1f} MP)")

            config = self.cam.create_video_configuration(
                main={"size": (self.max_w, self.max_h), "format": "RGB888"},
                controls={"FrameRate": 20.0},
            )
            self.cam.configure(config)

            # Set initial white balance for classroom fluorescent lighting
            self.set_awb(self.current_awb)

            self.cam.start()
            time.sleep(1.5)  # AWB settle
            LOG.info(f"Camera live with '{self.current_awb}' White Balance")

        except Exception as e:
            LOG.error(f"Camera init error: {e}")
            sys.exit(1)

    def set_awb(self, mode: str):
        try:
            from libcamera import controls

            awb_map = {
                "fluorescent": controls.AwbModeEnum.Fluorescent,
                "indoor": controls.AwbModeEnum.Incandescent,
                "auto": controls.AwbModeEnum.Auto,
                "daylight": controls.AwbModeEnum.Daylight,
            }
            target_enum = awb_map.get(mode.lower(), controls.AwbModeEnum.Fluorescent)
            self.cam.set_controls({
                "AwbMode": target_enum,
                "Sharpness": 1.0, # Natural sharpness
                "Contrast": 1.0,  # Natural contrast
                "Saturation": 1.0,
            })
            self.current_awb = mode.lower()
            LOG.info(f"Switched White Balance Mode to: {self.current_awb.upper()}")
        except Exception as e:
            LOG.warning(f"Could not set AWB mode {mode}: {e}")

    def _loop(self):
        import cv2

        while self.running:
            try:
                frame_rgb = self.cam.capture_array()

                if self.invert:
                    frame_rgb = frame_rgb[::-1, ::-1]

                # Web preview
                prev_h = int(960 * (self.max_h / self.max_w))
                prev_rgb = cv2.resize(frame_rgb, (960, prev_h), interpolation=cv2.INTER_AREA)
                prev_bgr = cv2.cvtColor(prev_rgb, cv2.COLOR_RGB2BGR)
                ret, jpeg = cv2.imencode(".jpg", prev_bgr, [int(cv2.IMWRITE_JPEG_QUALITY), 80])

                with self.lock:
                    self.latest_full_rgb = frame_rgb
                    if ret:
                        self.latest_preview_jpeg = jpeg.tobytes()

                time.sleep(0.04)
            except Exception as e:
                LOG.warning(f"Loop error: {e}")
                time.sleep(0.1)

    def snap(self) -> tuple[str, str, int, int]:
        import cv2

        with self.lock:
            if self.latest_full_rgb is None:
                raise RuntimeError("Frame not ready yet")
            full_rgb = self.latest_full_rgb.copy()
            idx = self.frame_idx
            self.frame_idx += 1

        h, w = full_rgb.shape[:2]
        fname_base = f"classroom_{SESSION_ID}-{idx:04d}"
        img_name = f"{fname_base}_clean.png"
        jpg_name = f"{fname_base}_clean.jpg"
        img_path = os.path.join(SAVE_DIR, img_name)
        jpg_path = os.path.join(SAVE_DIR, jpg_name)
        meta_path = os.path.join(SAVE_DIR, f"{fname_base}_metadata.json")

        full_bgr = cv2.cvtColor(full_rgb, cv2.COLOR_RGB2BGR)

        # 1. Lossless PNG
        cv2.imwrite(img_path, full_bgr, [int(cv2.IMWRITE_PNG_COMPRESSION), 1])
        # 2. 100% Quality JPEG
        cv2.imwrite(jpg_path, full_bgr, [int(cv2.IMWRITE_JPEG_QUALITY), 100])

        meta = {
            "frame_id": fname_base,
            "session_id": SESSION_ID,
            "image_size_wh": [w, h],
            "megapixels": round((w * h) / 1_000_000.0, 2),
            "color_format": "RGB888",
            "awb_mode": self.current_awb,
            "inverted": self.invert,
            "timestamp": time.time(),
            "clean_image": True,
        }
        with open(meta_path, "w", encoding="utf-8") as f:
            json.dump(meta, f, indent=2)

        LOG.info(f"[SAVED] {img_name} ({w}x{h}, {self.current_awb.upper()} AWB)")
        return img_name, img_path, w, h


HTML = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>ClassPulse - True Color Camera Calibration</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      background: #080c14;
      color: #f1f5f9;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      min-height: 100vh;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      padding: 16px;
    }
    .card {
      width: 100%;
      max-width: 860px;
      background: #101726;
      border: 1px solid #1e293b;
      border-radius: 16px;
      padding: 22px;
      box-shadow: 0 10px 40px rgba(0,0,0,0.7);
      text-align: center;
    }
    .header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      margin-bottom: 14px;
      border-bottom: 1px solid #1e293b;
      padding-bottom: 12px;
    }
    .title {
      font-size: 1.25rem;
      font-weight: 700;
      color: #38bdf8;
    }
    .video-box {
      background: #000;
      border-radius: 12px;
      overflow: hidden;
      border: 2px solid #334155;
      margin-bottom: 16px;
    }
    img {
      width: 100%;
      max-width: 820px;
      height: auto;
      display: block;
      margin: 0 auto;
    }
    .color-panel {
      background: #0f172a;
      border: 1px solid #1e293b;
      border-radius: 10px;
      padding: 12px 16px;
      margin-bottom: 16px;
      display: flex;
      align-items: center;
      justify-content: center;
      gap: 10px;
      flex-wrap: wrap;
    }
    .color-label {
      font-size: 0.9rem;
      font-weight: 700;
      color: #94a3b8;
    }
    .btn-awb {
      background: #1e293b;
      color: #cbd5e1;
      border: 1px solid #334155;
      padding: 8px 16px;
      border-radius: 6px;
      font-size: 0.85rem;
      font-weight: 600;
      cursor: pointer;
      transition: all 0.15s;
    }
    .btn-awb:hover { background: #334155; color: white; }
    .btn-awb.active {
      background: #0284c7;
      color: white;
      border-color: #38bdf8;
      box-shadow: 0 0 10px rgba(2, 132, 199, 0.5);
    }
    .actions {
      display: flex;
      gap: 12px;
      justify-content: center;
      flex-wrap: wrap;
    }
    .btn {
      border: none;
      padding: 14px 28px;
      font-size: 1.05rem;
      font-weight: 700;
      border-radius: 10px;
      cursor: pointer;
      transition: all 0.2s;
    }
    .btn-snap {
      background: #0284c7;
      color: white;
      box-shadow: 0 4px 14px rgba(2, 132, 199, 0.4);
    }
    .btn-snap:hover { background: #0369a1; transform: translateY(-1px); }
    .btn-invert {
      background: #1e293b;
      color: #cbd5e1;
      border: 1px solid #334155;
    }
    .btn-invert:hover { background: #334155; color: white; }
    #msg {
      margin-top: 14px;
      min-height: 28px;
      font-size: 1rem;
      font-weight: 600;
      color: #10b981;
    }
  </style>
</head>
<body>
  <div class="card">
    <div class="header">
      <div class="title">🎨 True-Color Classroom Camera Calibrator</div>
      <div style="font-size:0.8rem; color:#94a3b8;">PI 5 ULTRA-HD</div>
    </div>

    <div class="video-box">
      <img src="/stream.mjpg" alt="Classroom Live Stream" />
    </div>

    <!-- Live White Balance Tuning Panel -->
    <div class="color-panel">
      <span class="color-label">💡 White Balance (AWB):</span>
      <button class="btn-awb active" id="btn_fluorescent" onclick="setAWB('fluorescent')">Tube Lights (Fluorescent)</button>
      <button class="btn-awb" id="btn_indoor" onclick="setAWB('indoor')">Warm Indoor</button>
      <button class="btn-awb" id="btn_daylight" onclick="setAWB('daylight')">Daylight / Windows Open</button>
      <button class="btn-awb" id="btn_auto" onclick="setAWB('auto')">Auto</button>
    </div>

    <div class="actions">
      <button class="btn btn-snap" onclick="snap()">📸 Click & Save True-Color Photo</button>
      <button class="btn btn-invert" onclick="toggleInvert()">🔄 Toggle 180° Invert</button>
    </div>

    <div id="msg"></div>
  </div>

  <script>
    function setAWB(mode) {
      document.querySelectorAll('.btn-awb').forEach(b => b.classList.remove('active'));
      const activeBtn = document.getElementById('btn_' + mode);
      if (activeBtn) activeBtn.classList.add('active');

      const msg = document.getElementById('msg');
      msg.style.color = '#38bdf8';
      msg.innerText = 'Adjusting color balance for ' + mode + '...';

      fetch('/set_awb?mode=' + mode).then(r => r.json()).then(d => {
        msg.style.color = '#10b981';
        msg.innerText = 'Color Balance set to: ' + mode.toUpperCase() + ' (Wait 1-2s for sensor to adjust)';
        setTimeout(() => msg.innerText = '', 3000);
      });
    }

    function snap() {
      const msg = document.getElementById('msg');
      msg.style.color = '#38bdf8';
      msg.innerText = 'Saving true-color training frame...';
      fetch('/snap').then(r => r.json()).then(data => {
        if (data.ok) {
          msg.style.color = '#10b981';
          msg.innerText = '✓ Saved ' + data.filename + ' (' + data.size + ', ' + data.count + ' total)';
          setTimeout(() => { if (msg.innerText.includes(data.filename)) msg.innerText = ''; }, 4500);
        }
      });
    }

    function toggleInvert() {
      fetch('/toggle_invert').then(r => r.json()).then(d => {
        const msg = document.getElementById('msg');
        msg.style.color = '#38bdf8';
        msg.innerText = d.inverted ? 'Inverted (180°)' : 'Upright';
        setTimeout(() => msg.innerText = '', 2000);
      });
    }
  </script>
</body>
</html>
"""


class WebHandler(BaseHTTPRequestHandler):
    collector = None

    def log_message(self, format, *args):
        pass

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(HTML.encode("utf-8"))

        elif self.path.startswith("/set_awb"):
            mode = "fluorescent"
            if "mode=" in self.path:
                mode = self.path.split("mode=")[-1].split("&")[0]
            self.collector.set_awb(mode)
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"ok": True, "mode": mode}).encode("utf-8"))

        elif self.path == "/toggle_invert":
            self.collector.invert = not self.collector.invert
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(
                json.dumps({"ok": True, "inverted": self.collector.invert}).encode("utf-8")
            )

        elif self.path == "/snap":
            name, path, w, h = self.collector.snap()
            total = len(glob.glob(os.path.join(SAVE_DIR, "*_clean.png")))
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(
                json.dumps(
                    {
                        "ok": True,
                        "filename": name,
                        "size": f"{w}x{h}",
                        "count": total,
                    }
                ).encode("utf-8")
            )

        elif self.path == "/stream.mjpg":
            self.send_response(200)
            self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=FRAME")
            self.end_headers()
            try:
                while self.collector.running:
                    with self.collector.lock:
                        frame = self.collector.latest_preview_jpeg
                    if frame:
                        self.wfile.write(
                            b"--FRAME\r\nContent-Type: image/jpeg\r\n\r\n" + frame + b"\r\n"
                        )
                    time.sleep(0.04)
            except Exception:
                pass


def main():
    parser = argparse.ArgumentParser(description="ClassPulse True-Color Collector")
    parser.add_argument("--port", type=int, default=8000)
    parser.add_argument("--no-invert", action="store_true")
    args = parser.parse_args()

    collector = ColorCorrectedCollector(port=args.port, invert=not args.no_invert)
    WebHandler.collector = collector

    server = ThreadingHTTPServer(("0.0.0.0", args.port), WebHandler)
    LOG.info("=" * 60)
    LOG.info(f"  True-Color Camera Calibrator running on http://0.0.0.0:{args.port}")
    LOG.info("=" * 60)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        LOG.info("Stopping...")
    finally:
        collector.running = False
        collector.cam.stop()
        collector.cam.close()


if __name__ == "__main__":
    main()
