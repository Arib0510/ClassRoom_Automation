# Phase 5 fixed-view data collection and calibration

No classroom capture was performed on this Windows host. The new collection tool
uses the same bounded camera worker and records actual acquired RGB arrays as
lossless PNG, full dimensions, UTC save time, monotonic/sensor timestamps, frame ID,
camera/pose/rotation, session ID, source SHA-256, lighting and optional human zone
states. It never runs a detector or infers ground truth from predictions.

## Privacy and collection authorization

Obtain the school's required consent/authorization before capture. Use an approved
consent reference, not student names, in metadata. Limit access to the collection
account/reviewers; the CLI sets a restrictive umask and creates a private session
directory. Agree a retention/deletion schedule and responsible custodian before
collecting. Archives containing original student images are not anonymized or
encrypted by this tool. Transfer only through approved encrypted SFTP/SCP or
equivalent channels; keep credentials outside the repository. Do not publish raw
images, identities, room layouts or consent documents automatically.

## Fixed-view captures

After camera/mount/orientation verification on the Pi:

```bash
.venv-phase5/bin/python -m src.phase5_data collect \
  --config config/operator.local.yaml --interval 5 --count 120 \
  --lighting daylight --consent-reference APPROVED_CAPTURE_RECORD \
  --output dataset-daylight-01
```

Use `--manual` for Enter-to-capture and q-to-finish. Use a new output directory
for every session. A maximum of 4096 frames bounds a session; select a smaller
approved count to control disk usage. There is no image backlog during the
interval. Outputs include immutable session metadata, an append/flush journal and
a final manifest; the journal preserves completed records if capture is interrupted.
The PNG is the acquired oriented RGB frame, not raw Bayer sensor data or a model
resized input. It must retain the final deployed camera framing.

Plan sessions for empty room; one/multiple seated people; standing/walking people;
partial, desk-hidden, near/distant and boundary people; daylight, artificial/mixed
light; and transitions among all four physically known appliance zones. Include
negative scenes and difficult conditions. Do not exclude frames because a model
misses someone. Record camera/pose changes as a new session and recalibrate.

Optional `--human-zones zones.json` accepts exactly the four zone IDs with
OCCUPIED/VACANT/UNKNOWN. This is an explicit human assertion, not an automatic
annotation. Use it only while the recorded scenario stays true; otherwise leave
UNKNOWN and review afterward. Known absence needs visibility/physical evidence.
No person names or identities are needed for this task.

## Privacy-preserving export

```bash
# Default: sanitized manifest only, no photographs or absolute source paths.
.venv-phase5/bin/python -m src.phase5_data export --input dataset-daylight-01 --output dataset-metadata-01.zip
# Only after authorization to transfer original images:
.venv-phase5/bin/python -m src.phase5_data export --input dataset-daylight-01 --include-images --output dataset-images-01.zip
```

Exports verify source hashes and refuse existing destination files. The manifest
contains image names/hashes/dimensions, lighting and human/UNKNOWN zone states;
it excludes private consent references and internal source paths. Face redaction
is not performed. Review metadata for accidental identifying text before sharing.
Archive/checksum integrity is not a consent grant or confidentiality mechanism.

## Human boxes and physical calibration

Transfer an authorized final mounted reference to Windows. Reuse the existing
human box utility for a NEW dataset and the existing version-2 calibration editor:

```powershell
.\.venv\Scripts\python.exe -m src.annotate_persons --input path/to/new_camera_images --labels outputs/phase5/new_labels.coco.json
.\.venv\Scripts\python.exe -m src.calibrate_zones init --image path/to/frame_00001.png --calibration config/mounted.local.json --mounted-reference --camera-id ACTUAL_CAMERA_ID --pose-id ACTUAL_POSE_ID
.\.venv\Scripts\python.exe -m src.calibrate_zones edit --image path/to/frame_00001.png --calibration config/mounted.local.json
```

Match camera ID/pose, flips, rotation and oriented dimensions to Phase 5 settings.
Review seats/bench anchors against real appliance ownership. For seated people,
the bottom of a visible-body box is not necessarily a floor point. Keep unmapped
aisles and ambiguous boundaries UNKNOWN. Use independently verified ground contact
for ground-plane mode. The editor's final confirmation requires mounted-reference
checks; the old illustrative geometry must not be promoted by flipping a boolean.

Generate a Phase 5 `commissioning-template` from those exact geometry bytes. It
starts `verified:false` and every vacancy coverage flag false. Record reviewer,
verification date, physical evidence and actual geometry revision. Only after
on-site review can a responsible human complete it. The application validates
camera/pose/orientation/dimensions, geometry checksum and confirmation on load;
changes revoke eligibility.

Use the Phase 4 optional person-zone review workflow on compatible labelled
datasets if useful, preserving UNKNOWN and independent image-zone vacancy review.
Historical 27-image labels/predictions remain unchanged. Their all-UNKNOWN zones
cannot become operational labels merely because this new workflow exists.
