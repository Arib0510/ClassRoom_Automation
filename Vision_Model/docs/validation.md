# Software validation record

This is the original preparation record. Subsequent Windows model allocation,
real image-folder inference and the expanded test suite are documented in
[Windows inference validation](windows_inference_validation.md). The historical
no-inference statements below apply to repository preparation, not that later run.

Repository preparation date: 2026-10-25. Host: Windows, CPython 3.12.0.
All project files, artifacts and local development environment are under
`Classroom_Automation/Vision_Model`.

| Check | Result |
| --- | --- |
| `python -m pytest -q` | 86 passed; synthetic data and fake interpreter/MQTT client only |
| `python -m ruff check .` | Passed |
| `python -m ruff format --check .` | Passed |
| `python -m compileall -q src scripts tests` | Passed |
| Python 3.11 grammar parsing | Passed for all source, scripts and test modules |
| `python scripts/check_environment.py --static` | Passed; calibration explicitly pending |
| `python -m src.main check-config` | Passed; no hardware or interpreter allocation |
| `python -m src.main simulate` | 61 deterministic synthetic snapshots; no network or sleeps |
| Model restore/hash checks | Model, labels and upstream license match pinned manifest |
| FlatBuffer inspection | Current bytes match `models/inspection.json`; no inference |
| PowerShell parser and argument binding | Passed for Windows setup script |
| Git Bash `bash -n scripts/setup_pi.sh` | Passed; script not executed on a Pi |
| `python -m pip check` | No broken development requirements |
| Source distribution and wheel build | Built; archive contents inspected |

The source distribution includes configuration, baseline model, model license,
scripts, documentation and tests. The wheel contains the application modules and
CLI entry point; external configuration/model deployment is documented in README.

The model download and source verification used HTTPS. No MQTT broker connection,
camera capture, real-model interpreter allocation/invocation, photo evaluation,
latency/accuracy benchmark, resource measurement, training, ESP32 operation or
hardware test was performed. Windows package checks do not prove ARM runtime
compatibility. Allocated SSD output shapes remain startup assertions derived from
the serialized postprocess contract until verified on the Pi.

Physical zone calibration, broker address/credentials, controller mapping and
firmware integration are deployment inputs. The example zones remain
`calibrated: false`, and live startup is blocked until calibration is declared.
The <=5-second arrival-to-action target is unverified; follow
[tomorrow's test plan](tomorrow_test_plan.md).
