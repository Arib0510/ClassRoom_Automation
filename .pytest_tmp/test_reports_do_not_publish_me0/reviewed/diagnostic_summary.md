# Phase 3 diagnostic summary

Complete human labels evaluated at the matching IoU below.

Matching IoU: 0.5; global crop NMS IoU: 0.5.

| Mode | 0.10 | 0.20 | 0.30 | 0.40 | 0.50 | 0.55 |
| --- | --- | --- | --- | --- | --- | --- |
| full | 0 | 0 | 0 | 0 | 0 | 0 |
| roi | 0 | 0 | 0 | 0 | 0 | 0 |
| left_right | 0 | 0 | 0 | 0 | 0 | 0 |
| overlap | 0 | 0 | 0 | 0 | 0 | 0 |

These are prediction counts, not people counts or evidence of improved accuracy.
Raw returned person outputs, including scores below 0.10, are in predictions.json.
See threshold_comparisons/, annotated/, roi_previews/, model_inputs/, ground_truth/
and false_negative_review/. Full/ROI/left_right/overlap use 1/1/2/4 invokes per image.
No production setting was selected automatically.
