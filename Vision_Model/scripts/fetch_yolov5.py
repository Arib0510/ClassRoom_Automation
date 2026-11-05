"""Acquire one pinned official experiment without replacing existing artifacts."""

import hashlib
import subprocess
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REVISION = "915bbf294bb74c859f0b41f1c23bc395014ea679"
SHA256 = "4f180cf23ba0717ada0badd6c685026d73d48f184d00fc159c2641284b2ac0a3"
URL = "https://github.com/ultralytics/yolov5/releases/download/v7.0/yolov5n.pt"


def main():
    folder = ROOT / "models/experimental/yolov5n"
    folder.mkdir(parents=True, exist_ok=True)
    source = folder / "source"
    if not source.exists():
        subprocess.run(
            [
                "git",
                "clone",
                "--depth",
                "1",
                "--branch",
                "v7.0",
                "https://github.com/ultralytics/yolov5.git",
                str(source),
            ],
            check=True,
        )
    revision = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True)
    if revision.strip() != REVISION:
        raise ValueError("Source revision mismatch; preserving existing source")
    target = folder / "yolov5n.pt"
    if not target.exists():
        partial = target.with_suffix(".part")
        if partial.exists():
            raise ValueError("Previous partial download exists; inspect it before retrying")
        urllib.request.urlretrieve(URL, partial)
        if hashlib.sha256(partial.read_bytes()).hexdigest() != SHA256:
            raise ValueError("Download hash mismatch; partial file preserved")
        partial.rename(target)
    if hashlib.sha256(target.read_bytes()).hexdigest() != SHA256:
        raise ValueError("Existing weight hash mismatch; no replacement attempted")
    print(f"Verified {REVISION}: {SHA256}")


if __name__ == "__main__":
    main()
