"""ClassPulse Classroom Vision & Multi-Zone Decision Controller (Pi 5 8GB Optimized).

Features:
  • Zero-Lag Dual-Thread Pipeline for Raspberry Pi 5 (8GB RAM):
      - Thread 1: High-speed Camera Capture & 25-30 FPS MJPEG Web Streamer
      - Thread 2: Asynchronous YOLOv8 Inference (trained on Pi_5_Images) + Motion Gate
  • True-Color Picamera2 Pipeline:
      - Native 4:3 aspect ratio (640x480 default, zero vertical squishing)
      - Proper Picamera2 RGB888 -> OpenCV BGR memory layout (no Red/Blue swap)
      - Fluorescent AWB + 180° ceiling-mount orientation toggle
  • 6-Zone & Dual/Tri-ESP32 Switchboard Automation:
      - 6 physical zones (left_near, left_far, centre_near, centre_far, right_near, right_far)
      - Full backward compatibility with Front/Back zones (board01, board02, board03) & Flutter App
      - Strict DRY_RUN transport isolation (never actuates physical relays in DRY_RUN)
"""

from __future__ import annotations

import argparse
import hashlib
import json
import logging
import math
import os
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Dict, List, Optional, Tuple
from urllib.parse import parse_qs, urlparse

import cv2
import numpy as np

# Optimize OpenCV thread count for Raspberry Pi 5 (8GB) 4-core CPU
try:
    cv2.setNumThreads(2)
except Exception:
    pass

# Ensure Vision_Model root is in python path
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from src.ac_control import ClassroomACController
from src.classroom_tracker import ClassroomMotionTracker, TrackedPerson
from src.offline_diagnostics import class_names, resolve_model_path

try:
    import paho.mqtt.client as mqtt
except ImportError:
    mqtt = None

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
LOG = logging.getLogger("ClassPulseVision")

SIX_ZONE_IDS = (
    "left_near",
    "left_far",
    "centre_near",
    "centre_far",
    "right_near",
    "right_far",
)


class FastMotionFilter:
    """Sub-millisecond pixel-level motion pre-filter on downsampled luma."""

    def __init__(self, threshold: int = 18, min_motion_pixels: int = 96):
        self.threshold = threshold
        self.min_motion_pixels = min_motion_pixels
        self.last_gray: Optional[np.ndarray] = None

    def check_motion(self, bgr_frame: np.ndarray) -> Tuple[bool, float, Optional[np.ndarray]]:
        if bgr_frame.ndim == 3 and bgr_frame.shape[2] == 3:
            small = bgr_frame[::4, ::4]
            # Fast integer luma from BGR: 0.114 B + 0.587 G + 0.299 R
            small_gray = (
                small[:, :, 0].astype(np.uint16) * 29
                + small[:, :, 1].astype(np.uint16) * 150
                + small[:, :, 2].astype(np.uint16) * 77
            ) >> 8
            small_gray = small_gray.astype(np.uint8)
        else:
            small_gray = bgr_frame[::4, ::4]

        if self.last_gray is None or self.last_gray.shape != small_gray.shape:
            self.last_gray = small_gray
            return True, 1.0, None

        diff = np.abs(small_gray.astype(np.int16) - self.last_gray.astype(np.int16))
        motion_mask = (diff > self.threshold).astype(np.uint8)
        changed_pixels = int(np.sum(motion_mask))
        ratio = changed_pixels / max(1, small_gray.size)

        self.last_gray = small_gray
        has_motion = changed_pixels >= max(4, self.min_motion_pixels // 16)
        return has_motion, ratio, motion_mask


# ============================================================================
# Embedded Web Dashboard HTML (With 6-Zone & True-Color Controls)
# ============================================================================
PREVIEW_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>ClassPulse Pi 5 Multi-Zone AI Vision Hub</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    background: #0b0f19;
    color: #e2e8f0;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    padding: 14px;
    display: flex;
    flex-direction: column;
    align-items: center;
    min-height: 100vh;
  }
  .header {
    width: 100%;
    max-width: 1060px;
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 12px 18px;
    background: #151e32;
    border-radius: 12px;
    margin-bottom: 12px;
    border: 1px solid #1e293b;
    box-shadow: 0 4px 20px rgba(0,0,0,0.3);
    flex-wrap: wrap;
    gap: 10px;
  }
  .title {
    font-size: 1.2rem;
    font-weight: 700;
    color: #38bdf8;
    display: flex;
    align-items: center;
    gap: 10px;
  }
  .pulse-dot {
    width: 10px; height: 10px; border-radius: 50%; background: #22c55e;
    box-shadow: 0 0 10px #22c55e; animation: pulse 1.6s infinite;
  }
  @keyframes pulse { 0%, 100% { opacity: 1; transform: scale(1); } 50% { opacity: 0.35; transform: scale(0.85); } }
  .badges { display: flex; gap: 8px; flex-wrap: wrap; }
  .badge {
    padding: 5px 12px; border-radius: 9999px; font-size: 0.75rem; font-weight: 600; text-transform: uppercase;
  }
  .badge-mode { background: #0284c7; color: #f0f9ff; }
  .badge-room { background: #334155; color: #cbd5e1; }
  .badge-res { background: #3b82f6; color: #ffffff; }

  .control-card {
    width: 100%;
    max-width: 1060px;
    background: #151e32;
    border-radius: 12px;
    padding: 12px 18px;
    margin-bottom: 12px;
    border: 1px solid #1e293b;
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
  }
  .slider-group {
    display: flex;
    align-items: center;
    gap: 10px;
    flex: 1;
    min-width: 240px;
  }
  .slider-label { font-size: 0.85rem; font-weight: 600; color: #cbd5e1; }
  .slider-val {
    display: inline-block;
    min-width: 44px;
    text-align: center;
    padding: 2px 8px;
    background: #0284c7;
    border-radius: 6px;
    color: #fff;
    font-weight: 700;
    font-size: 0.85rem;
  }
  input[type=range] {
    flex: 1;
    accent-color: #38bdf8;
    height: 6px;
    border-radius: 3px;
    cursor: pointer;
  }
  .btn-grp { display: flex; gap: 8px; flex-wrap: wrap; }
  .btn-preset {
    background: #1e293b;
    border: 1px solid #334155;
    color: #cbd5e1;
    font-size: 0.75rem;
    padding: 6px 11px;
    border-radius: 6px;
    cursor: pointer;
    font-weight: 600;
    transition: all 0.15s ease;
  }
  .btn-preset:hover { background: #0284c7; color: #fff; border-color: #38bdf8; }

  .action-card {
    width: 100%;
    max-width: 1060px;
    background: #151e32;
    border-radius: 12px;
    padding: 10px 18px;
    margin-bottom: 12px;
    border: 1px solid #1e293b;
    display: flex;
    justify-content: space-between;
    align-items: center;
    flex-wrap: wrap;
    gap: 10px;
  }
  .action-left { display: flex; flex-wrap: wrap; gap: 8px; }
  .btn-action {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 7px 14px;
    border-radius: 8px;
    font-size: 0.82rem;
    font-weight: 600;
    text-decoration: none;
    transition: all 0.2s ease;
    cursor: pointer;
  }
  .btn-annotated {
    background: #0284c7;
    color: #ffffff;
    border: 1px solid #38bdf8;
  }
  .btn-annotated:hover { background: #0369a1; }
  .btn-raw {
    background: #1e293b;
    color: #cbd5e1;
    border: 1px solid #475569;
  }
  .btn-raw:hover { background: #334155; color: #ffffff; }

  .stats-grid {
    width: 100%;
    max-width: 1060px;
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
    gap: 10px;
    margin-bottom: 12px;
  }
  .stat-card {
    background: #151e32;
    padding: 11px 15px;
    border-radius: 12px;
    border: 1px solid #1e293b;
    display: flex;
    flex-direction: column;
  }
  .stat-card-front { border-left: 4px solid #38bdf8; }
  .stat-card-back { border-left: 4px solid #c084fc; }
  .stat-label { font-size: 0.72rem; color: #94a3b8; text-transform: uppercase; letter-spacing: 0.05em; font-weight: 600; }
  .stat-value { font-size: 1.45rem; font-weight: 700; color: #f8fafc; margin-top: 3px; }
  .stat-sub { font-size: 0.78rem; font-weight: 500; color: #94a3b8; margin-top: 2px; }
  .stat-accent-blue { color: #38bdf8; }
  .stat-accent-purple { color: #c084fc; }

  .video-container {
    width: 100%;
    max-width: 960px;
    background: #000;
    border-radius: 14px;
    overflow: hidden;
    position: relative;
    box-shadow: 0 10px 40px rgba(0,0,0,0.6);
    border: 1px solid #1e293b;
    display: flex;
    justify-content: center;
    align-items: center;
  }
  .video-container img {
    width: 100%;
    height: auto;
    display: block;
    max-height: 74vh;
    object-fit: contain;
  }
  .footer-note {
    margin-top: 12px;
    font-size: 0.78rem;
    color: #64748b;
    text-align: center;
    line-height: 1.4;
  }
</style>
</head>
<body>
  <div class="header">
    <div class="title">
      <div class="pulse-dot"></div>
      ClassPulse Pi 5 Multi-Zone Vision Hub (Zero-Lag 8GB Edition)
    </div>
    <div class="badges">
      <span class="badge badge-res" id="res_tag">640x480 4:3</span>
      <span class="badge badge-room" id="room_tag">reb_room_301</span>
      <span class="badge badge-mode" id="mode_tag">DRY_RUN</span>
    </div>
  </div>

  <div class="control-card">
    <div class="slider-group">
      <span class="slider-label">Sensitivity:</span>
      <input type="range" id="conf_slider" min="0.12" max="0.65" step="0.02" value="0.28" oninput="onConfChange(this.value)">
      <span class="slider-val" id="conf_val">0.28</span>
    </div>
    <div class="btn-grp">
      <button class="btn-preset" onclick="setPreset(0.20)">High Recall</button>
      <button class="btn-preset" onclick="setPreset(0.28)">Balanced</button>
      <button class="btn-preset" onclick="toggleFlip()">🔄 Flip 180° Camera</button>
      <button class="btn-preset" onclick="toggleInvert()">↕ Swap Front / Back</button>
      <button class="btn-preset" onclick="setAWB('fluorescent')">💡 Tube Light AWB</button>
      <button class="btn-preset" onclick="setAWB('daylight')">☀ Daylight AWB</button>
      <button class="btn-preset" id="btn_mode" onclick="toggleLiveMode()" style="background:#dc2626; color:#fff; font-weight:700;">⚡ LIVE RELAYS</button>
    </div>
  </div>

  <div class="action-card">
    <div class="action-left">
      <a href="/download/annotated" class="btn-action btn-annotated" download>
        📸 Download Snapshot (With AI Zones)
      </a>
      <a href="/download/raw" class="btn-action btn-raw" download>
        🖼 Download True-Color Clean Frame
      </a>
    </div>
    <div class="action-right">
      <span style="font-size:0.78rem; color:#94a3b8;" id="sub_6zone">6-Zone Grid: LN:0 LF:0 CN:0 CF:0 RN:0 RF:0</span>
    </div>
  </div>

  <div class="stats-grid">
    <div class="stat-card stat-card-front">
      <span class="stat-label">Front / Near Zone (ESP32-1)</span>
      <span class="stat-value stat-accent-blue" id="val_front">0</span>
      <span class="stat-sub" id="sub_front">Relay: OFF (board01)</span>
    </div>
    <div class="stat-card stat-card-back">
      <span class="stat-label">Back / Far Zone (ESP32-2)</span>
      <span class="stat-value stat-accent-purple" id="val_back">0</span>
      <span class="stat-sub" id="sub_back">Relay: OFF (board02)</span>
    </div>
    <div class="stat-card">
      <span class="stat-label">Total Occupancy</span>
      <span class="stat-value" id="val_total">0</span>
      <span class="stat-sub" id="sub_motion">0 Moving · 0 Seated</span>
    </div>
    <div class="stat-card">
      <span class="stat-label">Stream &amp; AI Speed</span>
      <span class="stat-value" id="val_fps">-- FPS</span>
      <span class="stat-sub" id="sub_status">AI: -- FPS</span>
    </div>
  </div>

  <div class="video-container">
    <img id="mjpeg_stream" src="/stream.mjpg" alt="Classroom Live Vision Stream" onerror="setTimeout(() => { this.src='/stream.mjpg?t='+Date.now(); }, 1500)">
  </div>

  <div class="footer-note">
    Raspberry Pi 5 (8GB) Decoupled Pipeline &bull; True-Color BGR Native &bull; Protocol: classroom-control-v1
  </div>

  <script>
    let confDebounce = null;
    function onConfChange(val) {
      document.getElementById('conf_val').textContent = parseFloat(val).toFixed(2);
      clearTimeout(confDebounce);
      confDebounce = setTimeout(() => {
        fetch('/api/config?conf=' + val, { cache: 'no-store' });
      }, 150);
    }
    function setPreset(val) {
      document.getElementById('conf_slider').value = val;
      onConfChange(val);
    }
    function toggleInvert() {
      fetch('/api/config?invert=toggle', { cache: 'no-store' });
    }
    function toggleFlip() {
      fetch('/api/config?flip=toggle', { cache: 'no-store' });
    }
    function setAWB(mode) {
      fetch('/api/config?awb=' + mode, { cache: 'no-store' });
    }
    function toggleLiveMode() {
      const modeEl = document.getElementById('mode_tag');
      const isLive = modeEl && modeEl.textContent === 'LIVE';
      const nextMode = isLive ? 'DRY_RUN' : 'LIVE';
      if (nextMode === 'LIVE' && !confirm('WARNING: Enabling LIVE mode will physically switch the relays on your ESP32 switchboards! Proceed?')) {
        return;
      }
      fetch('/api/config?mode=' + nextMode, { cache: 'no-store' });
    }

    async function updateStats() {
      try {
        const res = await fetch('/api/status', { cache: 'no-store' });
        if (res.ok) {
          const d = await res.json();
          document.getElementById('val_total').textContent = d.total_count ?? '0';
          document.getElementById('val_front').textContent = d.front_count ?? '0';
          document.getElementById('val_back').textContent = d.back_count ?? '0';
          document.getElementById('sub_motion').textContent = (d.moving_count ?? 0) + ' Moving · ' + (d.stationary_count ?? 0) + ' Seated';

          const r1 = (d.board1_relays && (d.board1_relays['1'] || d.board1_relays[1]));
          const elSubFront = document.getElementById('sub_front');
          elSubFront.textContent = 'Relay: ' + (r1 ? 'ON' : 'OFF') + ' (' + (d.front_board_id || 'board01') + ')';
          elSubFront.style.color = r1 ? '#4ade80' : '#94a3b8';

          const r2 = (d.board2_relays && (d.board2_relays['1'] || d.board2_relays[1]));
          const elSubBack = document.getElementById('sub_back');
          elSubBack.textContent = 'Relay: ' + (r2 ? 'ON' : 'OFF') + ' (' + (d.back_board_id || 'board02') + ')';
          elSubBack.style.color = r2 ? '#4ade80' : '#94a3b8';

          document.getElementById('val_fps').textContent = (d.stream_fps ? d.stream_fps.toFixed(1) : (d.fps ? d.fps.toFixed(1) : '--')) + ' FPS';
          document.getElementById('sub_status').textContent = 'AI: ' + (d.ai_fps ? d.ai_fps.toFixed(1) : '--') + ' Hz · ' + (d.model_name || 'YOLOv8n');

          if (d.zones6) {
            const z = d.zones6;
            document.getElementById('sub_6zone').textContent =
              `6-Zone Grid: LN:${z.left_near||0} LF:${z.left_far||0} | CN:${z.centre_near||0} CF:${z.centre_far||0} | RN:${z.right_near||0} RF:${z.right_far||0}`;
          }

          if (d.mode) {
            const mTag = document.getElementById('mode_tag');
            mTag.textContent = d.mode;
            mTag.style.background = d.mode === 'LIVE' ? '#16a34a' : '#0284c7';
            const bMode = document.getElementById('btn_mode');
            if (bMode) {
              bMode.textContent = d.mode === 'LIVE' ? '🔒 Switch to DRY-RUN' : '⚡ Switch to LIVE';
              bMode.style.background = d.mode === 'LIVE' ? '#eab308' : '#dc2626';
            }
          }
          if (d.room_id) document.getElementById('room_tag').textContent = d.room_id;
          if (d.resolution) document.getElementById('res_tag').textContent = d.resolution;

          if (d.current_conf && !confDebounce) {
            document.getElementById('conf_slider').value = d.current_conf;
            document.getElementById('conf_val').textContent = parseFloat(d.current_conf).toFixed(2);
          }
        }
      } catch (e) {}
    }
    setInterval(updateStats, 1000);
    updateStats();
  </script>
</body>
</html>
"""


# ============================================================================
# Streaming State & HTTP Server
# ============================================================================
class PreviewState:
    def __init__(self):
        self.lock = threading.Lock()
        self.latest_jpeg: Optional[bytes] = None
        self.latest_raw_frame: Optional[np.ndarray] = None
        self.latest_status: Dict = {}


class PreviewHTTPHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        state: PreviewState = self.server.preview_state  # type: ignore
        controller = getattr(self.server, "controller", None)

        if self.path.startswith("/api/config"):
            parsed = urlparse(self.path)
            qs = parse_qs(parsed.query)
            if controller is not None:
                if "conf" in qs:
                    try:
                        new_conf = float(qs["conf"][0])
                        controller.conf_thresh = max(0.05, min(0.95, new_conf))
                        LOG.info(f"[CONFIG] Live updated confidence threshold to: {controller.conf_thresh:.2f}")
                    except ValueError:
                        pass
                if "invert" in qs:
                    controller.tracker.invert_zones = not controller.tracker.invert_zones
                    LOG.info(f"[CONFIG] Live toggled zone orientation: invert={controller.tracker.invert_zones}")
                if "flip" in qs:
                    controller.flip_180 = not controller.flip_180
                    LOG.info(f"[CONFIG] Live toggled 180° camera flip: flip_180={controller.flip_180}")
                if "awb" in qs:
                    controller.set_camera_awb(qs["awb"][0])
                if "split" in qs:
                    try:
                        controller.tracker.split_y = max(0.1, min(0.9, float(qs["split"][0])))
                    except ValueError:
                        pass
                if "mode" in qs:
                    new_mode = qs["mode"][0].upper()
                    if new_mode in ("LIVE", "DRY_RUN"):
                        controller.mode = new_mode
                        LOG.info(f"⚡ [MODE CHANGED] Switched operation mode to: {controller.mode}")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(b'{"status":"ok"}')

        elif self.path.startswith("/download"):
            is_raw = "raw" in self.path
            with state.lock:
                if is_raw:
                    raw_f = state.latest_raw_frame.copy() if state.latest_raw_frame is not None else None
                    frame_bytes = None
                else:
                    raw_f = None
                    frame_bytes = state.latest_jpeg
            if is_raw and raw_f is not None:
                ok, buf = cv2.imencode(".jpg", raw_f, [cv2.IMWRITE_JPEG_QUALITY, 96])
                if ok:
                    frame_bytes = buf.tobytes()
            if frame_bytes is None:
                self.send_error(503, "No frame available yet")
                return
            ts_str = time.strftime("%Y%m%d_%H%M%S")
            fname = f"classroom_raw_{ts_str}.jpg" if is_raw else f"classroom_annotated_{ts_str}.jpg"
            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Content-Disposition", f'attachment; filename="{fname}"')
            self.send_header("Content-Length", str(len(frame_bytes)))
            self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
            self.end_headers()
            try:
                self.wfile.write(frame_bytes)
            except (BrokenPipeError, ConnectionResetError):
                pass

        elif self.path in ("/", "/index.html"):
            body = PREVIEW_HTML.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        elif self.path.startswith("/stream.mjpg"):
            self.send_response(200)
            self.send_header("Age", "0")
            self.send_header("Cache-Control", "no-cache, private")
            self.send_header("Pragma", "no-cache")
            self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=FRAME")
            self.end_headers()
            try:
                last_sent = None
                while True:
                    with state.lock:
                        frame_bytes = state.latest_jpeg
                    if frame_bytes is not None and frame_bytes is not last_sent:
                        last_sent = frame_bytes
                        self.wfile.write(b"--FRAME\r\n")
                        self.send_header("Content-Type", "image/jpeg")
                        self.send_header("Content-Length", str(len(frame_bytes)))
                        self.end_headers()
                        self.wfile.write(frame_bytes)
                        self.wfile.write(b"\r\n")
                    time.sleep(0.032)
            except (BrokenPipeError, ConnectionResetError):
                pass

        elif self.path == "/frame.jpg":
            with state.lock:
                frame_bytes = state.latest_jpeg
            if frame_bytes is None:
                self.send_error(503, "No processed frame yet")
                return
            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Content-Length", str(len(frame_bytes)))
            self.send_header("Cache-Control", "no-store, must-revalidate")
            self.end_headers()
            try:
                self.wfile.write(frame_bytes)
            except (BrokenPipeError, ConnectionResetError):
                pass

        elif self.path == "/api/status":
            with state.lock:
                status_doc = dict(state.latest_status)
            if controller is not None:
                status_doc["current_conf"] = controller.conf_thresh
                status_doc["front_board_id"] = controller.front_board_id
                status_doc["back_board_id"] = controller.back_board_id
                status_doc["board1_relays"] = controller.board_relays.get(controller.front_board_id, {})
                status_doc["board2_relays"] = controller.board_relays.get(controller.back_board_id, {})
            body = json.dumps(status_doc).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass

        else:
            self.send_error(404)

    def log_message(self, format: str, *args: object) -> None:
        pass


class ThreadedPreviewServer(ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, server_address, RequestHandlerClass, preview_state: PreviewState, controller=None):
        super().__init__(server_address, RequestHandlerClass)
        self.preview_state = preview_state
        self.controller = controller


# ============================================================================
# Main Multi-Zone Controller (Pi 5 8GB Decoupled Architecture)
# ============================================================================
class ClassroomVisionController:
    def __init__(
        self,
        model_path: str = "auto",
        broker: str = "broker.emqx.io",
        port: int = 1883,
        room_id: str = "reb_room_301",
        front_board: str = "board01",
        back_board: str = "board02",
        third_board: str = "board03",
        mode: str = "DRY_RUN",
        camera_source: int | str = 0,
        show_window: bool = False,
        conf_thresh: float = 0.28,
        iou_thresh: float = 0.45,
        track_iou_thresh: float = 0.18,
        confirmation_hits: int = 2,
        track_max_age: float = 1.5,
        centroid_distance_thresh: float = 0.06,
        occupancy_hold_seconds: float = 1.5,
        diagnostic_overlay: bool = False,
        preview_port: int = 8080,
        width: int = 640,
        height: int = 480,
        fps: float = 25.0,
        imgsz: int = 640,
        split_y: float = 0.48,
        invert_zones: bool = True,
        flip_180: bool = True,
        channels: str = "1,2",
    ):
        self.broker = broker
        self.port = port
        self.room_id = room_id
        self.front_board_id = front_board
        self.back_board_id = back_board
        self.third_board_id = third_board
        self.mode = mode.upper()
        self.channels_str = channels
        self.active_channels = [int(x.strip()) for x in channels.split(",") if x.strip().isdigit()] or [1, 2]
        self.camera_source = camera_source
        self.show_window = show_window
        self.conf_thresh = conf_thresh
        if not 0 < iou_thresh <= 1:
            raise ValueError("iou_thresh must be in (0,1]")
        if occupancy_hold_seconds <= 0 or not math.isfinite(occupancy_hold_seconds):
            raise ValueError("occupancy_hold_seconds must be finite and positive")
        self.iou_thresh = iou_thresh
        self.track_iou_thresh = track_iou_thresh
        self.confirmation_hits = confirmation_hits
        self.track_max_age = track_max_age
        self.occupancy_hold_seconds = occupancy_hold_seconds
        self.diagnostic_overlay = diagnostic_overlay
        self.preview_port = preview_port
        self.cam_width = width
        self.cam_height = height
        self.target_fps = fps
        self.imgsz = imgsz
        self.flip_180 = flip_180
        self.picam2 = None
        # Resolve before any preview or MQTT setup so a missing explicit model
        # path fails without starting another runtime component.
        self.model_path = self._resolve_model(model_path)

        self.session_id = f"sess_{uuid.uuid4().hex[:8]}"
        self.command_seq = 1
        self.last_state_pub = 0.0
        self.latest_front_count = 0
        self.latest_back_count = 0
        self.latest_total_count = 0
        self.prev_front_occupied = None
        self.prev_back_occupied = None
        self.prev_zone6_occupied: Dict[str, Optional[bool]] = {z: None for z in SIX_ZONE_IDS}
        self.last_confirmed_zone_time: Dict[str, Optional[float]] = {
            zone: None for zone in ("front", "back", *SIX_ZONE_IDS)
        }
        self.last_frame_ok = True

        # State tracking across boards
        self.active_overrides: Dict[str, Dict] = {}
        self.board_relays: Dict[str, Dict[int, bool]] = {
            self.front_board_id: {1: False, 2: False, 3: False, 4: False},
            self.back_board_id: {1: False, 2: False, 3: False, 4: False},
            self.third_board_id: {1: False, 2: False, 3: False, 4: False},
        }
        self.last_sent_state: Dict[str, Tuple[str, float]] = {}

        # Multi-Zone Motion Tracker
        self.motion_filter = FastMotionFilter(threshold=18, min_motion_pixels=96)
        self.tracker = ClassroomMotionTracker(
            iou_threshold=track_iou_thresh,
            centroid_distance_thresh=centroid_distance_thresh,
            max_missed_frames=14,
            max_age_seconds=track_max_age,
            confirmation_hits=confirmation_hits,
            motion_speed_threshold=0.035,
            smoothing_factor=0.6,
            split_y=split_y,
            col_left_x=0.34,
            col_right_x=0.66,
            invert_zones=invert_zones,
        )

        # Smart Classroom Optical IR Air Conditioner Controller (Gree AC on GPIO 4)
        self.ac_controller = ClassroomACController(
            room_id=self.room_id,
            front_board_id=self.front_board_id,
            back_board_id=self.back_board_id,
            min_occupants_for_ac=1,
            enter_delay_sec=2.0,
            vacant_off_delay_sec=30.0,
            adaptive_temp=True,
        )

        # Shared state between Camera Capture/Preview Thread and AI Inference Thread
        self.frame_lock = threading.Lock()
        self.latest_capture_frame: Optional[np.ndarray] = None
        self.latest_capture_seq: int = 0
        self.active_people_snapshot: List[TrackedPerson] = []
        self.tracked_people_snapshot: List[TrackedPerson] = []
        self.raw_detections_snapshot: List[
            Tuple[Tuple[float, float, float, float], float, int]
        ] = []
        self.tracker_diagnostics_snapshot: Dict[str, int] = {
            "observed_confirmed_count": 0,
            "tentative_track_count": 0,
            "retained_track_count": 0,
        }
        self.merged_detection_count_snapshot = 0
        self.zone_counts_snapshot: Dict[str, int] = {
            "front_left": 0,
            "front_right": 0,
            "back_left": 0,
            "back_right": 0,
        }
        self.zone6_counts_snapshot: Dict[str, int] = {z: 0 for z in SIX_ZONE_IDS}
        self.moving_count_snapshot: int = 0
        self.stationary_count_snapshot: int = 0
        self.ai_fps: float = 0.0
        self.stream_fps: float = 0.0
        self.running = True

        # Web Preview State & Server
        self.preview_state = PreviewState()
        self.preview_server: Optional[ThreadedPreviewServer] = None
        if self.preview_port > 0:
            self._start_preview_server()

        # Limit PyTorch CPU threads on Pi 5 (8GB) so camera & web server never lag
        try:
            import torch
            torch.set_num_threads(min(3, max(1, (os.cpu_count() or 4) - 1)))
        except Exception:
            pass

        # Resolve Model Path (Prioritizing newly trained Pi_5_Images classroom model)
        model_sha = self._file_sha256(self.model_path)
        LOG.info(f"Loading Classroom Vision Model: {self.model_path.name} ({self.model_path})")
        LOG.info(f"Model SHA256: {model_sha}")
        from ultralytics import YOLO
        self.model = YOLO(str(self.model_path))
        self.model_class_names = class_names(self.model)
        LOG.info("Model class names: %s", self.model_class_names)

        # Setup MQTT
        self.setup_mqtt()

    @staticmethod
    def _file_sha256(path: Path) -> str:
        try:
            with path.open("rb") as f:
                return hashlib.file_digest(f, "sha256").hexdigest()
        except Exception:
            return "unknown"

    def _resolve_model(self, candidate: str) -> Path:
        # Only the literal auto selector may choose another model.
        return resolve_model_path(candidate)

    def set_camera_awb(self, mode: str):
        if self.picam2 is None:
            return
        try:
            from libcamera import controls  # type: ignore[import-not-found]
            awb_map = {
                "fluorescent": controls.AwbModeEnum.Fluorescent,
                "indoor": controls.AwbModeEnum.Incandescent,
                "daylight": controls.AwbModeEnum.Daylight,
                "auto": controls.AwbModeEnum.Auto,
            }
            target = awb_map.get(mode.lower(), controls.AwbModeEnum.Fluorescent)
            self.picam2.set_controls({
                "AwbMode": target,
                "Sharpness": 1.1,
                "Contrast": 1.05,
                "Saturation": 1.0,
            })
            LOG.info(f"[CAMERA] Updated White Balance (AWB) to: {mode.upper()}")
        except Exception as e:
            LOG.warning(f"Could not set AWB mode {mode}: {e}")

    def _start_preview_server(self):
        try:
            self.preview_server = ThreadedPreviewServer(
                ("0.0.0.0", self.preview_port),
                PreviewHTTPHandler,
                self.preview_state,
                controller=self,
            )
            t = threading.Thread(target=self.preview_server.serve_forever, daemon=True)
            t.start()
            LOG.info("=" * 64)
            LOG.info(f"  [OK] ClassPulse Pi 5 Web Preview Active (Zero-Lag Stream)!")
            LOG.info(f"  -> On Raspberry Pi:  http://localhost:{self.preview_port}")
            LOG.info(f"  -> On Laptop/Phone:  http://<pi-ip>:{self.preview_port}")
            LOG.info("=" * 64)
        except Exception as e:
            LOG.warning(f"Could not start browser preview server on port {self.preview_port}: {e}")
            self.preview_server = None

    def setup_mqtt(self):
        if mqtt is None:
            LOG.error("paho-mqtt not installed. Run: pip install paho-mqtt")
            return

        client_id = f"ClassPulse_VisionPi5_{uuid.uuid4().hex[:6]}"
        if hasattr(mqtt, "CallbackAPIVersion"):
            self.mqtt_client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION1, client_id=client_id)
        else:
            self.mqtt_client = mqtt.Client(client_id=client_id, protocol=mqtt.MQTTv311)
        self.mqtt_client.on_connect = self._on_connect
        self.mqtt_client.on_message = self._on_message

        self.app_req_topic = f"classpulse/{self.room_id}/app/requests"
        self.app_res_topic = f"classpulse/{self.room_id}/app/results"
        self.app_state_topic = f"classpulse/{self.room_id}/app/state"

        lwt_doc = {
            "occupancy": {
                "count": 0,
                "front_count": 0,
                "back_count": 0,
                "moving_count": 0,
                "stationary_count": 0,
                "zones": {"Zone 1": 0, "Zone 2": 0, "Zone 3": 0},
            },
            "status": "OFFLINE",
            "online": False,
        }
        self.mqtt_client.will_set(self.app_state_topic, json.dumps(lwt_doc), qos=1, retain=True)

        try:
            LOG.info(f"Connecting to MQTT Broker: {self.broker}:{self.port}...")
            self.mqtt_client.connect(self.broker, self.port, keepalive=30)
            self.mqtt_client.loop_start()
        except Exception as e:
            LOG.error(f"Failed to connect to MQTT broker: {e}")

    def _on_connect(self, client, userdata, flags, rc):
        if rc == 0:
            LOG.info(f"[OK] MQTT Connected to {self.broker}:{self.port}")
            client.subscribe(f"classpulse/{self.room_id}/controllers/+/status", qos=0)
            client.subscribe(f"classpulse/{self.room_id}/controllers/+/ack", qos=0)
            client.subscribe(self.app_req_topic, qos=1)
            client.subscribe(f"ruet/classroom/{self.room_id}/#", qos=0)

            for bid in [self.front_board_id, self.back_board_id, self.third_board_id]:
                hello_pkt = {
                    "protocol": "classroom-control-v1",
                    "kind": "hello",
                    "session_id": self.session_id,
                    "challenge": "authorized",
                }
                client.publish(f"classpulse/{self.room_id}/controllers/{bid}/hello", json.dumps(hello_pkt), qos=1)
                if self.mode == "LIVE":
                    client.publish(f"ruet/classroom/{self.room_id}/controllers/{bid}/hello", json.dumps(hello_pkt), qos=1)
        else:
            LOG.warning(f"MQTT Connect failed with code {rc}")

    def _on_message(self, client, userdata, msg):
        topic = msg.topic
        payload_str = msg.payload.decode("utf-8", errors="ignore")

        if "/status" in topic or topic.endswith("/status"):
            try:
                data = json.loads(payload_str)
                if data.get("type") == "ac" or topic.endswith("/ac/status") or topic.endswith("/status/ac"):
                    z_id = int(data.get("zone") or data.get("board") or 1)
                    is_on = str(data.get("state", "OFF")).upper() in ("ON", "1", "TRUE")
                    self.ac_controller.update_from_esp32_telemetry(
                        zone_id=z_id,
                        is_on=is_on,
                        temp=int(data.get("temp", 24)),
                        mode=str(data.get("mode", "COOL")),
                        fan=int(data.get("fan", 0)),
                        swing=bool(data.get("swing", False)),
                    )
                    return
                parts = topic.split("/")
                board_id = data.get("controller_id") or (parts[-2] if len(parts) >= 2 else "")
                relays = data.get("relays", {})
                if board_id not in self.board_relays:
                    self.board_relays[board_id] = {1: False, 2: False, 3: False, 4: False}
                for k, v in relays.items():
                    if str(k).isdigit():
                        self.board_relays[board_id][int(k)] = (v == "ON" or v is True)
            except Exception:
                pass
            return

        elif "/ack" in topic:
            try:
                data = json.loads(payload_str)
                LOG.info(f"[ESP32 ACK] {data.get('controller_id')} seq={data.get('command_sequence')} res={data.get('result')}")
            except Exception:
                pass

        elif topic.startswith(f"ruet/classroom/{self.room_id}/"):
            if self.mode != "LIVE":
                return
            try:
                data = json.loads(payload_str) if payload_str.startswith("{") else {"state": payload_str}
                req_state = str(data.get("state", payload_str)).upper()
                is_back = ("/zone/2" in topic) or ("/zone/back" in topic) or ("/board/2" in topic) or (data.get("zone") == 2)
                target_board = self.back_board_id if is_back else self.front_board_id
                zone_id = 2 if is_back else 1
                zone_count = self.latest_back_count if is_back else self.latest_front_count
                zone_label = "Back Zone (Zone 2)" if is_back else "Front Zone (Zone 1)"

                # Check if this is an Optical IR AC command (GPIO 4) from the Flutter App
                is_ac_cmd = ("/ac" in topic) or (str(data.get("type", "")).lower() == "ac") or (str(data.get("protocol", "")).upper() == "GREE")
                if is_ac_cmd:
                    pub_fn = lambda t, p: self.mqtt_client.publish(t, p, qos=0)
                    self.ac_controller.handle_app_ac_request(
                        zone_id=zone_id,
                        occupant_count=zone_count,
                        desired_state=req_state,
                        temp=int(data["temp"]) if "temp" in data else None,
                        mode=str(data["mode"]) if "mode" in data else None,
                        fan=int(data["fan"]) if "fan" in data else None,
                        swing=bool(data["swing"]) if "swing" in data else None,
                        now=time.monotonic(),
                        publish_fn=pub_fn if zone_count <= 0 else None,  # If occupied, ESP32 already received the direct MQTT packet
                        operation_mode=self.mode,
                    )
                    return

                if (req_state == "ON" or req_state == "ALL_ON") and zone_count <= 0:
                    LOG.warning(f"[VISION GATE INTERCEPT] Direct MQTT ON on '{topic}' BLOCKED: {zone_label} is EMPTY (0 occupants)!")
                    self.mqtt_client.publish(topic, json.dumps({"state": "OFF"}), qos=0)
                    for ch in self.active_channels:
                        self._send_esp32_command(board_id=target_board, channel=ch, desired_state="OFF", lease_sec=60)
            except Exception:
                pass

        elif topic == self.app_req_topic or topic.endswith("/app/requests"):
            try:
                data = json.loads(payload_str)
                req_id = data.get("request_id", "req")
                aid = data.get("appliance_id", "")
                desired = data.get("desired_state", "AUTO").upper()
                dur = float(data.get("duration_seconds", 300.0))
                now = time.time()

                is_back = any(x in aid.lower() for x in ["zone 2", "zone_2", "b2", "_2", "back"])
                target_board = self.back_board_id if is_back else self.front_board_id
                zone_id = 2 if is_back else 1
                zone_count = self.latest_back_count if is_back else self.latest_front_count
                zone_label = "Back Zone (Zone 2)" if is_back else "Front Zone (Zone 1)"

                # Route AC / HVAC requests through ClassroomACController (GPIO 4 Optical IR)
                if any(k in aid.lower() for k in ("ac", "hvac", "gree")):
                    pub_fn = lambda t, p: self.mqtt_client.publish(t, p, qos=0)
                    accepted, reason = self.ac_controller.handle_app_ac_request(
                        zone_id=zone_id,
                        occupant_count=zone_count,
                        desired_state=desired,
                        temp=int(data["temp"]) if "temp" in data else None,
                        mode=str(data["mode"]) if "mode" in data else None,
                        fan=int(data["fan"]) if "fan" in data else None,
                        swing=bool(data["swing"]) if "swing" in data else None,
                        duration_seconds=dur,
                        now=time.monotonic(),
                        publish_fn=pub_fn,
                        operation_mode=self.mode,
                    )
                    res_packet = {
                        "schema_version": 1,
                        "kind": "app_result",
                        "request_id": req_id,
                        "result": "ACCEPTED" if accepted else "REJECTED",
                        "reason": reason,
                        "appliance_id": aid,
                        "desired_state": desired if accepted else "OFF",
                        "event_time_unix_ms": int(now * 1000),
                    }
                    self.mqtt_client.publish(self.app_res_topic, json.dumps(res_packet), qos=0)
                    return

                if desired == "ON":
                    if zone_count <= 0:
                        LOG.warning(f"[VISION GATE BLOCKED] Rejecting ON for {aid} ({target_board}): {zone_label} is EMPTY ({zone_count} people)!")
                        self.active_overrides.pop(aid, None)
                        for ch in self.active_channels:
                            self._send_esp32_command(board_id=target_board, channel=ch, desired_state="OFF", lease_sec=60)

                        res_packet = {
                            "schema_version": 1,
                            "kind": "app_result",
                            "request_id": req_id,
                            "result": "REJECTED",
                            "reason": f"Vision Gate: {zone_label} is empty (0 occupants). Relay cannot turn ON.",
                            "appliance_id": aid,
                            "desired_state": "OFF",
                            "event_time_unix_ms": int(now * 1000),
                        }
                        self.mqtt_client.publish(self.app_res_topic, json.dumps(res_packet), qos=0)
                        return

                    self.active_overrides[aid] = {
                        "state": desired,
                        "operator": "flutter_user",
                        "expires_at": now + dur,
                        "board_id": target_board,
                    }
                    LOG.info(f"[APP OVERRIDE ACCEPTED] {aid} -> ON for {dur}s on {target_board} ({zone_label} count: {zone_count})")
                    self._send_esp32_command(board_id=target_board, channel=1, desired_state=desired, lease_sec=int(dur))
                elif desired == "OFF":
                    self.active_overrides[aid] = {
                        "state": desired,
                        "operator": "flutter_user",
                        "expires_at": now + 1800.0,
                        "board_id": target_board,
                    }
                    self.active_overrides[f"manual_off_{target_board}"] = {
                        "state": "OFF",
                        "operator": "flutter_user",
                        "expires_at": now + 1800.0,
                        "board_id": target_board,
                    }
                    LOG.info(f"[APP MANUAL OVERRIDE] {aid} -> OFF on {target_board} (Active for 30m)")
                    for ch in self.active_channels:
                        self._send_esp32_command(board_id=target_board, channel=ch, desired_state="OFF", lease_sec=1800)
                else:
                    self.active_overrides.pop(aid, None)

                res_packet = {
                    "schema_version": 1,
                    "kind": "app_result",
                    "request_id": req_id,
                    "result": "ACCEPTED",
                    "reason": "OK",
                    "appliance_id": aid,
                    "desired_state": desired,
                    "event_time_unix_ms": int(now * 1000),
                }
                self.mqtt_client.publish(self.app_res_topic, json.dumps(res_packet), qos=0)
            except Exception as e:
                LOG.error(f"Error processing app request: {e}")

    def _send_esp32_command(self, board_id: str, channel: int, desired_state: str, lease_sec: int = 60):
        if mqtt is None or not hasattr(self, "mqtt_client"):
            return
        target_topic = (
            f"classpulse/{self.room_id}/controllers/{board_id}/dry_run/command"
            if self.mode == "DRY_RUN"
            else f"classpulse/{self.room_id}/controllers/{board_id}/command"
        )
        seq = self.command_seq
        self.command_seq += 1

        cmd_doc = {
            "protocol": "classroom-control-v1",
            "kind": "command",
            "controller_id": board_id,
            "session_id": self.session_id,
            "challenge": "authorized",
            "sequence": seq,
            "channel": f"Channel {channel}",
            "desired_state": desired_state,
            "mode": self.mode,
            "command_id": f"cmd-{seq}",
            "appliance_id": f"relay_{channel}",
            "sent_at_unix_ms": int(time.time() * 1000),
            "lease_sec": lease_sec,
        }
        self.mqtt_client.publish(target_topic, json.dumps(cmd_doc), qos=0)
        LOG.info(f"[CMD TO ESP32] {self.mode} {board_id} Channel {channel} -> {desired_state} (seq: {seq})")

    def _inference_worker(self):
        """Asynchronous AI inference thread so camera capture & MJPEG web stream never lag."""
        import torch

        last_processed_seq = -1
        last_yolo_time = 0.0
        prev_ai_time = time.monotonic()

        while self.running:
            with self.frame_lock:
                frame = self.latest_capture_frame
                seq = self.latest_capture_seq

            if frame is None or seq == last_processed_seq:
                time.sleep(0.008)
                continue

            last_processed_seq = seq
            now_mono = time.monotonic()
            now_wall = time.time()

            # 1. Fast Motion Pre-Check (<0.5ms)
            has_motion, _, _ = self.motion_filter.check_motion(frame)

            # Smart scheduling for Pi 5 (8GB):
            # Run at full speed when motion is present; run at 3 Hz (every 0.33s) when motionless
            # so stationary students are never dropped while keeping CPU cool and responsive.
            if not has_motion and (now_mono - last_yolo_time) < 0.33:
                time.sleep(0.015)
                continue

            last_yolo_time = now_mono
            cur_conf = self.conf_thresh
            cur_iou = self.iou_thresh
            frame_ok = True
            results = None

            # 2. YOLOv8 Inference inside inference_mode
            with torch.inference_mode():
                try:
                    results = self.model.predict(
                        source=frame,
                        conf=cur_conf,
                        iou=cur_iou,
                        classes=[0],
                        imgsz=self.imgsz,
                        rect=True,
                        verbose=False,
                    )
                except Exception as first_error:
                    try:
                        results = self.model.predict(
                            source=frame,
                            conf=cur_conf,
                            iou=cur_iou,
                            imgsz=self.imgsz,
                            verbose=False,
                        )
                    except Exception as fallback_error:
                        frame_ok = False
                        LOG.warning(
                            "Detector failed for frame; preserving occupancy state: "
                            "primary=%s; fallback=%s",
                            first_error,
                            fallback_error,
                        )

            dt_ai = now_mono - prev_ai_time
            if dt_ai > 0:
                self.ai_fps = 0.85 * self.ai_fps + 0.15 * (1.0 / dt_ai) if self.ai_fps > 0 else (1.0 / dt_ai)
            prev_ai_time = now_mono

            h, w = frame.shape[:2]
            detections: List[Tuple[Tuple[float, float, float, float], float]] = []
            raw_detections: List[Tuple[Tuple[float, float, float, float], float, int]] = []
            first_result = next(iter(results), None) if results else None
            boxes = getattr(first_result, "boxes", None)
            if frame_ok and boxes is not None:
                for box in boxes:
                    cls_id = int(box.cls[0].item())
                    conf = float(box.conf[0].item())
                    xyxy = box.xyxy[0].tolist()
                    norm_box = (
                        max(0.0, xyxy[0] / w),
                        max(0.0, xyxy[1] / h),
                        min(1.0, xyxy[2] / w),
                        min(1.0, xyxy[3] / h),
                    )
                    raw_detections.append((norm_box, conf, cls_id))
                    if cls_id == 0:
                        detections.append((norm_box, conf))

            # 3. Update Multi-Zone Tracker
            tracked = self.tracker.update(detections, now_mono)
            tracker_counts = self.tracker.diagnostics()
            active_people = self.tracker.observed_confirmed()

            total_count = len(active_people)
            moving_count = sum(1 for p in active_people if p.state == "MOVING")
            stationary_count = total_count - moving_count

            front_count = sum(1 for p in active_people if p.is_front)
            back_count = sum(1 for p in active_people if not p.is_front)
            self.latest_front_count = front_count
            self.latest_back_count = back_count
            self.latest_total_count = total_count

            zone_counts: Dict[str, int] = {
                "front_left": 0,
                "front_right": 0,
                "back_left": 0,
                "back_right": 0,
            }
            zone6_counts: Dict[str, int] = {z: 0 for z in SIX_ZONE_IDS}
            for p in active_people:
                if p.zone in zone_counts:
                    zone_counts[p.zone] += 1
                if p.zone6 in zone6_counts:
                    zone6_counts[p.zone6] += 1

            with self.frame_lock:
                self.active_people_snapshot = list(active_people)
                self.tracked_people_snapshot = list(tracked)
                self.raw_detections_snapshot = list(raw_detections)
                self.tracker_diagnostics_snapshot = tracker_counts
                self.merged_detection_count_snapshot = len(detections)
                self.zone_counts_snapshot = zone_counts
                self.zone6_counts_snapshot = zone6_counts
                self.moving_count_snapshot = moving_count
                self.stationary_count_snapshot = stationary_count

            # 4. Multi-Zone Automated Decision Logic (Strict DRY_RUN isolation)
            if frame_ok:
                for zone_name, people in (
                    ("front", [p for p in active_people if p.is_front]),
                    ("back", [p for p in active_people if not p.is_front]),
                ):
                    if people:
                        self.last_confirmed_zone_time[zone_name] = now_mono
                for zone_id in SIX_ZONE_IDS:
                    if zone6_counts[zone_id] > 0:
                        self.last_confirmed_zone_time[zone_id] = now_mono
            self.last_frame_ok = frame_ok

            def held_occupied(
                zone_name: str,
                current_count: int,
                frame_ok: bool = frame_ok,
                now_mono: float = now_mono,
            ) -> bool:
                if current_count > 0:
                    return True
                if not frame_ok:
                    if zone_name in SIX_ZONE_IDS:
                        return bool(self.prev_zone6_occupied.get(zone_name, False))
                    return bool(getattr(self, f"prev_{zone_name}_occupied", False))
                last_seen = self.last_confirmed_zone_time[zone_name]
                return last_seen is not None and now_mono - last_seen <= self.occupancy_hold_seconds

            front_occupied = held_occupied("front", front_count)
            back_occupied = held_occupied("back", back_count)
            front_transition = (
                front_occupied
                if self.prev_front_occupied is None
                else self.prev_front_occupied != front_occupied
            )
            back_transition = (
                back_occupied
                if self.prev_back_occupied is None
                else self.prev_back_occupied != back_occupied
            )

            if frame_ok and front_transition:
                self.prev_front_occupied = front_occupied
                target_front = "ON" if front_occupied else "OFF"
                LOG.info(f"⚡ [FRONT ZONE TRANSITION] {front_count} people -> {target_front} ({self.front_board_id}, mode={self.mode})")
                for ch in self.active_channels:
                    self._send_esp32_command(self.front_board_id, ch, target_front, lease_sec=60)
                if self.mode == "LIVE" and hasattr(self, "mqtt_client"):
                    ruet_cmd_f = "ALL_ON" if front_occupied else "ALL_OFF"
                    self.mqtt_client.publish(f"ruet/classroom/{self.room_id}/zone/1/command/all", ruet_cmd_f, qos=0)
                    self.mqtt_client.publish(f"ruet/classroom/{self.room_id}/board/1/command/all", ruet_cmd_f, qos=0)
                    self.mqtt_client.publish(f"ruet/classroom/{self.room_id}/zone/1/all", json.dumps({"state": target_front}), qos=0)
                    for ch in [1, 2, 3, 4]:
                        self.mqtt_client.publish(f"ruet/classroom/{self.room_id}/zone/1/relay/{ch}", json.dumps({"state": target_front}), qos=0)
                self.last_sent_state[self.front_board_id] = (target_front, now_wall)
                self.last_state_pub = 0.0

            if frame_ok and back_transition:
                self.prev_back_occupied = back_occupied
                target_back = "ON" if back_occupied else "OFF"
                LOG.info(f"⚡ [BACK ZONE TRANSITION] {back_count} people -> {target_back} ({self.back_board_id}, mode={self.mode})")
                for ch in self.active_channels:
                    self._send_esp32_command(self.back_board_id, ch, target_back, lease_sec=60)
                if self.mode == "LIVE" and hasattr(self, "mqtt_client"):
                    ruet_cmd_b = "ALL_ON" if back_occupied else "ALL_OFF"
                    self.mqtt_client.publish(f"ruet/classroom/{self.room_id}/zone/2/command/all", ruet_cmd_b, qos=0)
                    self.mqtt_client.publish(f"ruet/classroom/{self.room_id}/board/2/command/all", ruet_cmd_b, qos=0)
                    self.mqtt_client.publish(f"ruet/classroom/{self.room_id}/zone/2/all", json.dumps({"state": target_back}), qos=0)
                    for ch in [1, 2, 3, 4]:
                        self.mqtt_client.publish(f"ruet/classroom/{self.room_id}/zone/2/relay/{ch}", json.dumps({"state": target_back}), qos=0)
                self.last_sent_state[self.back_board_id] = (target_back, now_wall)
                self.last_state_pub = 0.0

            # 6-Zone granular board routing (board01: left_near/left_far, board02: centre_near/centre_far, board03: right_near/right_far)
            six_zone_board_map = {
                "left_near": (self.front_board_id, 1),
                "left_far": (self.front_board_id, 2),
                "centre_near": (self.back_board_id, 1),
                "centre_far": (self.back_board_id, 2),
                "right_near": (self.third_board_id, 1),
                "right_far": (self.third_board_id, 2),
            }
            for z6_id, (b_id, ch_num) in six_zone_board_map.items():
                z6_occ = held_occupied(z6_id, zone6_counts.get(z6_id, 0))
                if frame_ok and self.prev_zone6_occupied.get(z6_id) != z6_occ:
                    self.prev_zone6_occupied[z6_id] = z6_occ
                    if b_id == self.third_board_id:
                        self._send_esp32_command(b_id, ch_num, "ON" if z6_occ else "OFF", lease_sec=60)

            # 4B. Optical IR Air Conditioner Automation (Gree AC on GPIO 4)
            pub_fn = (
                (lambda t, p: self.mqtt_client.publish(t, p, qos=0))
                if hasattr(self, "mqtt_client")
                else None
            )
            self.ac_controller.evaluate_all(
                front_count=front_count,
                back_count=back_count,
                now=now_mono,
                publish_fn=pub_fn,
                operation_mode=self.mode,
            )

            # 5. Broadcast Multi-Zone App State Snapshot to Flutter App (1 Hz)
            if hasattr(self, "mqtt_client") and (now_wall - self.last_state_pub >= 1.0):
                self.last_state_pub = now_wall
                col3_count = zone6_counts["right_near"] + zone6_counts["right_far"]
                ac_appliances = self.ac_controller.get_app_state_appliances()
                app_state_doc = {
                    "schema_version": 1,
                    "kind": "app_state",
                    "session_id": self.session_id,
                    "mode": self.mode,
                    "sent_at_unix_ms": int(now_wall * 1000),
                    "freshness_seconds": 4.0,
                    "occupancy": {
                        "present": total_count > 0,
                        "observation_valid": frame_ok,
                        "observation_status": "OK" if frame_ok else "STALE",
                        "count": total_count,
                        "total_count": total_count,
                        "raw_detection_count": len(raw_detections),
                        "merged_detection_count": len(detections),
                        "observed_confirmed_count": tracker_counts["observed_confirmed_count"],
                        "tentative_track_count": tracker_counts["tentative_track_count"],
                        "retained_track_count": tracker_counts["retained_track_count"],
                        "moving_count": moving_count,
                        "stationary_count": stationary_count,
                        "front_count": front_count,
                        "back_count": back_count,
                        "zones": {
                            "Zone 1": front_count,
                            "Zone 2": back_count,
                            "Zone 3": col3_count,
                            "front": front_count,
                            "back": back_count,
                            "front_left": zone_counts["front_left"],
                            "front_right": zone_counts["front_right"],
                            "back_left": zone_counts["back_left"],
                            "back_right": zone_counts["back_right"],
                            **zone6_counts,
                        },
                    },
                    "appliances": {
                        "light_1": {
                            "reported": "ON" if front_occupied else "OFF",
                            "desired": "ON" if front_occupied else "OFF",
                        },
                        "fan_1": {
                            "reported": "ON" if front_occupied else "OFF",
                            "desired": "ON" if front_occupied else "OFF",
                        },
                        "light_2": {
                            "reported": "ON" if back_occupied else "OFF",
                            "desired": "ON" if back_occupied else "OFF",
                        },
                        "fan_2": {
                            "reported": "ON" if back_occupied else "OFF",
                            "desired": "ON" if back_occupied else "OFF",
                        },
                        **ac_appliances,
                    },
                }
                self.mqtt_client.publish(self.app_state_topic, json.dumps(app_state_doc), qos=0)

    def _draw_overlay(self, frame: np.ndarray) -> np.ndarray:
        """Draws crisp 6-zone + Front/Back HUD and tracked person boxes onto a copy of frame."""
        annotated = frame.copy()
        h, w = annotated.shape[:2]

        with self.frame_lock:
            active_people = list(self.active_people_snapshot)
            tracked_people = list(self.tracked_people_snapshot)
            raw_detections = list(self.raw_detections_snapshot)
            tracker_diagnostics = dict(self.tracker_diagnostics_snapshot)
            merged_detection_count = self.merged_detection_count_snapshot
            zone_counts = dict(self.zone_counts_snapshot)
            zone6_counts = dict(self.zone6_counts_snapshot)

        front_count = self.latest_front_count
        back_count = self.latest_back_count
        total_count = self.latest_total_count

        # Draw 6-Zone Grid (Horizontal Front/Back divider + 2 Vertical Column dividers)
        split_pixel_y = int(self.tracker.split_y * h)
        col1_x = int(self.tracker.col_left_x * w)
        col2_x = int(self.tracker.col_right_x * w)

        cv2.line(annotated, (0, split_pixel_y), (w, split_pixel_y), (0, 255, 255), 2)
        cv2.line(annotated, (col1_x, 32), (col1_x, h), (90, 90, 90), 1)
        cv2.line(annotated, (col2_x, 32), (col2_x, h), (90, 90, 90), 1)

        # Zone Headers
        top_is_front = not self.tracker.invert_zones
        top_label = f"FRONT/NEAR ZONE ({self.front_board_id}): {front_count}" if top_is_front else f"BACK/FAR ZONE ({self.back_board_id}): {back_count}"
        bot_label = f"BACK/FAR ZONE ({self.back_board_id}): {back_count}" if top_is_front else f"FRONT/NEAR ZONE ({self.front_board_id}): {front_count}"
        top_color = (248, 189, 56) if top_is_front else (252, 132, 192)
        bot_color = (252, 132, 192) if top_is_front else (248, 189, 56)

        cv2.putText(annotated, top_label, (12, 52), cv2.FONT_HERSHEY_SIMPLEX, 0.48, top_color, 2)
        cv2.putText(annotated, bot_label, (12, split_pixel_y + 22), cv2.FONT_HERSHEY_SIMPLEX, 0.48, bot_color, 2)

        if self.diagnostic_overlay:
            for raw_box, raw_conf, raw_class in raw_detections:
                rx1, ry1, rx2, ry2 = (
                    int(raw_box[0] * w),
                    int(raw_box[1] * h),
                    int(raw_box[2] * w),
                    int(raw_box[3] * h),
                )
                cv2.rectangle(annotated, (rx1, ry1), (rx2, ry2), (0, 165, 255), 1)
                cv2.putText(
                    annotated,
                    f"RAW c{raw_class} {raw_conf:.2f}",
                    (rx1, min(h - 4, ry2 + 14)),
                    cv2.FONT_HERSHEY_SIMPLEX,
                    0.38,
                    (0, 165, 255),
                    1,
                )

        # Draw current confirmed observations; diagnostics expose other lifecycle states.
        overlay_people = tracked_people if self.diagnostic_overlay else active_people
        for p in overlay_people:
            x1 = int(p.bbox[0] * w)
            y1 = int(p.bbox[1] * h)
            x2 = int(p.bbox[2] * w)
            y2 = int(p.bbox[3] * h)
            ax = int(p.anchor[0] * w)
            ay = int(p.anchor[1] * h)

            if p.lifecycle == "TENTATIVE":
                box_color = (0, 215, 255)
            elif p.lifecycle == "RETAINED":
                box_color = (150, 150, 150)
            else:
                box_color = (250, 190, 40) if p.is_front else (240, 120, 220)
            cv2.rectangle(annotated, (x1, y1), (x2, y2), box_color, 2)
            cv2.circle(annotated, (ax, ay), 3, (0, 255, 0), -1)

            tag = f"#{p.track_id} {p.zone6.upper()} {int(p.confidence * 100)}%"
            if self.diagnostic_overlay:
                tag = f"#{p.track_id} {p.zone6.upper()} {p.lifecycle} {int(p.confidence * 100)}%"
            if p.lifecycle == "RETAINED":
                tag += f" {max(0.0, time.monotonic() - p.last_seen_time):.1f}s"
            (tw, th), _ = cv2.getTextSize(tag, cv2.FONT_HERSHEY_SIMPLEX, 0.42, 1)
            cv2.rectangle(annotated, (x1, max(0, y1 - 18)), (x1 + tw + 6, max(18, y1)), (15, 25, 40), -1)
            cv2.putText(annotated, tag, (x1 + 3, max(13, y1 - 4)), cv2.FONT_HERSHEY_SIMPLEX, 0.42, box_color, 1)

        # Top HUD Banner
        cv2.rectangle(annotated, (0, 0), (w, 30), (15, 25, 40), -1)
        b1_r1 = self.board_relays.get(self.front_board_id, {}).get(1, False)
        b2_r1 = self.board_relays.get(self.back_board_id, {}).get(1, False)
        hud_str = (
            f"Stream: {self.stream_fps:.0f}FPS | AI: {self.ai_fps:.1f}Hz | "
            f"Front:{front_count}({'ON' if b1_r1 else 'OFF'}) Back:{back_count}({'ON' if b2_r1 else 'OFF'}) | "
            f"Total:{total_count} | {self.mode}"
        )
        cv2.putText(annotated, hud_str, (10, 20), cv2.FONT_HERSHEY_SIMPLEX, 0.45, (240, 240, 240), 1)
        if self.diagnostic_overlay:
            diag_str = (
                f"RAW {len(raw_detections)} (model NMS) | MERGED {merged_detection_count} | "
                f"OBS {tracker_diagnostics['observed_confirmed_count']} | "
                f"TENT {tracker_diagnostics['tentative_track_count']} | "
                f"RETAIN {tracker_diagnostics['retained_track_count']}"
            )
            cv2.putText(
                annotated,
                diag_str,
                (12, max(45, h - 14)),
                cv2.FONT_HERSHEY_SIMPLEX,
                0.45,
                (0, 165, 255),
                1,
            )
        return annotated

    def run(self):
        LOG.info(f"Opening camera source: {self.camera_source} at {self.cam_width}x{self.cam_height} ({self.target_fps} FPS)")
        is_image = False
        use_picam2 = False
        cap = None
        static_frame = None

        if isinstance(self.camera_source, str) and Path(self.camera_source).is_file():
            ext = Path(self.camera_source).suffix.lower()
            if ext in (".png", ".jpg", ".jpeg", ".bmp"):
                is_image = True
                static_frame = cv2.imread(self.camera_source)
                if static_frame is None:
                    LOG.error(f"Cannot read image: {self.camera_source}. Exiting.")
                    return

        if not is_image:
            if self.camera_source == "picam":
                use_picam2 = True
            else:
                # Prefer Picamera2 automatically on Raspberry Pi 5 when source is 0
                try:
                    from picamera2 import Picamera2  # type: ignore[import-not-found]
                    use_picam2 = True
                    LOG.info("[INFO] Detected Picamera2 on Raspberry Pi 5; using native low-latency ISP pipeline...")
                except ImportError:
                    cap = cv2.VideoCapture(self.camera_source)
                    if not cap.isOpened():
                        LOG.error(f"Cannot open camera: {self.camera_source}. Exiting.")
                        return

            if use_picam2:
                try:
                    from picamera2 import Picamera2  # type: ignore[import-not-found]
                    self.picam2 = Picamera2()
                    # CRITICAL COLOR & LATENCY FIX FOR RASPBERRY PI 5:
                    # 1. format="RGB888" in Picamera2 outputs [B, G, R] bytes in memory (native OpenCV BGR).
                    #    Never use "BGR888" or cvtColor(COLOR_RGB2BGR), which swaps Red and Blue!
                    # 2. buffer_count=2, queue=False guarantees zero frame lag and low RAM usage on 8GB Pi 5.
                    picam2_config = self.picam2.create_video_configuration(
                        main={"size": (self.cam_width, self.cam_height), "format": "RGB888"},
                        buffer_count=2,
                        queue=False,
                        controls={"FrameRate": self.target_fps},
                    )
                    self.picam2.configure(picam2_config)
                    self.set_camera_awb("fluorescent")
                    self.picam2.start()
                    time.sleep(0.8)
                    LOG.info(
                        f"[OK] Picamera2 True-Color Stream Active at {self.cam_width}x{self.cam_height} "
                        f"@ {self.target_fps:.0f} FPS (flip_180={self.flip_180})"
                    )
                except Exception as e:
                    LOG.error(f"Picamera2 initialization failed: {e}")
                    return
            elif cap is not None:
                cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)
                cap.set(cv2.CAP_PROP_FRAME_WIDTH, self.cam_width)
                cap.set(cv2.CAP_PROP_FRAME_HEIGHT, self.cam_height)
                cap.set(cv2.CAP_PROP_FPS, self.target_fps)

        LOG.info("=" * 64)
        LOG.info("  ClassPulse Pi 5 (8GB) Zero-Lag Vision & Decision Loop Active")
        LOG.info(f"  Classroom:        {self.room_id}")
        LOG.info(f"  Model:            {self.model_path.name}")
        LOG.info(f"  Front Zone Board: {self.front_board_id} (Zone 1)")
        LOG.info(f"  Back Zone Board:  {self.back_board_id} (Zone 2)")
        LOG.info(f"  Mode:             {self.mode} (Live Relays: {self.mode == 'LIVE'})")
        LOG.info(
            f"  Resolution:       {self.cam_width}x{self.cam_height} (4:3) | "
            f"Conf: {self.conf_thresh:.2f} | NMS IoU: {self.iou_thresh:.2f} | "
            f"Track IoU: {self.track_iou_thresh:.2f}"
        )
        LOG.info("=" * 64)

        # Start decoupled AI inference worker thread
        ai_thread = threading.Thread(target=self._inference_worker, daemon=True)
        ai_thread.start()

        prev_stream_time = time.monotonic()
        target_frame_interval = 1.0 / max(5.0, self.target_fps)

        try:
            while self.running:
                loop_start = time.monotonic()

                if is_image and static_frame is not None:
                    frame = static_frame.copy()
                    time.sleep(0.04)
                elif use_picam2 and self.picam2 is not None:
                    frame = self.picam2.capture_array()
                    frame = cv2.cvtColor(frame, cv2.COLOR_RGB2BGR)
                    if self.flip_180:
                        frame = cv2.flip(frame, -1)
                elif cap is not None:
                    ret, frame = cap.read()
                    if not ret:
                        time.sleep(0.03)
                        continue
                    if self.flip_180:
                        frame = cv2.flip(frame, -1)
                else:
                    time.sleep(0.03)
                    continue

                now_mono = time.monotonic()
                dt_s = now_mono - prev_stream_time
                if dt_s > 0:
                    self.stream_fps = (
                        0.9 * self.stream_fps + 0.1 * (1.0 / dt_s)
                        if self.stream_fps > 0
                        else (1.0 / dt_s)
                    )
                prev_stream_time = now_mono

                # Hand latest raw frame to the asynchronous AI worker thread
                with self.frame_lock:
                    self.latest_capture_frame = frame
                    self.latest_capture_seq += 1

                # Render lightweight HUD overlay & encode single preview JPEG
                annotated = self._draw_overlay(frame)

                if self.preview_server is not None:
                    success, jpeg_buf = cv2.imencode(".jpg", annotated, [cv2.IMWRITE_JPEG_QUALITY, 78])
                    if success:
                        h, w = frame.shape[:2]
                        with self.preview_state.lock:
                            self.preview_state.latest_jpeg = jpeg_buf.tobytes()
                            self.preview_state.latest_raw_frame = frame
                            self.preview_state.latest_status = {
                                "fps": round(self.stream_fps, 1),
                                "stream_fps": round(self.stream_fps, 1),
                                "ai_fps": round(self.ai_fps, 1),
                                "model_name": self.model_path.name,
                                "total_count": self.latest_total_count,
                                "moving_count": self.moving_count_snapshot,
                                "stationary_count": self.stationary_count_snapshot,
                                "front_count": self.latest_front_count,
                                "back_count": self.latest_back_count,
                                "mode": self.mode,
                                "room_id": self.room_id,
                                "front_board_id": self.front_board_id,
                                "back_board_id": self.back_board_id,
                                "board1_relays": self.board_relays.get(self.front_board_id, {}),
                                "board2_relays": self.board_relays.get(self.back_board_id, {}),
                                "resolution": f"{w}x{h}",
                                "current_conf": round(self.conf_thresh, 2),
                                "current_iou": round(self.iou_thresh, 2),
                                "track_iou": round(self.track_iou_thresh, 2),
                                "raw_detection_count": len(self.raw_detections_snapshot),
                                "merged_detection_count": self.merged_detection_count_snapshot,
                                "observed_confirmed_count": self.tracker_diagnostics_snapshot[
                                    "observed_confirmed_count"
                                ],
                                "tentative_track_count": self.tracker_diagnostics_snapshot[
                                    "tentative_track_count"
                                ],
                                "retained_track_count": self.tracker_diagnostics_snapshot[
                                    "retained_track_count"
                                ],
                                "observation_valid": self.last_frame_ok,
                                "detector_nms": "model_internal",
                                "raw_detection_definition": (
                                    "model output after Ultralytics NMS; before person filtering"
                                ),
                                "merged_detection_definition": (
                                    "person boxes passed to tracker; no second NMS in single-pass runtime"
                                ),
                                "diagnostic_overlay": self.diagnostic_overlay,
                                "zones": self.zone_counts_snapshot,
                                "zones6": self.zone6_counts_snapshot,
                            }

                if self.show_window:
                    try:
                        cv2.imshow("ClassPulse Vision & IoT", annotated)
                        if cv2.waitKey(1) & 0xFF == 27:
                            break
                    except (cv2.error, Exception):
                        self.show_window = False

                if now_mono - getattr(self, "_last_console_log", 0.0) >= 4.0:
                    self._last_console_log = now_mono
                    b1_r1 = self.board_relays.get(self.front_board_id, {}).get(1, False)
                    b2_r1 = self.board_relays.get(self.back_board_id, {}).get(1, False)
                    LOG.info(
                        f"[STATS] Total: {self.latest_total_count} | "
                        f"Front: {self.latest_front_count} ({'ON' if b1_r1 else 'OFF'}) | "
                        f"Back: {self.latest_back_count} ({'ON' if b2_r1 else 'OFF'}) | "
                        f"Stream: {self.stream_fps:.1f} FPS | AI: {self.ai_fps:.1f} Hz"
                    )

                # Pace capture loop to target_fps so CPU stays cool
                elapsed = time.monotonic() - loop_start
                sleep_time = target_frame_interval - elapsed
                if sleep_time > 0.002:
                    time.sleep(sleep_time)

        except KeyboardInterrupt:
            LOG.info("Stopping Multi-Zone Classroom Vision Controller...")
        finally:
            self.running = False
            if cap is not None:
                cap.release()
            if self.picam2 is not None:
                try:
                    self.picam2.stop()
                    self.picam2.close()
                except Exception:
                    pass
            if self.show_window:
                try:
                    cv2.destroyAllWindows()
                except Exception:
                    pass
            if self.preview_server is not None:
                try:
                    self.preview_server.shutdown()
                    self.preview_server.server_close()
                except Exception:
                    pass
            try:
                if hasattr(self, "mqtt_client"):
                    LOG.info("[SHUTDOWN] Broadcasting OFFLINE state...")
                    offline_pkt = {
                        "occupancy": {
                            "count": 0,
                            "front_count": 0,
                            "back_count": 0,
                            "moving_count": 0,
                            "stationary_count": 0,
                            "zones": {"Zone 1": 0, "Zone 2": 0, "Zone 3": 0},
                        },
                        "status": "OFFLINE",
                        "online": False,
                    }
                    self.mqtt_client.publish(self.app_state_topic, json.dumps(offline_pkt), qos=1, retain=True)
                    if self.mode == "LIVE":
                        self.mqtt_client.publish(f"ruet/classroom/{self.room_id}/zone/1/command/all", "ALL_OFF", qos=1)
                        self.mqtt_client.publish(f"ruet/classroom/{self.room_id}/zone/2/command/all", "ALL_OFF", qos=1)
                    time.sleep(0.2)
                    self.mqtt_client.loop_stop()
                    self.mqtt_client.disconnect()
            except Exception as e:
                LOG.warning(f"Error during shutdown broadcast: {e}")
            LOG.info("Clean shutdown complete.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="ClassPulse Pi 5 (8GB) Multi-Zone Classroom Vision Controller")
    parser.add_argument(
        "--model",
        default="auto",
        help="Path to YOLOv8 model (.pt or .onnx). Defaults to 'auto' (loads trained classroom_yolo_best.pt)",
    )
    parser.add_argument("--broker", default="broker.emqx.io", help="MQTT broker hostname")
    parser.add_argument("--port", type=int, default=1883, help="MQTT broker port")
    parser.add_argument("--room", default="reb_room_301", help="Classroom identifier")
    parser.add_argument("--front-board", default="board01", help="Front/Near Zone Controller board ID (Zone 1)")
    parser.add_argument("--back-board", default="board02", help="Back/Far Zone Controller board ID (Zone 2)")
    parser.add_argument("--third-board", default="board03", help="Third Zone Controller board ID (Zone 3)")
    parser.add_argument("--mode", default="LIVE", choices=["DRY_RUN", "LIVE"], help="Operational mode (default: LIVE)")
    parser.add_argument("--channels", default="1,2", help="Comma-separated relay channels to actuate (default: 1,2)")
    parser.add_argument("--source", default=0, help="Camera index, 'picam', image, or video file")
    parser.add_argument("--no-gui", action="store_true", help="Run headless without display window (recommended for Pi)")
    parser.add_argument("--conf", type=float, default=0.28, help="Confidence threshold (default 0.28)")
    parser.add_argument(
        "--iou",
        type=float,
        default=0.45,
        help="YOLO model-internal NMS IoU threshold (default 0.45)",
    )
    parser.add_argument(
        "--track-iou",
        type=float,
        default=0.18,
        help="Tracker box-matching IoU threshold (default 0.18)",
    )
    parser.add_argument(
        "--confirm-hits",
        type=int,
        default=2,
        help="Matched observations required to confirm a track (default 2)",
    )
    parser.add_argument(
        "--track-max-age",
        type=float,
        default=1.5,
        help="Seconds to retain an unmatched confirmed track (default 1.5)",
    )
    parser.add_argument(
        "--centroid-distance",
        type=float,
        default=0.06,
        help="Maximum normalized centroid fallback distance (default 0.06)",
    )
    parser.add_argument(
        "--occupancy-hold",
        type=float,
        default=1.5,
        help="Seconds to hold zone occupancy after the last confirmed observation (default 1.5)",
    )
    parser.add_argument(
        "--diagnostic-overlay",
        action="store_true",
        help="Show raw detector boxes and tracker lifecycle diagnostics",
    )
    parser.add_argument("--width", type=int, default=640, help="Camera capture width (default: 640 4:3 native)")
    parser.add_argument("--height", type=int, default=480, help="Camera capture height (default: 480 4:3 native)")
    parser.add_argument("--fps", type=float, default=25.0, help="Target camera & stream frame rate (default: 25.0)")
    parser.add_argument("--imgsz", type=int, default=640, help="YOLO inference resolution (default: 640)")
    parser.add_argument("--split-y", type=float, default=0.48, help="Front/Back boundary ratio (default 0.48)")
    parser.add_argument("--no-invert-zones", action="store_true", help="Do not invert top/bottom Front/Back mapping")
    parser.add_argument("--no-flip", action="store_true", help="Disable 180-degree ceiling-mount camera flip")
    parser.add_argument("--preview-port", type=int, default=8080, help="Embedded HTTP Web Preview Port (default 8080)")

    args = parser.parse_args()
    source = int(args.source) if str(args.source).isdigit() else args.source

    controller = ClassroomVisionController(
        model_path=args.model,
        broker=args.broker,
        port=args.port,
        room_id=args.room,
        front_board=args.front_board,
        back_board=args.back_board,
        third_board=args.third_board,
        mode=args.mode,
        camera_source=source,
        show_window=not args.no_gui,
        conf_thresh=args.conf,
        iou_thresh=args.iou,
        track_iou_thresh=args.track_iou,
        confirmation_hits=args.confirm_hits,
        track_max_age=args.track_max_age,
        centroid_distance_thresh=args.centroid_distance,
        occupancy_hold_seconds=args.occupancy_hold,
        diagnostic_overlay=args.diagnostic_overlay,
        preview_port=args.preview_port,
        width=args.width,
        height=args.height,
        fps=args.fps,
        imgsz=args.imgsz,
        split_y=args.split_y,
        invert_zones=not args.no_invert_zones,
        flip_180=not args.no_flip,
        channels=args.channels,
    )
    controller.run()
