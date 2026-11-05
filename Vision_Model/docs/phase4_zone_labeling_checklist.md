# Phase 4 optional physical-zone review

Status: **PENDING**. The current calibration is illustrative. None of the 108
image-zone pairs is established as physically occupied or vacant. Keep the
existing annotations and calibration unchanged.

1. Obtain a reliable room plan identifying appliance ownership, physical front,
   back, left and right, with a named human reviewer. Confirm which camera poses
   and photos that evidence covers. An image split is not a room survey.
2. Use originals and human-box overlays to inspect all 54 annotated instances.
   Assign `front_left`, `front_right`, `back_left`, `back_right` or `UNKNOWN`.
   Record the physical basis and reviewer for each known assignment. Preserve
   UNKNOWN for ambiguous ownership, aisles or insufficient layout evidence.
3. Independently review all four binary image-zone states for every image. Record
   `occupied`, `vacant` or `UNKNOWN`. A zone without an assigned visible person is
   not automatically vacant. Occlusion, unseen areas and unresolved persons may
   require UNKNOWN. Known person assignments must not contradict confirmed vacancy.
4. Review the saved sidecar and attest physical layout verification only when
   supported by the actual room evidence. The workflow records this assertion;
   it does not validate physical facts automatically.
5. Obtain a separately verified detector-to-physical-zone mapping for the exact
   image poses/hashes. Do not use `config/zones.yaml` or illustrative Phase 3B
   polygons to produce operational metrics. Prediction zone states must include
   UNKNOWN when mapping is unresolved.
6. Evaluate only when both label and prediction-mapping evidence are reliable.
   Preserve UNKNOWN exclusions and report coverage with all binary results.

Initialize or review a **new sidecar** without editing person boxes:

```powershell
.\.venv\Scripts\python.exe -m src.phase4_zones init --labels evaluation_baseline/labels.coco.json --output outputs/phase4_zone_draft.json
.\.venv\Scripts\python.exe -m src.phase4_zones review --labels evaluation_baseline/labels.coco.json --sidecar outputs/phase4_zone_draft.json --output outputs/phase4_zone_reviewed.json
```

The review command is a text workflow: inspect each photograph and its labelled
box IDs alongside the prompts. It does not infer ownership from box coordinates.
Every output must be new. To review further, read the previous sidecar and write
another new file; a previous record is not overwritten. The supplied comparison
already has `zone_labels.pending.json` with all person/pair states UNKNOWN.

Future prediction JSON must explicitly provide:

```json
{
  "mapping_physically_verified": true,
  "mapping_evidence": "Actual human-verified mapping identifier, reviewer and pose evidence",
  "images": [
    {
      "image_id": 1,
      "source_sha256": "the exact original image hash",
      "zones": {
        "front_left": "UNKNOWN",
        "front_right": "UNKNOWN",
        "back_left": "UNKNOWN",
        "back_right": "UNKNOWN"
      }
    }
  ]
}
```

This is a schema example, not a claim that a verified mapping exists. Include
exactly one record for each labelled image. Pair states are occupied/vacant/UNKNOWN.
After genuine mapping evidence is available:

```powershell
.\.venv\Scripts\python.exe -m src.phase4_zones evaluate --labels evaluation_baseline/labels.coco.json --sidecar outputs/phase4_zone_reviewed.json --predictions outputs/physically_verified_zone_predictions.json --output outputs/phase4_zone_metrics.json
```

The evaluator produces per-zone and aggregate TP/FP/FN/TN, false-vacancy (FN),
false-occupancy (FP), precision, recall and F1. Each image-zone pair is one
observation, independent of how many people occupy it. UNKNOWN truth is excluded
from primary metrics. UNKNOWN predictions remain explicitly unresolved; conditional
binary metrics exclude them and occupied-zone recall including unresolved
predictions counts that loss of coverage. They are never silently counted vacant.

This offline workflow does not start a camera, connect MQTT, modify occupancy
state, operate ESP32s or authorize real appliance activation.
