# Reviewed model baseline

The baseline is **TF2 SSD MobileNet V2 COCO17 post-training quantized**, from
Google Coral's [CPU model catalog](https://coral.ai/models/object-detection/).
The artifact is present as `ssd_mobilenet_v2_coco_quant.tflite` (6,741,896 bytes).
`coco_labels.txt` and the unchanged upstream `LICENSE.google-coral` are included.
The upstream repository uses Apache-2.0; retain the license with the artifacts.

`manifest.json` records every exact URL, SHA256, and upstream commit
`104342d2d3480b3e66203073dac24f4e2dbb4c41`. `scripts/fetch_model.py` restores the
three artifacts from those URLs and verifies bytes before replacing any local
file. It never accepts an unverified replacement or falls back to another model.

Model SHA256:

```text
3438ee45f33153b1fe6c49e18bcd869ce7c94ef01c485d4eb027eaf8fc0db8ac
```

## Quantization and preprocessing

Static inspection found 175 INT8, 75 INT32, 11 FLOAT32 and 1 UINT8 tensors.
Thus the network is integer quantized with UINT8 input and float detection
postprocessing; this is not a claim that every tensor is signed INT8.
No Edge TPU operator is present. The only custom operator is
`TFLite_Detection_PostProcess`, supplied by the standard TFLite CPU runtime.

Input tensor 0, `serving_default_input:0`, has shape `[1,300,300,3]`, dtype UINT8,
scale `0.007843137718737125`, and zero point `127`. The baseline uses RGB bytes
directly (`input_encoding: raw_uint8`), consistent with Coral's
[image input adapter](https://github.com/google-coral/pycoral/blob/master/pycoral/adapters/common.py).
Pillow stretches the oriented image to 300×300. Box coordinates therefore remain
normalized to the original full image, with no crop or letterbox correction.

For a reviewed replacement, `normalized_real` instead computes
`real = (pixel - input_mean) / input_std`; integer input then uses
`clip(round(real / tensor_scale + zero_point))`. Float input uses `real` directly.
The input dtype, dimensions, scale, and zero point are checked after allocation.
Input quantization alone does not establish a replacement's normalization rules.

## Verified output mapping

Positions below refer to the **ordered graph outputs**, equivalent to positions
in `get_output_details()`, rather than tensor indices:

| Meaning | Config position | Tensor index | Expected allocated shape |
| --- | --- | --- | --- |
| Boxes `(ymin,xmin,ymax,xmax)` | 1 | 250 | `[1,20,4]` |
| Classes, zero based | 3 | 251 | `[1,20]` |
| Scores | 0 | 252 | `[1,20]` |
| Valid detection count | 2 | 253 | `[1]` |

All four output dtypes are FLOAT32. These tensors have empty shape arrays in
the serialized FlatBuffer. The listed allocated shapes were initially derived
from the postprocess operator's `max_detections=20` and
`max_classes_per_detection=1`. They have now been **observed after allocation on
native Windows with TensorFlow CPU 2.16.2**; real inference was also executed.
See [Windows validation](../docs/windows_inference_validation.md) and
[captured allocated metadata](../docs/windows_allocated_tensors.json).
Pi runtime allocation remains unverified.
The adapter checks the actual allocated shapes at startup and rejects mismatches.
The output mapping is derived from the custom operator outputs `[250,251,252,253]`
and the graph outputs `[252,250,253,251]`, using the
[TFLite postprocess contract](https://github.com/tensorflow/tensorflow/blob/v2.14.0/tensorflow/lite/kernels/detection_postprocess.cc).
Names alone cannot distinguish these outputs.

Person is zero-based class **0**, the first line of the supplied label map.
The 90-slot label map contains unused COCO category slots. Do not prepend a
background line, shift class IDs, or replace it with a contiguous 80-label map.
The detector filters person scores at the configured threshold and respects the
valid count rather than interpreting padded detections. Nonfinite or invalid
outputs raise a fault instead of becoming a false empty-room observation.
At most 20 detections can be returned; crowded-room counts can saturate.

## Why this artifact

The [official MediaPipe page](https://ai.google.dev/edge/mediapipe/solutions/vision/object_detector)
advertised an SSD MobileNetV2 INT8 download, but that link resolved to a
`float16/latest/ssd_mobilenet_v2.tflite` URL during repository preparation.
That mismatch blocks relying on that particular INT8 link. The explicitly selected
Coral CPU baseline above was downloaded and structurally verified instead; no
float model or unrelated detector was silently substituted.

## Reproduce static inspection

```powershell
.\.venv\Scripts\python.exe scripts/fetch_model.py
.\.venv\Scripts\python.exe scripts/inspect_model.py
.\.venv\Scripts\python.exe scripts/check_environment.py --static
```

`inspection.json` is the machine-readable FlatBuffer inspection. The schema
packages are development-only dependencies. Neither inspection nor unit tests
allocate the real model, invoke inference, use photos, or evaluate accuracy.

For replacement models, verify source/license/hash, preprocessing, person label,
ordered output semantics, and CPU operator compatibility first. Configure the
adapter explicitly. It supports batch-one SSD outputs after NMS/postprocessing,
not raw SSD anchors/logits, YOLO heads, or per-axis-quantized I/O.
