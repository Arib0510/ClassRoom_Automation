"""Restore reviewed baseline artifacts from commit-pinned URLs with SHA256 checks."""

from __future__ import annotations

import hashlib
import json
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    manifest = json.loads((ROOT / "models/manifest.json").read_text(encoding="utf-8"))
    for artifact in manifest["artifacts"]:
        destination = (ROOT / "models" / artifact["file"]).resolve()
        if destination.parent != ROOT / "models":
            raise ValueError("Artifact destination must stay inside models/")
        expected = artifact["sha256"]
        if (
            destination.exists()
            and hashlib.sha256(destination.read_bytes()).hexdigest() == expected
        ):
            print(f"Verified existing {destination.name}")
            continue
        url = artifact["url"]
        if not url.startswith("https://raw.githubusercontent.com/google-coral/test_data/"):
            raise ValueError("Unexpected model source; review manifest")
        request = urllib.request.Request(url, headers={"User-Agent": "classroom-occupancy-vision"})
        with urllib.request.urlopen(request, timeout=60) as response:
            data = response.read(16 * 1024 * 1024 + 1)
        if len(data) > 16 * 1024 * 1024 or hashlib.sha256(data).hexdigest() != expected:
            raise ValueError(f"Invalid download for {destination.name}; existing file preserved")
        temporary = destination.with_suffix(destination.suffix + ".part")
        temporary.write_bytes(data)
        temporary.replace(destination)
        print(f"Downloaded and verified {destination.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
