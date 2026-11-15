#!/usr/bin/env python3
"""
Raspberry Pi Live Camera Web Streamer & Photo Capture Tool.
- Streams live video (640x480) over HTTP to any web browser.
- Live Invert (180° flip) toggle for ceiling-mounted cameras.
- Saves snapshots directly to ~/Desktop/images (creates folder if not present).
"""

import glob
import io
import logging
import os
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s", datefmt="%H:%M:%S")
LOG = logging.getLogger("PiCameraWeb")

# Auto-create Desktop/images directory
SAVE_DIR = os.path.expanduser("~/Desktop/images")
os.makedirs(SAVE_DIR, exist_ok=True)

# Try imports
try:
    from PIL import Image
except ImportError:
    Image = None

try:
    import cv2
except ImportError:
    cv2 = None

from picamera2 import Picamera2

cam = Picamera2()
config = cam.create_video_configuration(main={"size": (640, 480), "format": "RGB888"})
cam.configure(config)
cam.start()
time.sleep(1)

# Default to inverted (180 deg) for ceiling mount
is_inverted = True

HTML_PAGE = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Classroom Camera Capture Hub</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      background: #0b0f19;
      color: #f1f5f9;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      min-height: 100vh;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      padding: 16px;
    }
    .container {
      width: 100%;
      max-width: 720px;
      background: #151e32;
      border: 1px solid #1e293b;
      border-radius: 16px;
      padding: 20px;
      box-shadow: 0 10px 30px rgba(0,0,0,0.5);
      text-align: center;
    }
    .header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      margin-bottom: 14px;
      padding-bottom: 10px;
      border-bottom: 1px solid #1e293b;
    }
    .title {
      font-size: 1.15rem;
      font-weight: 700;
      color: #38bdf8;
    }
    .badge {
      background: #10b981;
      color: #fff;
      font-size: 0.75rem;
      font-weight: 700;
      padding: 4px 10px;
      border-radius: 20px;
    }
    .video-box {
      background: #000;
      border-radius: 12px;
      overflow: hidden;
      border: 2px solid #334155;
    }
    img {
      width: 100%;
      max-width: 640px;
      height: auto;
      display: block;
      margin: 0 auto;
    }
    .controls {
      display: flex;
      gap: 12px;
      justify-content: center;
      margin-top: 16px;
      flex-wrap: wrap;
    }
    .btn {
      border: none;
      padding: 12px 22px;
      font-size: 1rem;
      font-weight: 700;
      border-radius: 8px;
      cursor: pointer;
      transition: all 0.15s ease;
    }
    .btn-snap {
      background: #0284c7;
      color: #fff;
    }
    .btn-snap:hover { background: #0369a1; }
    .btn-invert {
      background: #334155;
      color: #cbd5e1;
      border: 1px solid #475569;
    }
    .btn-invert:hover { background: #475569; color: #fff; }
    #msg {
      margin-top: 12px;
      font-size: 0.95rem;
      font-weight: 600;
      min-height: 24px;
      color: #4ade80;
    }
    .info {
      margin-top: 10px;
      font-size: 0.8rem;
      color: #94a3b8;
    }
  </style>
</head>
<body>
  <div class="container">
    <div class="header">
      <div class="title">📷 Classroom Camera Stream & Capture</div>
      <div class="badge">LIVE FEED</div>
    </div>
    <div class="video-box">
      <img id="stream_img" src="/stream.mjpg" alt="Live Camera Feed" />
    </div>
    <div class="controls">
      <button class="btn btn-snap" onclick="snapPhoto()">📸 Click & Save Photo</button>
      <button class="btn btn-invert" id="inv_btn" onclick="toggleInvert()">🔄 Flip 180° (Invert)</button>
    </div>
    <div id="msg"></div>
    <div class="info">Saving to: <code>~/Desktop/images/</code> (640×480)</div>
  </div>
  <script>
    function snapPhoto() {
      const msg = document.getElementById('msg');
      msg.style.color = '#38bdf8';
      msg.innerText = 'Capturing snapshot...';
      fetch('/snap').then(r => r.text()).then(txt => {
        msg.style.color = '#4ade80';
        msg.innerText = txt;
        setTimeout(() => { if (msg.innerText === txt) msg.innerText = ''; }, 4000);
      }).catch(err => {
        msg.style.color = '#f87171';
        msg.innerText = 'Error saving photo: ' + err;
      });
    }
    function toggleInvert() {
      fetch('/toggle_invert').then(r => r.json()).then(data => {
        const btn = document.getElementById('inv_btn');
        btn.innerText = data.inverted ? '🔄 Flip 180° (Inverted: ON)' : '🔄 Flip 180° (Inverted: OFF)';
        const msg = document.getElementById('msg');
        msg.style.color = '#38bdf8';
        msg.innerText = data.inverted ? 'Camera Inverted (180° upside-down)' : 'Camera Upright (Normal)';
        setTimeout(() => msg.innerText = '', 2000);
      });
    }
  </script>
</body>
</html>
"""


def get_next_filename() -> str:
    pattern = os.path.join(SAVE_DIR, "classroom_snap_*.jpg")
    existing = glob.glob(pattern)
    max_num = 0
    for p in existing:
        base = os.path.basename(p)
        try:
            num = int(base.replace("classroom_snap_", "").replace(".jpg", ""))
            if num > max_num:
                max_num = num
        except ValueError:
            pass
    next_num = max_num + 1
    return os.path.join(SAVE_DIR, f"classroom_snap_{next_num:03d}.jpg")


def get_current_frame_bytes(invert: bool) -> tuple[bytes, object]:
    frame = cam.capture_array()
    if invert:
        # 180 degree flip (both axes)
        frame = frame[::-1, ::-1]

    if Image is not None:
        img = Image.fromarray(frame)
        buf = io.BytesIO()
        img.save(buf, format="JPEG", quality=80)
        return buf.getvalue(), img

    if cv2 is not None:
        frame_bgr = cv2.cvtColor(frame, cv2.COLOR_RGB2BGR)
        _, jpeg = cv2.imencode(".jpg", frame_bgr, [int(cv2.IMWRITE_JPEG_QUALITY), 80])
        return jpeg.tobytes(), frame_bgr

    buf = io.BytesIO()
    cam.capture_file(buf, format="jpeg")
    return buf.getvalue(), None


class WebHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_GET(self):
        global is_inverted
        if self.path in ("/", "/index.html"):
            content = HTML_PAGE.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(content)))
            self.end_headers()
            self.wfile.write(content)

        elif self.path == "/toggle_invert":
            is_inverted = not is_inverted
            res = f'{{"inverted": {str(is_inverted).lower()}}}'.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(res)

        elif self.path == "/snap":
            filepath = get_next_filename()
            _, raw_obj = get_current_frame_bytes(is_inverted)
            if Image is not None and isinstance(raw_obj, Image.Image):
                raw_obj.save(filepath, "JPEG", quality=95)
            elif cv2 is not None:
                cv2.imwrite(filepath, raw_obj)
            else:
                cam.capture_file(filepath)

            basename = os.path.basename(filepath)
            msg = f"Saved: ~/Desktop/images/{basename}"
            LOG.info(f"Captured: {filepath}")
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(msg.encode("utf-8"))

        elif self.path == "/stream.mjpg":
            self.send_response(200)
            self.send_header("Age", "0")
            self.send_header("Cache-Control", "no-cache, private")
            self.send_header("Pragma", "no-cache")
            self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=FRAME")
            self.end_headers()
            try:
                while True:
                    jpg_bytes, _ = get_current_frame_bytes(is_inverted)
                    if jpg_bytes:
                        self.wfile.write(b"--FRAME\r\nContent-Type: image/jpeg\r\n\r\n" + jpg_bytes + b"\r\n")
                    time.sleep(0.04)
            except Exception:
                pass
        else:
            self.send_error(404)


def main():
    server = ThreadingHTTPServer(("0.0.0.0", 8000), WebHandler)
    LOG.info("=" * 60)
    LOG.info(f"  Camera Web Streamer Running on http://0.0.0.0:8000")
    LOG.info(f"  Saving snapshots to: {SAVE_DIR}")
    LOG.info("=" * 60)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        LOG.info("Stopping...")
    finally:
        cam.stop()
        cam.close()


if __name__ == "__main__":
    main()
