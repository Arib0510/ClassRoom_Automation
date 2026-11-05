"""Headless browser preview for the existing Phase 5 OBSERVE pipeline."""
import argparse
import io
import json
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

HTML = b"""<!doctype html>
<html>
<head>
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Classroom SSD preview</title>
<style>
body { background:#101820; color:#eee; font:16px Arial;
       max-width:900px; margin:24px auto; padding:12px; }
img { width:100%; height:auto; background:#222; }
#status { padding:12px 0; }
</style>
</head>
<body>
<h2>Classroom SSD \xe2\x80\x94 OBSERVE</h2>
<p>Detection runs on the Pi. Appliance commands are disabled.</p>
<div id="status">Waiting for the first processed frame...</div>
<img id="view" alt="Waiting for SSD detection">
<script>
let previousURL;
async function refresh() {
  const status = document.getElementById("status");
  try {
    const response = await fetch("/frame.jpg", {cache:"no-store"});
    if (!response.ok) throw new Error("Waiting for a processed frame");
    const age = Number(response.headers.get("X-Frame-Age"));
    const blob = await response.blob();
    const nextURL = URL.createObjectURL(blob);
    document.getElementById("view").src = nextURL;
    if (previousURL) URL.revokeObjectURL(previousURL);
    previousURL = nextURL;
    status.textContent = (age >= 4 ? "STALE FRAME \xe2\x80\x94 " : "Receiving \xe2\x80\x94 ")
       + "capture age: " + age.toFixed(1) + " s";
    status.style.color = age >= 4 ? "#ff8a80" : "#80e0a0";
  } catch (error) {
    status.textContent = error.message + " \xe2\x80\x94 check the Pi terminal";
    status.style.color = "#ffcf70";
  }
  setTimeout(refresh, 500);
}
refresh();
</script>
</body>
</html>"""


def main():
    from PIL import Image, ImageDraw
    from src.phase5_config import load_phase5
    from src import phase5_runtime as runtime

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path,
                        default=ROOT / "config/phase5.example.yaml")
    parser.add_argument("--host", type=str, default="0.0.0.0",
                        help="Network host interface to bind (default 0.0.0.0 for LAN browser access)")
    parser.add_argument("--port", type=int, default=8080)
    args = parser.parse_args()

    config = load_phase5(args.config)
    if config.mode != "OBSERVE" or config.data["mqtt"]["enabled"]:
        raise ValueError("Preview requires OBSERVE mode with MQTT disabled")

    lock = threading.Lock()
    latest = {"jpeg": None, "captured_at": None}
    original_observe = runtime.Pipeline.observe

    def observe_with_preview(self, frame, result, now, unix):
        outcome = original_observe(self, frame, result, now, unix)
        try:
            image = Image.fromarray(frame["rgb"])
            draw = ImageDraw.Draw(image)
            width, height = image.size

            for detection in result["detections"]:
                ymin, xmin, ymax, xmax = detection.box
                x1 = max(0, min(width - 1, int(xmin * width)))
                y1 = max(0, min(height - 1, int(ymin * height)))
                x2 = max(x1, min(width - 1, int(xmax * width)))
                y2 = max(y1, min(height - 1, int(ymax * height)))
                draw.rectangle((x1, y1, x2, y2), outline="lime", width=2)
                label = f"Person {detection.score:.0%}"
                label_y = max(0, y1 - 14)
                draw.rectangle((x1, label_y,
                                min(width - 1, x1 + 100), label_y + 13),
                               fill="black")
                draw.text((x1 + 2, label_y), label, fill="lime")

            zones = outcome[0]
            lines = [
                f"OBSERVE | people: {len(result['detections'])}",
                f"SSD: {result['total_detector_seconds']:.2f}s",
            ]
            lines += [
                f"{name}: {state['state']}" for name, state in zones.items()
            ]
            draw.rectangle((0, 0, min(width - 1, 310),
                            len(lines) * 15 + 6), fill="black")
            for index, line in enumerate(lines):
                draw.text((5, 4 + index * 15), line, fill="white")

            buffer = io.BytesIO()
            image.save(buffer, format="JPEG", quality=65)
            with lock:
                latest["jpeg"] = buffer.getvalue()
                latest["captured_at"] = frame["captured_at"]
        except Exception as exc:
            print(f"Preview rendering error: {exc}", flush=True)
        return outcome

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == "/":
                body, content_type, age = HTML, "text/html; charset=utf-8", None
            elif self.path == "/frame.jpg":
                with lock:
                    body = latest["jpeg"]
                    captured_at = latest["captured_at"]
                if body is None:
                    self.send_error(503, "Waiting for first processed frame")
                    return
                content_type = "image/jpeg"
                age = max(0, time.monotonic() - captured_at)
            else:
                self.send_error(404)
                return

            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            if age is not None:
                self.send_header("X-Frame-Age", f"{age:.3f}")
            self.end_headers()
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    runtime.Pipeline.observe = observe_with_preview
    thread.start()

    output = ROOT / "outputs" / "preview" / uuid.uuid4().hex
    print(f"Preview listening on http://{args.host}:{args.port} (open in your browser)", flush=True)
    print(f"Run logs: {output}", flush=True)
    print("Starting camera and SSD. Press Ctrl+C to stop.", flush=True)
    try:
        code = runtime.run_service(config, output)
    finally:
        runtime.Pipeline.observe = original_observe
        server.shutdown()
        server.server_close()

    if code:
        print("Pipeline stopped with an error. Recent log lines:", flush=True)
        if output.exists():
            for path in output.rglob("*.jsonl"):
                print(f"\n{path}", flush=True)
                with path.open() as stream:
                    from collections import deque
                    print("".join(deque(stream, maxlen=6)), flush=True)
    return code


if __name__ == "__main__":
    raise SystemExit(main())

