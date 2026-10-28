# Isolated YOLOv5n experiment

Official [Ultralytics YOLOv5 v7.0](https://github.com/ultralytics/yolov5/tree/915bbf294bb74c859f0b41f1c23bc395014ea679),
revision `915bbf294bb74c859f0b41f1c23bc395014ea679`.
Weights: [official v7.0 yolov5n.pt](https://github.com/ultralytics/yolov5/releases/download/v7.0/yolov5n.pt).

Computed SHA-256: `4f180cf23ba0717ada0badd6c685026d73d48f184d00fc159c2641284b2ac0a3`.
Size: 4,062,133 bytes. Checkpoint parameters: 1,872,157; after official Conv/BN
fusion: 1,867,405. These counts were measured from the downloaded checkpoint.

[manifest.json](manifest.json) records checkpoint labels, architecture and tensor
contracts. The checkpoint's own 80-class map identifies `person` as index 0;
this was checked independently of SSD's indexing. Tested inputs are batch-one
RGB NCHW float32 `/255`, 320 or 416 square, official letterbox with `auto=False`.
Decoded outputs are `[1,6300,85]` and `[1,10647,85]`: input-pixel xywh,
objectness, then 80 class probabilities. Postprocessing is external to exports.

The pinned source's license is **GPL-3.0**, copied unchanged as
[LICENSE.yolov5-v7.0](LICENSE.yolov5-v7.0). Do not substitute the current branch's
license for this historical source. Preserve applicable license notices and
corresponding-source obligations when redistributing code/weights/derived
artifacts; no separate permissive weight-license exception was established here.
Local test packages do not establish redistribution compliance.

`source/`, weights and runtime caches are ignored by Git. Restore with:

```powershell
.\.venv-yolov5\Scripts\python.exe scripts/fetch_yolov5.py
```

The fetcher refuses unexpected existing bytes. The adapter checks weight SHA,
source revision and tracked-source cleanliness before loading the official pickle.
Automatic upstream dependency installation is disabled. Do not load other pickle
checkpoints through this experiment. Full environment setup is
`scripts/setup_windows_yolov5.ps1`; dependencies remain in `.venv-yolov5`.

See [comparison](../../../docs/phase4_model_comparison.md) and
[deployment feasibility](../../../docs/phase4_deployment_feasibility.md).
The experiment is not connected to the live pipeline. Nothing promotes these
weights, changes production settings or starts camera/MQTT/appliance control.
