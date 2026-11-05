"""Record separate software and genuine model suites; no hardware acceptance claims."""

import argparse
import json
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from src.person_labels import source_hash  # noqa: E402
from src.phase3_diagnostics import empty_output  # noqa: E402


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output", type=Path, default=Path("outputs/phase4_model_comparison/validation")
    )
    args = parser.parse_args()
    empty_output(args.output)
    unit = str(ROOT / ".venv/Scripts/python.exe")
    ssd = str(ROOT / ".venv-inference/Scripts/python.exe")
    yolo = str(ROOT / ".venv-yolov5/Scripts/python.exe")
    checks = [
        ("unit", [unit, "-m", "pytest", "--junitxml=" + str(args.output / "unit.xml")]),
        ("ruff", [unit, "-m", "ruff", "check", "."]),
        ("format", [unit, "-m", "ruff", "format", "--check", "."]),
        ("static", [unit, "scripts/check_environment.py", "--static"]),
        (
            "ssd_real",
            [
                ssd,
                "-m",
                "pytest",
                "tests/integration/test_phase3_real.py",
                "tests/integration/test_windows_inference.py",
                "--run-real-inference",
                "--junitxml=" + str(args.output / "ssd_real.xml"),
            ],
        ),
        (
            "yolo_export_real",
            [
                yolo,
                "-m",
                "pytest",
                "tests/integration/test_phase4_real.py",
                "tests/integration/test_phase4_export_real.py",
                "--run-real-inference",
                "--junitxml=" + str(args.output / "yolo_export_real.xml"),
            ],
        ),
        ("yolo_pip", [yolo, "-m", "pip", "check"]),
    ]
    records = []
    for name, command in checks:
        result = subprocess.run(
            command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT
        )
        (args.output / f"{name}.log").write_text(result.stdout, encoding="utf-8")
        record = {
            "check": name,
            "command": command,
            "exit_code": result.returncode,
            "last_line": result.stdout.strip().splitlines()[-1] if result.stdout.strip() else "",
        }
        xml = args.output / f"{name}.xml"
        if xml.exists():
            suite = ET.parse(xml).getroot().find("testsuite")
            record["pytest"] = {
                k: int(suite.attrib[k]) for k in ("tests", "failures", "errors", "skipped")
            }
            record["pytest"]["passed"] = record["pytest"]["tests"] - sum(
                record["pytest"][k] for k in ("failures", "errors", "skipped")
            )
        records.append(record)
        print(name, record["exit_code"], record["last_line"], flush=True)
    protected = json.loads(
        (ROOT / "outputs/phase4_inspection/protected_inventory.json").read_text()
    )
    changed = [
        name
        for name, digest in protected["sha256"].items()
        if not (ROOT / name).is_file() or source_hash(ROOT / name) != digest
    ]
    # New experimental modules are outside this original-file inventory.
    record = {
        "checks": records,
        "protected_original_files": len(protected["sha256"]),
        "changed_original_files": changed,
        "hardware_tested": False,
        "all_passed": all(r["exit_code"] == 0 for r in records) and not changed,
    }
    (args.output / "evidence.json").write_text(json.dumps(record, indent=2) + "\n")
    return 0 if record["all_passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
