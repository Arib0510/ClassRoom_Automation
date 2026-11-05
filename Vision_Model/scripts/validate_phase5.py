"""Record distinct software, genuine SSD/YOLO and real loopback-broker checks; no Pi claims."""

import argparse
import ast
import json
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from src.phase5_config import digest  # noqa: E402


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    unit = str(ROOT / ".venv/Scripts/python.exe")
    ssd = str(ROOT / ".venv-inference/Scripts/python.exe")
    yolo = str(ROOT / ".venv-yolov5/Scripts/python.exe")
    broker = str(ROOT / ".venv-phase5-test/Scripts/python.exe")
    checks = [
        ("software", [unit, "-m", "pytest", "--junitxml=" + str(args.output / "software.xml")]),
        ("ruff", [unit, "-m", "ruff", "check", "."]),
        ("format", [unit, "-m", "ruff", "format", "--check", "."]),
        ("static", [unit, "scripts/check_environment.py", "--static"]),
        (
            "ssd_real",
            [
                ssd,
                "-m",
                "pytest",
                "tests/integration/test_windows_inference.py",
                "tests/integration/test_phase3_real.py",
                "tests/integration/test_phase5_real.py",
                "--run-real-inference",
                "--junitxml=" + str(args.output / "ssd_real.xml"),
            ],
        ),
        (
            "phase4_real",
            [
                yolo,
                "-m",
                "pytest",
                "tests/integration/test_phase4_real.py",
                "tests/integration/test_phase4_export_real.py",
                "--run-real-inference",
                "--junitxml=" + str(args.output / "phase4_real.xml"),
            ],
        ),
        (
            "broker",
            [
                broker,
                "scripts/phase5_test_broker.py",
                "test",
                "--output",
                str(args.output / "broker"),
            ],
        ),
        (
            "windows_pipeline",
            [
                ssd,
                "-m",
                "src.phase5_runtime",
                "run",
                "--input",
                "sample_images",
                "--backend",
                "tensorflow",
                "--max-frames",
                "2",
                "--output",
                str(args.output / "windows_pipeline"),
            ],
        ),
        ("broker_dependencies", [broker, "-m", "pip", "check"]),
    ]
    git = shutil.which("git")
    bash = Path(git).resolve().parents[1] / "bin/bash.exe" if git else Path("missing-bash")
    if bash.exists():
        checks.append(("shell_syntax", [str(bash), "-n", "scripts/install_phase5.sh"]))
    results = []
    for name, command in checks:
        result = subprocess.run(
            command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
        )
        (args.output / f"{name}.log").write_text(result.stdout, encoding="utf-8")
        record = {
            "check": name,
            "command": command,
            "exit_code": result.returncode,
            "last_line": result.stdout.strip().splitlines()[-1] if result.stdout.strip() else "",
        }
        xml = args.output / ("broker/broker.xml" if name == "broker" else f"{name}.xml")
        if xml.exists():
            suite = ET.parse(xml).getroot().find("testsuite")
            record["pytest"] = {
                key: int(suite.attrib[key]) for key in ("tests", "failures", "errors", "skipped")
            }
            record["pytest"]["passed"] = record["pytest"]["tests"] - sum(
                record["pytest"][k] for k in ("failures", "errors", "skipped")
            )
        results.append(record)
        print(name, result.returncode, record["last_line"], flush=True)
    original = json.loads((ROOT / "outputs/phase5/protected_inventory.json").read_text())
    changed = [
        name
        for name, sha in original.items()
        if not (ROOT / name).is_file() or digest(ROOT / name) != sha
    ]
    allowed = {".gitignore"}
    unexpected = [p for p in changed if p.replace("\\", "/") not in allowed]
    history_path = ROOT / "outputs/phase4_inspection/protected_inventory.json"
    historical = json.loads(history_path.read_text())["sha256"]
    historical_changes = [
        name
        for name, sha in historical.items()
        if not (ROOT / name).is_file() or digest(ROOT / name) != sha
    ]
    for path in (ROOT / "src").glob("phase5_*.py"):
        ast.parse(path.read_text(), feature_version=(3, 11))
    evidence = {
        "checks": results,
        "protected_file_count": len(original),
        "expected_changed_files": changed,
        "unexpected_changed_files": unexpected,
        "historical_protected_files": len(historical),
        "historical_changed_files": historical_changes,
        "python311_grammar": "PASS",
        "pi_hardware_tested": False,
        "esp32_tested": False,
        "appliance_energized": False,
        "all_passed": all(r["exit_code"] == 0 for r in results)
        and not unexpected
        and not historical_changes,
    }
    (args.output / "evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")
    return 0 if evidence["all_passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
