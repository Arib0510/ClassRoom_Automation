# Offline diagnostic workflow

This workflow targets the Raspberry Pi 5 8 GB runtime and is intentionally
offline. It accepts image folders and existing video files only. It never opens
a camera, constructs MQTT, publishes commands, changes calibration or zone
mappings, trains, or writes weights/dataset annotations.

Run it from `Vision_Model`:

```powershell
python -m src.offline_diagnostics images --input ..\Pi_5_Images --output outputs\diagnostics-images --model auto --conf 0.28 --iou 0.45 --imgsz 640
python -m src.offline_diagnostics video --input captures\saved-session.mp4 --output outputs\diagnostics-video --model auto --conf 0.28 --iou 0.45 --track-iou 0.18 --annotated-video
```

`--model auto` is the only selector that may use the repository fallback order.
Any explicit missing path fails before model loading. Each run records the
resolved path, full SHA256 and model class names. Ultralytics is imported only
for these commands.

The image command bypasses tracking and writes detector-only overlays plus
`detections.json` and `inference_metadata.json`. The video command uses the
existing `ClassroomMotionTracker`, and each frame records a timestamp,
detector count, observed confirmed count, tentative count, retained count, and
track details. Detector boxes are orange; confirmed, tentative and retained
tracks are green, yellow and blue respectively.

Preprocessing is recorded in each metadata file. The current runtime passes
BGR arrays to the same Ultralytics API, uses `imgsz` and `rect=True` for model
resizing, applies a 180-degree flip by default on video/camera paths, and does
not apply EXIF orientation. Image-folder diagnostics default to no flip because
the current runtime's static-image path does not flip; use `--flip-180` when the
folder represents an unrotated ceiling-camera source. Coordinates are xyxy
pixel edges in the oriented diagnostic frame and normalized by its width and
height.

Ultralytics returned boxes may already have model-internal suppression applied;
they are not pre-NMS raw predictions. The explicit `--iou` is the detector's
model-internal suppression IoU. `--track-iou` is a separate tracker matching
threshold.

## Label review and evaluation

Export existing YOLO sidecars or COCO labels over the clean images without
editing them:

```powershell
python -m src.offline_diagnostics review-labels --input ..\Pi_5_Images --labels ..\Pi_5_Images --output outputs\label-review
python -m src.offline_diagnostics review-labels --input ..\Pi_5_Images --labels dataset\labels.coco.json --output outputs\label-review-coco
```

YOLO sidecars are always marked `unreviewed_pseudo_labels` by this export.
COCO labels are considered reviewed only when `info.annotation_source` is
`human_manual`, every image has `reviewed: true`, and every image has a
nonempty `reviewed_by`. No command here changes those annotations.

Evaluate an image diagnostic against fully human-reviewed COCO labels:

```powershell
python -m src.offline_diagnostics evaluate --predictions outputs\diagnostics-images\detections.json --labels evaluation_baseline\labels.coco.json --output outputs\diagnostics-images\evaluation.json --match-iou 0.50
```

Evaluation sorts predictions by descending confidence and greedily matches each
prediction to at most one unmatched person label at the requested IoU. An
unmatched prediction overlapping any ground-truth person at that IoU is counted
as a duplicate. Duplicate rate is duplicates divided by all predictions. Count
error is mean absolute predicted-minus-reviewed person count per image. The
report includes precision and recall, but neither those metrics nor unit tests
establish classroom reliability.
