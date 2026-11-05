"""ClassPulse Classroom Vision & Multi-Zone Decision Controller.

Runs real-time YOLOv8 inference + Motion Tracking on Raspberry Pi 5 (or PC),
partitions the classroom into Front Zone (Zone 1) and Back Zone (Zone 2),
commands TWO separate ESP32 switchboards (board01 & board02), provides an
embedded HTTP browser preview (http://<pi-ip>:8080) with live sensitivity and
zone tuning, and synchronizes live zone occupancy and appliance states with the
Flutter Mobile App.
"""

from __future__ import annotations

import argparse
import io
import json
import logging
import math
import sys
import threading
import time
import uuid
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Dict, List, Optional, Tuple
from urllib.parse import parse_qs, urlparse

import cv2
import numpy as np

# Ensure Vision_Model root is in python path
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

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


# ============================================================================
# Classroom Motion & Persistence Tracker
# ============================================================================
@dataclass
class TrackedPerson:
    track_id: int
    bbox: Tuple[float, float, float, float]  # (x1, y1, x2, y2) normalized [0, 1]
    centroid: Tuple[float, float]             # (cx, cy)
    confidence: float = 0.50
    velocity: Tuple[float, float] = (0.0, 0.0)
    speed: float = 0.0
    state: str = "STATIONARY"                 # "MOVING" or "STATIONARY"
    zone: str = "front_left"                  # Quadrant
    is_front: bool = True                     # True = Front Zone, False = Back Zone
    last_seen_time: float = 0.0
    frames_tracked: int = 1
    missed_frames: int = 0


class FastMotionFilter:
    """Pre-filter detecting pixel-level motion across consecutive frames."""

    def __init__(self, threshold: int = 20, min_motion_pixels: int = 120):
        self.threshold = threshold
        self.min_motion_pixels = min_motion_pixels
        self.last_gray: Optional[np.ndarray] = None

    def check_motion(self, rgb_frame: np.ndarray) -> Tuple[bool, float, Optional[np.ndarray]]:
        if rgb_frame.ndim == 3 and rgb_frame.shape[2] == 3:
            gray = (
                rgb_frame[:, :, 0].astype(np.uint16) * 77
                + rgb_frame[:, :, 1].astype(np.uint16) * 150
                + rgb_frame[:, :, 2].astype(np.uint16) * 29
            ) >> 8
            gray = gray.astype(np.uint8)
        else:
            gray = rgb_frame

        h, w = gray.shape[:2]
        small_gray = gray[::4, ::4]

        if self.last_gray is None or self.last_gray.shape != small_gray.shape:
            self.last_gray = small_gray
            return True, 1.0, None

        diff = np.abs(small_gray.astype(np.int16) - self.last_gray.astype(np.int16))
        motion_mask = (diff > self.threshold).astype(np.uint8)
        changed_pixels = int(np.sum(motion_mask))
        ratio = changed_pixels / small_gray.size

        self.last_gray = small_gray
        has_motion = changed_pixels >= (self.min_motion_pixels // 16)
        return has_motion, ratio, motion_mask


class ClassroomMotionTracker:
    """
    Robust classroom-tuned person tracker with IoU + Centroid proximity fallback.
    Prevents track loss for seated/stationary students behind desks.
    """

    def __init__(
        self,
        iou_threshold: float = 0.18,
        centroid_distance_thresh: float = 0.12,
        max_missed_frames: int = 14,
        motion_speed_threshold: float = 0.035,
        smoothing_factor: float = 0.6,
        split_y: float = 0.50,
        invert_zones: bool = False,
    ):
        self.iou_threshold = iou_threshold
        self.dist_thresh = centroid_distance_thresh
        self.max_missed_frames = max_missed_frames
        self.motion_speed_threshold = motion_speed_threshold
        self.smoothing = smoothing_factor
        self.split_y = split_y
        self.invert_zones = invert_zones

        self.tracks: Dict[int, TrackedPerson] = {}
        self.next_track_id: int = 1
        self.last_update_time: Optional[float] = None

    @staticmethod
    def _compute_iou(box_a: Tuple[float, float, float, float], box_b: Tuple[float, float, float, float]) -> float:
        xa1, ya1, xa2, ya2 = box_a
        xb1, yb1, xb2, yb2 = box_b
        inter_x1 = max(xa1, xb1)
        inter_y1 = max(ya1, yb1)
        inter_x2 = min(xa2, xb2)
        inter_y2 = min(ya2, yb2)
        if inter_x2 <= inter_x1 or inter_y2 <= inter_y1:
            return 0.0
        inter_area = (inter_x2 - inter_x1) * (inter_y2 - inter_y1)
        area_a = (xa2 - xa1) * (ya2 - ya1)
        area_b = (xb2 - xb1) * (ya2 - ya1)
        union = area_a + area_b - inter_area
        return inter_area / union if union > 0 else 0.0

    @staticmethod
    def _centroid(box: Tuple[float, float, float, float]) -> Tuple[float, float]:
        return ((box[0] + box[2]) / 2.0, (box[1] + box[3]) / 2.0)

    def classify_zone(self, centroid: Tuple[float, float]) -> Tuple[str, bool]:
        """Returns (quadrant_str, is_front_zone)."""
        cx, cy = centroid
        is_front_raw = cy < self.split_y
        is_front = (not is_front_raw) if self.invert_zones else is_front_raw
        is_left = cx < 0.5

        if is_front and is_left:
            quadrant = "front_left"
        elif is_front and not is_left:
            quadrant = "front_right"
        elif not is_front and is_left:
            quadrant = "back_left"
        else:
            quadrant = "back_right"

        return quadrant, is_front

    def update(
        self,
        detections: List[Tuple[Tuple[float, float, float, float], float]],
        now: Optional[float] = None,
    ) -> List[TrackedPerson]:
        now = time.monotonic() if now is None else float(now)
        dt = (now - self.last_update_time) if self.last_update_time is not None else 0.1
        dt = max(0.01, min(dt, 2.0))
        self.last_update_time = now

        unmatched_dets = set(range(len(detections)))
        unmatched_tracks = set(self.tracks.keys())
        matched_pairs: List[Tuple[int, int]] = []

        # Pass 1: Greedy IoU matching
        if self.tracks and detections:
            track_ids = list(self.tracks.keys())
            iou_matrix = np.zeros((len(track_ids), len(detections)), dtype=np.float32)
            for i, tid in enumerate(track_ids):
                for j, (det_box, _) in enumerate(detections):
                    iou_matrix[i, j] = self._compute_iou(self.tracks[tid].bbox, det_box)

            while True:
                max_iou = np.max(iou_matrix) if iou_matrix.size > 0 else 0.0
                if max_iou < self.iou_threshold:
                    break
                row, col = np.unravel_index(np.argmax(iou_matrix), iou_matrix.shape)
                tid = track_ids[row]
                matched_pairs.append((tid, col))
                unmatched_tracks.discard(tid)
                unmatched_dets.discard(col)
                iou_matrix[row, :] = -1.0
                iou_matrix[:, col] = -1.0

        # Pass 2: Centroid proximity matching for occluded/seated students whose box shifted
        if unmatched_tracks and unmatched_dets:
            for tid in list(unmatched_tracks):
                old_c = self.tracks[tid].centroid
                best_det = None
                min_dist = self.dist_thresh
                for det_idx in list(unmatched_dets):
                    det_box, _ = detections[det_idx]
                    c = self._centroid(det_box)
                    dist = math.hypot(c[0] - old_c[0], c[1] - old_c[1])
                    if dist < min_dist:
                        min_dist = dist
                        best_det = det_idx
                if best_det is not None:
                    matched_pairs.append((tid, best_det))
                    unmatched_tracks.discard(tid)
                    unmatched_dets.discard(best_det)

        # Update matched tracks
        for tid, det_idx in matched_pairs:
            det_box, conf = detections[det_idx]
            new_c = self._centroid(det_box)
            old_c = self.tracks[tid].centroid

            raw_vx = (new_c[0] - old_c[0]) / dt
            raw_vy = (new_c[1] - old_c[1]) / dt

            old_vx, old_vy = self.tracks[tid].velocity
            vx = self.smoothing * old_vx + (1.0 - self.smoothing) * raw_vx
            vy = self.smoothing * old_vy + (1.0 - self.smoothing) * raw_vy
            speed = math.hypot(vx, vy)

            state = "MOVING" if speed > self.motion_speed_threshold else "STATIONARY"
            quadrant, is_front = self.classify_zone(new_c)

            self.tracks[tid].bbox = det_box
            self.tracks[tid].centroid = new_c
            self.tracks[tid].confidence = conf
            self.tracks[tid].velocity = (vx, vy)
            self.tracks[tid].speed = speed
            self.tracks[tid].state = state
            self.tracks[tid].zone = quadrant
            self.tracks[tid].is_front = is_front
            self.tracks[tid].last_seen_time = now
            self.tracks[tid].frames_tracked += 1
            self.tracks[tid].missed_frames = 0

        # Age unmatched tracks
        for tid in list(unmatched_tracks):
            self.tracks[tid].missed_frames += 1
            if self.tracks[tid].missed_frames > self.max_missed_frames:
                del self.tracks[tid]

        # Register new tracks
        for det_idx in unmatched_dets:
            det_box, conf = detections[det_idx]
            c = self._centroid(det_box)
            quadrant, is_front = self.classify_zone(c)
            new_person = TrackedPerson(
                track_id=self.next_track_id,
                bbox=det_box,
                centroid=c,
                confidence=conf,
                velocity=(0.0, 0.0),
                speed=0.0,
                state="STATIONARY",
                zone=quadrant,
                is_front=is_front,
                last_seen_time=now,
                frames_tracked=1,
                missed_frames=0,
            )
            self.tracks[self.next_track_id] = new_person
            self.next_track_id += 1

        return list(self.tracks.values())


# ============================================================================
# Embedded Web Dashboard HTML (With Multi-Zone Support & Downloads)
# ============================================================================
PREVIEW_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>ClassPulse Multi-Zone AI Vision Hub</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    background: #0b0f19;
    color: #e2e8f0;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    padding: 16px;
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
    padding: 14px 20px;
    background: #151e32;
    border-radius: 12px;
    margin-bottom: 14px;
    border: 1px solid #1e293b;
    box-shadow: 0 4px 20px rgba(0,0,0,0.3);
  }
  .title {
    font-size: 1.25rem;
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

  /* Controls Banner */
  .control-card {
    width: 100%;
    max-width: 1060px;
    background: #151e32;
    border-radius: 12px;
    padding: 14px 20px;
    margin-bottom: 12px;
    border: 1px solid #1e293b;
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    justify-content: space-between;
    gap: 14px;
  }
  .slider-group {
    display: flex;
    align-items: center;
    gap: 12px;
    flex: 1;
    min-width: 280px;
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
    padding: 6px 12px;
    border-radius: 6px;
    cursor: pointer;
    font-weight: 600;
    transition: all 0.15s ease;
  }
  .btn-preset:hover { background: #0284c7; color: #fff; border-color: #38bdf8; }

  /* Action Buttons for Download */
  .action-card {
    width: 100%;
    max-width: 1060px;
    background: #151e32;
    border-radius: 12px;
    padding: 12px 18px;
    margin-bottom: 14px;
    border: 1px solid #1e293b;
    display: flex;
    justify-content: space-between;
    align-items: center;
    flex-wrap: wrap;
    gap: 12px;
  }
  .action-left {
    display: flex;
    flex-wrap: wrap;
    gap: 10px;
  }
  .btn-action {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    padding: 8px 16px;
    border-radius: 8px;
    font-size: 0.85rem;
    font-weight: 600;
    text-decoration: none;
    transition: all 0.2s ease;
    cursor: pointer;
  }
  .btn-annotated {
    background: #0284c7;
    color: #ffffff;
    border: 1px solid #38bdf8;
    box-shadow: 0 2px 10px rgba(2, 132, 199, 0.3);
  }
  .btn-annotated:hover {
    background: #0369a1;
    transform: translateY(-1px);
  }
  .btn-raw {
    background: #1e293b;
    color: #cbd5e1;
    border: 1px solid #475569;
  }
  .btn-raw:hover {
    background: #334155;
    color: #ffffff;
    border-color: #64748b;
    transform: translateY(-1px);
  }
  .action-hint {
    font-size: 0.78rem;
    color: #94a3b8;
  }

  /* Zone Stats Grid */
  .stats-grid {
    width: 100%;
    max-width: 1060px;
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
    gap: 12px;
    margin-bottom: 14px;
  }
  .stat-card {
    background: #151e32;
    padding: 12px 16px;
    border-radius: 12px;
    border: 1px solid #1e293b;
    display: flex;
    flex-direction: column;
  }
  .stat-card-front {
    border-left: 4px solid #38bdf8;
  }
  .stat-card-back {
    border-left: 4px solid #c084fc;
  }
  .stat-label { font-size: 0.72rem; color: #94a3b8; text-transform: uppercase; letter-spacing: 0.05em; font-weight: 600; }
  .stat-value { font-size: 1.55rem; font-weight: 700; color: #f8fafc; margin-top: 4px; }
  .stat-sub { font-size: 0.8rem; font-weight: 500; color: #94a3b8; margin-top: 2px; }
  .stat-accent-green { color: #4ade80; }
  .stat-accent-amber { color: #fbbf24; }
  .stat-accent-blue { color: #38bdf8; }
  .stat-accent-purple { color: #c084fc; }

  .video-container {
    width: 100%;
    max-width: 1060px;
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
    max-height: 75vh;
    object-fit: contain;
  }
  .footer-note {
    margin-top: 14px;
    font-size: 0.8rem;
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
      ClassPulse Dual-Zone Vision Hub
    </div>
    <div class="badges">
      <span class="badge badge-res" id="res_tag">1280x720 HD</span>
      <span class="badge badge-room" id="room_tag">reb_room_301</span>
      <span class="badge badge-mode" id="mode_tag">DRY_RUN</span>
    </div>
  </div>

  <div class="control-card">
    <div class="slider-group">
      <span class="slider-label">Sensitivity:</span>
      <input type="range" id="conf_slider" min="0.10" max="0.60" step="0.02" value="0.25" oninput="onConfChange(this.value)">
      <span class="slider-val" id="conf_val">0.25</span>
    </div>
    <div class="btn-grp">
      <button class="btn-preset" onclick="setPreset(0.18)">High Recall</button>
      <button class="btn-preset" onclick="setPreset(0.25)">Balanced</button>
      <button class="btn-preset" onclick="toggleInvert()">🔄 Swap Front / Back</button>
      <button class="btn-preset" id="btn_mode" onclick="toggleLiveMode()" style="background:#dc2626; color:#fff; font-weight:700;">⚡ LIVE RELAYS</button>
    </div>
  </div>

  <div class="action-card">
    <div class="action-left">
      <a href="/download/annotated" class="btn-action btn-annotated" download>
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M23 19a2 2 0 0 1-2 2H3a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4l2-3h6l2 3h4a2 2 0 0 1 2 2z"></path><circle cx="12" cy="13" r="4"></circle></svg>
        Download Snapshot (With AI Zones)
      </a>
      <a href="/download/raw" class="btn-action btn-raw" download>
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"></path><polyline points="7 10 12 15 17 10"></polyline><line x1="12" y1="15" x2="12" y2="3"></line></svg>
        Download Clean Frame (Raw Camera)
      </a>
    </div>
    <div class="action-right">
      <span class="action-hint">Dual-ESP32 Automation Active (board01 &amp; board02)</span>
    </div>
  </div>

  <div class="stats-grid">
    <div class="stat-card stat-card-front">
      <span class="stat-label">Front Zone (ESP32-1)</span>
      <span class="stat-value stat-accent-blue" id="val_front">0</span>
      <span class="stat-sub" id="sub_front">Relay: OFF (board01)</span>
    </div>
    <div class="stat-card stat-card-back">
      <span class="stat-label">Back Zone (ESP32-2)</span>
      <span class="stat-value stat-accent-purple" id="val_back">0</span>
      <span class="stat-sub" id="sub_back">Relay: OFF (board02)</span>
    </div>
    <div class="stat-card">
      <span class="stat-label">Total Occupancy</span>
      <span class="stat-value" id="val_total">0</span>
      <span class="stat-sub" id="sub_motion">0 Moving · 0 Seated</span>
    </div>
    <div class="stat-card">
      <span class="stat-label">Inference Speed</span>
      <span class="stat-value" id="val_fps">-- FPS</span>
      <span class="stat-sub" id="sub_status">Dual Boards Synced</span>
    </div>
  </div>

  <div class="video-container">
    <img id="mjpeg_stream" src="/stream.mjpg" alt="Classroom Live Vision Stream" onerror="setTimeout(() => { this.src='/stream.mjpg?t='+Date.now(); }, 1500)">
  </div>

  <div class="footer-note">
    Connected to Raspberry Pi 5 CSI Camera &bull; Protocol: classroom-control-v1 &bull; MQTT: broker.emqx.io<br>
    Front Zone drives <b>ESP32 #1 (board01)</b> &bull; Back Zone drives <b>ESP32 #2 (board02)</b>
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

          document.getElementById('val_fps').textContent = (d.fps ? d.fps.toFixed(1) : '--') + ' FPS';
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
        self.latest_raw_jpeg: Optional[bytes] = None
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
                frame_bytes = state.latest_raw_jpeg if is_raw else state.latest_jpeg
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

        elif self.path == "/stream.mjpg":
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
                    time.sleep(0.035)
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

    def log_message(self, *args):
        pass


class ThreadedPreviewServer(ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, server_address, RequestHandlerClass, preview_state: PreviewState, controller=None):
        super().__init__(server_address, RequestHandlerClass)
        self.preview_state = preview_state
        self.controller = controller


# ============================================================================
# Main Multi-Zone Controller
# ============================================================================
class ClassroomVisionController:
    def __init__(
        self,
        model_path: str = "yolov8n.pt",
        broker: str = "broker.emqx.io",
        port: int = 1883,
        room_id: str = "reb_room_301",
        front_board: str = "board01",
        back_board: str = "board02",
        mode: str = "DRY_RUN",
        camera_source: int | str = 0,
        show_window: bool = False,
        conf_thresh: float = 0.25,
        preview_port: int = 8080,
        width: int = 1280,
        height: int = 720,
        imgsz: int = 640,
        split_y: float = 0.50,
        invert_zones: bool = False,
        channels: str = "1,2",
    ):
        self.broker = broker
        self.port = port
        self.room_id = room_id
        self.front_board_id = front_board
        self.back_board_id = back_board
        self.mode = mode.upper()
        self.channels_str = channels
        self.active_channels = [int(x.strip()) for x in str(channels).split(",") if x.strip().isdigit()] or [1, 2]
        self.camera_source = camera_source
        self.show_window = show_window
        self.conf_thresh = conf_thresh
        self.preview_port = preview_port
        self.cam_width = width
        self.cam_height = height
        self.imgsz = imgsz

        self.session_id = f"sess_{uuid.uuid4().hex[:8]}"
        self.command_seq = 1
        self.last_state_pub = 0.0
        self.last_decision_time = 0.0
        self.latest_front_count = 0
        self.latest_back_count = 0
        self.latest_total_count = 0
        self.prev_front_occupied = None
        self.prev_back_occupied = None

        # State tracking across BOTH boards
        self.active_overrides: Dict[str, Dict] = {}
        self.board_relays: Dict[str, Dict[int, bool]] = {
            self.front_board_id: {1: False, 2: False, 3: False, 4: False},
            self.back_board_id: {1: False, 2: False, 3: False, 4: False},
        }
        # Last command sent per board: board_id -> (target_state, timestamp)
        self.last_sent_state: Dict[str, Tuple[str, float]] = {}

        # Multi-Zone Motion Tracker
        self.motion_filter = FastMotionFilter(threshold=20, min_motion_pixels=120)
        self.tracker = ClassroomMotionTracker(
            iou_threshold=0.18,
            centroid_distance_thresh=0.12,
            max_missed_frames=14,
            motion_speed_threshold=0.035,
            smoothing_factor=0.6,
            split_y=split_y,
            invert_zones=invert_zones,
        )

        # Web Preview State & Server
        self.preview_state = PreviewState()
        self.preview_server: Optional[ThreadedPreviewServer] = None
        if self.preview_port > 0:
            self._start_preview_server()

        # Resolve Model Path
        self.model_path = self._resolve_model(model_path)
        LOG.info(f"Loading Classroom Vision Model: {self.model_path}")
        from ultralytics import YOLO
        self.model = YOLO(str(self.model_path))

        # Setup MQTT
        self.setup_mqtt()

    def _resolve_model(self, candidate: str) -> Path:
        paths_to_check = [
            Path(candidate),
            ROOT / candidate,
            ROOT / "yolov8n.pt",
            ROOT / "yolov8n.onnx",
            ROOT / "runs/train/classroom_person_detector/weights/best.onnx",
            ROOT / "runs/train/classroom_person_detector/weights/best.pt",
        ]
        for p in paths_to_check:
            if p.exists() and p.is_file():
                return p.resolve()
        return Path(candidate)

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
            LOG.info(f"  [OK] ClassPulse Dual-Zone Web Preview Active!")
            LOG.info(f"  -> On Raspberry Pi:  http://localhost:{self.preview_port}")
            LOG.info(f"  -> From PC / Phone:  http://pizero.local:{self.preview_port}")
            LOG.info(f"  -> Front Zone (ESP32-1): {self.front_board_id}")
            LOG.info(f"  -> Back Zone (ESP32-2):  {self.back_board_id}")
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
                "zones": {"Zone 1": 0, "Zone 2": 0}
            },
            "status": "OFFLINE",
            "online": False
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
            # Wildcard subscription to status and acks of ALL controllers in the classroom
            client.subscribe(f"classpulse/{self.room_id}/controllers/+/status", qos=0)
            client.subscribe(f"classpulse/{self.room_id}/controllers/+/ack", qos=0)
            client.subscribe(self.app_req_topic, qos=1)
            client.subscribe(f"ruet/classroom/{self.room_id}/#", qos=0)
            LOG.info(f"Subscribed to Dual-Zone ESP32s ({self.front_board_id}, {self.back_board_id}) & App for: {self.room_id}")

            # Send Phase 5 hello handshakes to both ESP32 controllers
            for bid in [self.front_board_id, self.back_board_id]:
                hello_pkt = {
                    "protocol": "classroom-control-v1",
                    "kind": "hello",
                    "session_id": self.session_id,
                    "challenge": "authorized",
                }
                client.publish(f"classpulse/{self.room_id}/controllers/{bid}/hello", json.dumps(hello_pkt), qos=1)
                client.publish(f"ruet/classroom/{self.room_id}/controllers/{bid}/hello", json.dumps(hello_pkt), qos=1)
        else:
            LOG.warning(f"MQTT Connect failed with code {rc}")

    def _on_message(self, client, userdata, msg):
        topic = msg.topic
        payload_str = msg.payload.decode("utf-8", errors="ignore")

        # 1. Outbound ESP32 Status Messages (Ignore so they never trigger overrides)
        if "/status" in topic or topic.endswith("/status"):
            try:
                data = json.loads(payload_str)
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

        # 2. ESP32 ACK
        elif "/ack" in topic:
            try:
                data = json.loads(payload_str)
                LOG.info(f"[ESP32 ACK] {data.get('controller_id')} seq={data.get('command_sequence')} res={data.get('result')}")
            except Exception:
                pass

        # 3. Direct ESP32 Relay Command Intercept (ruet/classroom/...)
        elif topic.startswith(f"ruet/classroom/{self.room_id}/"):
            try:
                data = json.loads(payload_str) if payload_str.startswith("{") else {"state": payload_str}
                req_state = str(data.get("state", payload_str)).upper()
                is_back = ("/zone/2" in topic) or ("/zone/back" in topic) or ("/board/2" in topic)
                target_board = self.back_board_id if is_back else self.front_board_id
                zone_count = self.latest_back_count if is_back else self.latest_front_count
                zone_label = "Back Zone (Zone 2)" if is_back else "Front Zone (Zone 1)"

                if (req_state == "ON" or req_state == "ALL_ON") and zone_count <= 0:
                    LOG.warning(f"[VISION GATE INTERCEPT] Direct MQTT ON on '{topic}' BLOCKED: {zone_label} is EMPTY (0 occupants)!")
                    self.mqtt_client.publish(topic, json.dumps({"state": "OFF"}), qos=0)
                    for ch in self.active_channels:
                        self._send_esp32_command(board_id=target_board, channel=ch, desired_state="OFF", lease_sec=60)
            except Exception:
                pass

        # 4. Flutter App Ingress Request (Manual Overrides)
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
                zone_count = self.latest_back_count if is_back else self.latest_front_count
                zone_label = "Back Zone (Zone 2)" if is_back else "Front Zone (Zone 1)"

                if desired == "ON":
                    # STRICT VISION GATE CHECK: Is anyone sitting or moving in this zone?
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

                # Send Result back to App
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

    def run(self):
        LOG.info(f"Opening camera source: {self.camera_source} at resolution {self.cam_width}x{self.cam_height}")
        is_image = False
        use_picam2 = False
        cap = None
        picam2 = None
        static_frame = None

        if isinstance(self.camera_source, str) and Path(self.camera_source).is_file():
            ext = Path(self.camera_source).suffix.lower()
            if ext in (".png", ".jpg", ".jpeg", ".bmp"):
                is_image = True
                static_frame = cv2.imread(str(self.camera_source))
                if static_frame is None:
                    LOG.error(f"Cannot read image: {self.camera_source}. Exiting.")
                    return

        if not is_image:
            if self.camera_source == "picam":
                use_picam2 = True
            else:
                cap = cv2.VideoCapture(self.camera_source)
                if not cap.isOpened():
                    try:
                        from picamera2 import Picamera2
                        use_picam2 = True
                        LOG.info("[INFO] V4L2 camera unavailable; switching to native Picamera2 (Ribbon Camera)...")
                    except ImportError:
                        LOG.error(f"Cannot open camera: {self.camera_source}. Exiting.")
                        return

            if use_picam2:
                try:
                    from picamera2 import Picamera2
                    picam2 = Picamera2()
                    picam2_config = picam2.create_video_configuration(
                        main={"size": (self.cam_width, self.cam_height), "format": "BGR888"}
                    )
                    picam2.configure(picam2_config)
                    picam2.start()
                    LOG.info(f"[OK] Native Pi Ribbon Camera (Picamera2) initialized at {self.cam_width}x{self.cam_height} HD")
                except Exception as e:
                    LOG.error(f"Failed to initialize Picamera2 at {self.cam_width}x{self.cam_height}: {e}")
                    try:
                        picam2 = Picamera2()
                        picam2_config = picam2.create_video_configuration(main={"size": (640, 480), "format": "BGR888"})
                        picam2.configure(picam2_config)
                        picam2.start()
                        self.cam_width, self.cam_height = 640, 480
                    except Exception as e2:
                        LOG.error(f"Picamera2 initialization failed: {e2}")
                        return
            else:
                cap.set(cv2.CAP_PROP_FRAME_WIDTH, self.cam_width)
                cap.set(cv2.CAP_PROP_FRAME_HEIGHT, self.cam_height)

        LOG.info("=" * 60)
        LOG.info("  ClassPulse Dual-Zone Vision & Decision Loop Active")
        LOG.info(f"  Classroom:       {self.room_id}")
        LOG.info(f"  Front Zone Board: {self.front_board_id} (Zone 1)")
        LOG.info(f"  Back Zone Board:  {self.back_board_id} (Zone 2)")
        LOG.info(f"  Mode:            {self.mode} (Live Relays: {self.mode == 'LIVE'})")
        LOG.info(f"  Resolution:      {self.cam_width}x{self.cam_height} | Conf: {self.conf_thresh:.2f}")
        LOG.info("=" * 60)

        prev_time = time.time()
        fps = 0.0

        try:
            while True:
                if is_image:
                    frame = static_frame.copy()
                    time.sleep(0.08)
                elif use_picam2:
                    frame = picam2.capture_array()
                else:
                    ret, frame = cap.read()
                    if not ret:
                        time.sleep(0.05)
                        continue

                now = time.time()
                dt = now - prev_time
                if dt > 0:
                    fps = 0.9 * fps + 0.1 * (1.0 / dt) if fps > 0 else 1.0 / dt
                prev_time = now

                # 1. Fast Motion Differencing Pre-check
                has_motion, motion_ratio, _ = self.motion_filter.check_motion(frame)

                # 2. YOLO Neural Detection
                cur_conf = self.conf_thresh
                try:
                    results = self.model.predict(
                        source=frame,
                        conf=cur_conf,
                        classes=[0],
                        imgsz=self.imgsz,
                        verbose=False,
                    )
                except Exception:
                    results = self.model.predict(
                        source=frame,
                        conf=cur_conf,
                        imgsz=self.imgsz,
                        verbose=False,
                    )

                h, w = frame.shape[:2]
                detections: List[Tuple[Tuple[float, float, float, float], float]] = []
                for box in results[0].boxes:
                    cls_id = int(box.cls[0].item())
                    if cls_id == 0:
                        conf = float(box.conf[0].item())
                        xyxy = box.xyxy[0].tolist()
                        norm_box = (
                            max(0.0, xyxy[0] / w),
                            max(0.0, xyxy[1] / h),
                            min(1.0, xyxy[2] / w),
                            min(1.0, xyxy[3] / h),
                        )
                        detections.append((norm_box, conf))

                # 3. Multi-Zone Motion & Velocity Tracking
                tracked = self.tracker.update(detections, now)
                active_people = [p for p in tracked if p.missed_frames <= 4]

                total_count = len(active_people)
                moving_count = sum(1 for p in active_people if p.state == "MOVING")
                stationary_count = total_count - moving_count

                # Zone breakdown
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
                for p in active_people:
                    if p.zone in zone_counts:
                        zone_counts[p.zone] += 1

                # 4. Multi-Zone Automated Decision Logic (Edge-Triggered Transitions)
                front_occupied = (front_count > 0)
                back_occupied = (back_count > 0)

                # --- A. FRONT ZONE (board01 / Zone 1) ---
                if self.prev_front_occupied != front_occupied:
                    self.prev_front_occupied = front_occupied
                    target_front = "ON" if front_occupied else "OFF"
                    LOG.info(f"⚡ [FRONT ZONE TRANSITION] {front_count} people detected -> Sending {target_front} to {self.front_board_id}")
                    for ch in self.active_channels:
                        self._send_esp32_command(self.front_board_id, ch, target_front, lease_sec=60)
                    ruet_cmd_f = "ALL_ON" if front_occupied else "ALL_OFF"
                    self.mqtt_client.publish(f"ruet/classroom/{self.room_id}/zone/1/command/all", ruet_cmd_f, qos=0)
                    self.mqtt_client.publish(f"ruet/classroom/{self.room_id}/board/1/command/all", ruet_cmd_f, qos=0)
                    self.mqtt_client.publish(f"ruet/classroom/{self.room_id}/zone/1/all", json.dumps({"state": target_front}), qos=0)
                    for ch in [1, 2, 3, 4]:
                        self.mqtt_client.publish(f"ruet/classroom/{self.room_id}/zone/1/relay/{ch}", json.dumps({"state": target_front}), qos=0)
                    self.last_sent_state[self.front_board_id] = (target_front, now)
                    self.last_state_pub = 0.0 # Instant Flutter telemetry push!

                # --- B. BACK ZONE (board02 / Zone 2) ---
                if self.prev_back_occupied != back_occupied:
                    self.prev_back_occupied = back_occupied
                    target_back = "ON" if back_occupied else "OFF"
                    LOG.info(f"⚡ [BACK ZONE TRANSITION] {back_count} people detected -> Sending {target_back} to {self.back_board_id}")
                    for ch in self.active_channels:
                        self._send_esp32_command(self.back_board_id, ch, target_back, lease_sec=60)
                    ruet_cmd_b = "ALL_ON" if back_occupied else "ALL_OFF"
                    self.mqtt_client.publish(f"ruet/classroom/{self.room_id}/zone/2/command/all", ruet_cmd_b, qos=0)
                    self.mqtt_client.publish(f"ruet/classroom/{self.room_id}/board/2/command/all", ruet_cmd_b, qos=0)
                    self.mqtt_client.publish(f"ruet/classroom/{self.room_id}/zone/2/all", json.dumps({"state": target_back}), qos=0)
                    for ch in [1, 2, 3, 4]:
                        self.mqtt_client.publish(f"ruet/classroom/{self.room_id}/zone/2/relay/{ch}", json.dumps({"state": target_back}), qos=0)
                    self.last_sent_state[self.back_board_id] = (target_back, now)
                    self.last_state_pub = 0.0 # Instant Flutter telemetry push!

                # 5. Broadcast Multi-Zone App State Snapshot to Flutter App (1 Hz)
                if now - self.last_state_pub >= 1.0:
                    self.last_state_pub = now
                    b1_relays = self.board_relays.get(self.front_board_id, {})
                    b2_relays = self.board_relays.get(self.back_board_id, {})

                    app_state_doc = {
                        "schema_version": 1,
                        "kind": "app_state",
                        "session_id": self.session_id,
                        "mode": self.mode,
                        "sent_at_unix_ms": int(now * 1000),
                        "freshness_seconds": 4.0,
                        "occupancy": {
                            "present": total_count > 0,
                            "count": total_count,
                            "total_count": total_count,
                            "moving_count": moving_count,
                            "stationary_count": stationary_count,
                            "front_count": front_count,
                            "back_count": back_count,
                            "zones": {
                                "Zone 1": front_count,
                                "Zone 2": back_count,
                                "front": front_count,
                                "back": back_count,
                                "front_left": zone_counts["front_left"],
                                "front_right": zone_counts["front_right"],
                                "back_left": zone_counts["back_left"],
                                "back_right": zone_counts["back_right"],
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
                        },
                    }
                    self.mqtt_client.publish(self.app_state_topic, json.dumps(app_state_doc), qos=0)

                # 6. Prepare Annotated Frame for Web Preview
                annotated = frame.copy()

                # Calculate zone boundary line
                split_pixel_y = int(self.tracker.split_y * h)

                # Draw Front vs Back Zone Boundary Divider
                cv2.line(annotated, (0, split_pixel_y), (w, split_pixel_y), (0, 255, 255), 2)
                cv2.line(annotated, (w // 2, 0), (w // 2, h), (80, 80, 80), 1)

                # Labels for Zones
                front_label_y = split_pixel_y // 2 if not self.tracker.invert_zones else split_pixel_y + (h - split_pixel_y) // 2
                back_label_y = split_pixel_y + (h - split_pixel_y) // 2 if not self.tracker.invert_zones else split_pixel_y // 2

                cv2.putText(annotated, f"FRONT ZONE (ESP32-1: {self.front_board_id}) | People: {front_count}", (16, 52), cv2.FONT_HERSHEY_SIMPLEX, 0.52, (56, 189, 248), 2)
                cv2.putText(annotated, f"BACK ZONE (ESP32-2: {self.back_board_id}) | People: {back_count}", (16, split_pixel_y + 26), cv2.FONT_HERSHEY_SIMPLEX, 0.52, (192, 132, 252), 2)

                # Draw Bounding Boxes with Zone Tag
                for p in active_people:
                    x1 = int(p.bbox[0] * w)
                    y1 = int(p.bbox[1] * h)
                    x2 = int(p.bbox[2] * w)
                    y2 = int(p.bbox[3] * h)

                    # Cyan for Front Zone, Purple for Back Zone
                    box_color = (250, 180, 50) if p.is_front else (252, 132, 192)
                    cv2.rectangle(annotated, (x1, y1), (x2, y2), box_color, 2)

                    z_name = "FRONT" if p.is_front else "BACK"
                    tag = f"#{p.track_id} {z_name} {p.state} {int(p.confidence*100)}%"
                    (tw, th), _ = cv2.getTextSize(tag, cv2.FONT_HERSHEY_SIMPLEX, 0.45, 1)
                    cv2.rectangle(annotated, (x1, max(0, y1 - 20)), (x1 + tw + 6, max(20, y1)), (15, 25, 40), -1)
                    cv2.putText(annotated, tag, (x1 + 3, max(15, y1 - 4)), cv2.FONT_HERSHEY_SIMPLEX, 0.45, box_color, 1)

                # Top HUD Banner
                cv2.rectangle(annotated, (0, 0), (w, 32), (15, 25, 40), -1)
                b1_r1 = self.board_relays.get(self.front_board_id, {}).get(1, False)
                b2_r1 = self.board_relays.get(self.back_board_id, {}).get(1, False)
                hud_str = (
                    f"FPS: {fps:.1f} | Front: {front_count} (R1: {'ON' if b1_r1 else 'OFF'}) | "
                    f"Back: {back_count} (R2: {'ON' if b2_r1 else 'OFF'}) | Total: {total_count} | {self.mode}"
                )
                cv2.putText(annotated, hud_str, (12, 22), cv2.FONT_HERSHEY_SIMPLEX, 0.50, (240, 240, 240), 1)

                # Update Web Preview Buffer
                if self.preview_server is not None:
                    success, jpeg_buf = cv2.imencode(".jpg", annotated, [cv2.IMWRITE_JPEG_QUALITY, 78])
                    success_raw, raw_buf = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 85])
                    if success:
                        with self.preview_state.lock:
                            self.preview_state.latest_jpeg = jpeg_buf.tobytes()
                            if success_raw:
                                self.preview_state.latest_raw_jpeg = raw_buf.tobytes()
                            self.preview_state.latest_status = {
                                "fps": round(fps, 1),
                                "total_count": total_count,
                                "moving_count": moving_count,
                                "stationary_count": stationary_count,
                                "front_count": front_count,
                                "back_count": back_count,
                                "mode": self.mode,
                                "room_id": self.room_id,
                                "front_board_id": self.front_board_id,
                                "back_board_id": self.back_board_id,
                                "board1_relays": self.board_relays.get(self.front_board_id, {}),
                                "board2_relays": self.board_relays.get(self.back_board_id, {}),
                                "resolution": f"{w}x{h}",
                                "current_conf": round(cur_conf, 2),
                                "zones": zone_counts,
                            }

                if self.show_window:
                    try:
                        cv2.imshow("ClassPulse Vision & IoT", annotated)
                        if cv2.waitKey(1) & 0xFF == 27:
                            break
                    except (cv2.error, Exception):
                        self.show_window = False

                # Periodic terminal telemetry logging
                if now - getattr(self, "_last_console_log", 0) >= 3.0:
                    self._last_console_log = now
                    LOG.info(
                        f"[ZONE STATS] Total: {total_count} | Front: {front_count} (ESP32-1: {'ON' if b1_r1 else 'OFF'}) | "
                        f"Back: {back_count} (ESP32-2: {'ON' if b2_r1 else 'OFF'}) | FPS: {fps:.1f}"
                    )

        except KeyboardInterrupt:
            LOG.info("Stopping Multi-Zone Classroom Vision Controller...")
        finally:
            if cap is not None:
                cap.release()
            if picam2 is not None:
                try:
                    picam2.stop()
                    picam2.close()
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
                LOG.info("[SHUTDOWN] Broadcasting OFFLINE state and turning OFF zone relays...")
                offline_pkt = {
                    "occupancy": {
                        "count": 0,
                        "front_count": 0,
                        "back_count": 0,
                        "moving_count": 0,
                        "stationary_count": 0,
                        "zones": {"Zone 1": 0, "Zone 2": 0}
                    },
                    "status": "OFFLINE",
                    "online": False
                }
                self.mqtt_client.publish(self.app_state_topic, json.dumps(offline_pkt), qos=1, retain=True)
                self.mqtt_client.publish(f"ruet/classroom/{self.room_id}/zone/1/command/all", "ALL_OFF", qos=1)
                self.mqtt_client.publish(f"ruet/classroom/{self.room_id}/zone/2/command/all", "ALL_OFF", qos=1)
                time.sleep(0.3)
            except Exception as e:
                LOG.warning(f"Error during shutdown broadcast: {e}")
            self.mqtt_client.loop_stop()
            self.mqtt_client.disconnect()
            LOG.info("Clean shutdown complete.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="ClassPulse Multi-Zone Classroom Vision & Decision Controller")
    parser.add_argument(
        "--model",
        default="yolov8n.pt",
        help="Path to YOLOv8 model (.pt or .onnx). Defaults to yolov8n.pt",
    )
    parser.add_argument("--broker", default="broker.emqx.io", help="MQTT broker hostname")
    parser.add_argument("--port", type=int, default=1883, help="MQTT broker port")
    parser.add_argument("--room", default="reb_room_301", help="Classroom identifier")
    parser.add_argument("--front-board", default="board01", help="Front Zone Controller board identifier (Zone 1)")
    parser.add_argument("--back-board", default="board02", help="Back Zone Controller board identifier (Zone 2)")
    parser.add_argument("--mode", default="LIVE", choices=["DRY_RUN", "LIVE"], help="Operational mode (default: LIVE)")
    parser.add_argument("--channels", default="1,2", help="Comma-separated relay channels to actuate (default: 1,2)")
    parser.add_argument("--source", default=0, help="Camera index, 'picam', or video file")
    parser.add_argument("--no-gui", action="store_true", help="Run headless without display window (recommended for Pi)")
    parser.add_argument("--conf", type=float, default=0.25, help="Confidence threshold (default 0.25)")
    parser.add_argument("--width", type=int, default=1280, help="Camera capture width (default: 1280 HD)")
    parser.add_argument("--height", type=int, default=720, help="Camera capture height (default: 720 HD)")
    parser.add_argument("--imgsz", type=int, default=640, help="YOLO inference resolution (default: 640)")
    parser.add_argument("--split-y", type=float, default=0.50, help="Front/Back boundary ratio (default 0.50)")
    parser.add_argument("--invert-zones", action="store_true", help="Invert front and back zones if camera is rear-mounted")
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
        mode=args.mode,
        camera_source=source,
        show_window=not args.no_gui,
        conf_thresh=args.conf,
        preview_port=args.preview_port,
        width=args.width,
        height=args.height,
        imgsz=args.imgsz,
        split_y=args.split_y,
        invert_zones=args.invert_zones,
        channels=args.channels,
    )
    controller.run()
