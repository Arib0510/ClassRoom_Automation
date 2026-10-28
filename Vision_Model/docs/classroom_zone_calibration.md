# Phase 3B: physical classroom zone calibration

The offline calibration utility is implemented. **Physical calibration has not
been completed.** The supplied photographs illustrate the editor and may differ
from the final mounted camera. Both `config/zones.yaml` and the new
`config/calibration.example.yaml` remain `calibrated:false`.

The four stable appliance owners are `front_left`, `front_right`, `back_left`
and `back_right`. Left/right mean an observer at the front facing the back. These
are physical ownership areas; fans and other appliances are not occupancy masks.

## Open the photo illustration

From the repository root on Windows, using the existing lightweight environment:

```powershell
.\.venv\Scripts\python.exe -m src.calibrate_zones edit --image sample_images/IMG_20261013_133640.jpg --calibration outputs/phase3b_calibration/calibration.example.yaml --preview outputs/phase3b_calibration/calibration.preview.png
```

The checked-in [example YAML](../config/calibration.example.yaml) also works as
the `--calibration` argument. Edit a local copy to preserve that template. Windows
Python's optional standard Tk support and Pillow provide the desktop editor;
the Pi runtime does not import Tk and gains no dependency. No local server or
external service is involved.

![Illustrative seat-region and floor-plan correspondence](../outputs/phase3b_calibration/calibration.preview.png)

The example shows four **incomplete, illustrative** seat/bench anchor regions,
two illustrative seating-row lines, and a ceiling exclusion. Matching colors
link each image region to its appliance owner on the floor plan. The floor-plan
quadrants are an editable physical-coordinate template, not four image sections.
No floor homography or measured seat positions are claimed for this photograph.
Its floor markers are illustrative. The two person-shaped boxes and ceiling box
are manually specified **UI probes**, not model detections or ground-truth labels.
Their results are `PREVIEW back_left`, `PREVIEW front_right` and `UNKNOWN
excluded_nonoccupancy_region` respectively.

Saved example outputs: YAML and JSON calibration documents, the PNG preview and
[preview report](../outputs/phase3b_calibration/calibration.preview.json), under
`outputs/phase3b_calibration/`. Recreate the illustration in a new empty directory:

```powershell
.\.venv\Scripts\python.exe -m src.calibrate_zones example --image sample_images/IMG_20261013_133640.jpg --output outputs/phase3b_example_new
```

## Editor controls

| Mode/control | Action |
| --- | --- |
| Seating row | Set an ID; click 2–12 points along the actual bench row in the image; Finish |
| Seat region | Enter a unique ID, an existing Row ID and appliance zone; click 3–12 convex vertices around the expected seated upper-body **anchor area**; Finish |
| Map selected seat | Select an existing seat in the list, choose its zone/row, then apply; changing zone clears its old optional floor marker |
| Seat floor marker | Select a seat; click its physical position on the floor plan; marker must lie inside its appliance zone |
| Excluded region | Mark ceiling, fan, window or wall areas that could overlap an occupancy anchor mask; exclusions take precedence |
| Floor zone | Select the appliance zone; mark its physical boundary on the **floor plan**; Finish |
| Image zone outline | Optional manually drawn zone outline for image explanation; display only, never a fallback assignment mask |
| Floor landmark | Click the image landmark, then its matching floor-plan position; explicitly attest whether both points are on the floor plane |
| Assignment box | Drag a person-shaped box on the image; see the configured anchor cross, candidate owner or UNKNOWN reason |
| Ground probe | Click a verified floor-contact point; used only by ground-plane assignment, never derived from a person box |
| Move vertex | Select a saved region/row in the list, choose this mode, then drag a vertex; invalid geometry is rejected |
| Assignment settings | Validated JSON dialog: method, anchor fraction, margins, exact measured coordinates, bulk boundary edits and notes |
| Preview + export | Save current PNG/JSON and record that this exact geometry has been previewed |
| Save + backup | Atomic YAML/JSON save, increment revision, preserve previous bytes in a content-addressed sibling backup folder |
| Undo | Restore geometry from the last 30 edit states; always clear manual confirmation |
| Manual confirmation | Mounted-reference workflow only; requires current preview, reviewer, explicit phrase and applicable on-site attestations |

Use scrollbars and zoom to reach both panels. A floor landmark has a stable ID on
both views. To correct a landmark pair, delete and recreate it, or use exact
coordinates in Assignment settings. To edit an image zone outline, redraw it.
Floor-zone polygons cannot overlap; shrink a neighboring region before expanding
another, or edit both boundaries together in the JSON dialog. Seat regions can
overlap in a draft, but a probe in multiple regions returns UNKNOWN, even when
the regions share an appliance owner.

Geometry changes clear approval and the current-preview record. Changing settings
cannot change the reference identity: create a new document for another frame,
camera pose or flip configuration. Closing prompts for a draft save; there is no
implicit final confirmation. Invalid edits preserve the previous document.
Previews cannot overwrite the source reference or the calibration/JSON sidecar.

## Procedure after mounting the actual Pi Camera

1. Mount the front-ceiling camera facing the classroom back. Fix the lens, sensor
   mode, resolution, aspect ratio, framing/crop, flips and physical pose. Record
   a camera ID and a pose ID. Obtain a reference RGB frame using the **same
   `camera.py` video configuration** that will deliver detections (currently
   640x480). Capture is a separate, intentional on-site operation; the editor
   never opens a camera. A differently cropped `rpicam-still` photograph is not
   an interchangeable reference. Do not resize, rotate or crop the frame afterward.
2. Copy that frame to the desktop. Start a new mounted-reference draft. The
   following uses a future example filename; it was **not run on hardware**:

   ```powershell
   .\.venv\Scripts\python.exe -m src.calibrate_zones init --image captures/pi_reference.png --calibration config/pi_camera.local.yaml --mounted-reference --camera-id classroom-pi-camera --pose-id front-ceiling-v1
   .\.venv\Scripts\python.exe -m src.calibrate_zones edit --image captures/pi_reference.png --calibration config/pi_camera.local.yaml
   ```

   Add `--hflip`/`--vflip` at initialization only if those match the actual camera
   configuration. Source dimensions, original-byte SHA256, source kind and camera
   identity are stored. The known supplied photos, including byte-identical
   copies, are refused as mounted references by this utility.
3. Physically identify the appliance ownership boundaries. Use actual seating
   rows and floor landmarks, and record which benches are served by each appliance
   zone. Edit the floor-plan template to those boundaries; equal physical halves
   are only a starting template. Floor coordinates are normalized physical width
   and depth: x=0 left, x=1 right, y=0 front, y=1 back. Where measured, use
   x=lateral distance/room width and y=depth from front/room depth; retain measured
   dimensions and landmark descriptions in notes. Image coordinates are separate
   normalized x/y with top-left origin. Never assume physical left matches image
   left without checking camera orientation.
4. Prefer **seat_regions** for seated students with hidden feet. Mark actual row
   lines and a separate convex region for each seat/bench's expected upper-body
   anchor locations. A region describes where the assignment anchor can appear;
   it is not a floor contact patch, nor automatically the desk's visible top.
   Map every monitored seat to an appliance zone. Use several convex regions for
   separated benches. Leave irrelevant ceiling, walls, windows and fans outside
   these regions; add exclusions wherever necessary. A gap returns UNKNOWN.
5. Check the configurable anchor with representative seated, standing, partial
   and occluded boxes at every bench and boundary. The initial fraction `[0.5,0.25]`
   means horizontal center and one-quarter down the **observed** box. It is a
   tunable upper-body heuristic, not a head detector or physical position proof.
   A box bottom on a desk is never treated as floor contact. The default safety
   margin is four **reference-image pixels** from a seat-region edge; adjust it
   with evidence at the real runtime resolution. Multiple hits, exclusions,
   boundary margins and uncovered locations must visibly produce UNKNOWN.
6. Optionally use the homography workflow below for verified floor-contact data.
   Do not choose it merely because person bounding boxes are available.
7. Export the current preview and check **every seat/zone/anchor** with the room
   layout. In Manual confirmation enter the reviewer name and type
   `CONFIRM MOUNTED CAMERA CALIBRATION`. Confirm final mounted framing, physical
   appliance ownership, anchor behavior and exclusions, plus seat coverage or
   floor correspondences for the selected method. These attestations start
   unchecked. The confirmation stores UTC time and a digest of the geometry and
   reference. The tool refuses illustrative references and incomplete checks.
8. Keep appliance control disabled during these steps. After physical review,
   point a local application config's existing `zones_path` at the confirmed
   version-2 file and run the read-only config check. **This phase does not start
   `run`, MQTT, a service or any appliances.** Further camera/model/controller
   commissioning remains separate. Moving the camera, changing framing, lens,
   flips or seating invalidates the physical review even when pixel dimensions
   happen to stay the same; create a new reference/pose record and repeat.

The legacy `config/zones.yaml` remains readable for historical tests/overlays but
is not the commissioning format. Live mode now requires both `calibrated:true`
and a valid version-2 mounted-reference confirmation. Flipping the legacy boolean
cannot commission the example orange polygons. The active default remains false.

## Optional ground-plane homography

Mark **at least four** corresponding, distinct floor points with non-degenerate
geometry in both coordinate systems. Spread them across the monitored area; do
not use four points along one aisle, or bench tops, wall corners above the floor,
ceiling fixtures or student bodies. Enter measured normalized floor coordinates
precisely in Assignment settings. More independently measured points are preferred.
Set each correspondence's `on_floor:true` only after physical verification.

NumPy normalized DLT fits image-to-floor and inverse matrices. The implementation
checks rank, conditioning, invertibility, horizons and inverse reprojection error
in reference pixels (default maximum 3 px). It reports reference count, maximum
error and RMS error in preview JSON. Four points can fit perfectly while being
physically wrong; low reprojection error is not calibration acceptance. The model
assumes a planar floor and consistent lens/rendering geometry; lens distortion
and incorrect correspondences are not automatically corrected.

Choose `assignment.method: ground_plane` to test verified floor-contact points.
The API requires a `GroundPoint(image_xy, provenance, uncertainty_px)` with
`manual_floor_contact` or `external_floor_estimate` provenance. It rejects
`bbox_bottom` provenance. With only a seated-person box it returns
`UNKNOWN explicit_ground_contact_required`.

Ground assignment stays inside the measured landmark hull, includes pixel
uncertainty and a physical normalized boundary margin (default 0.01), and never
extrapolates to a zone outside that domain. Floor-zone outlines are clipped to
the measured domain before being projected onto the reference image. Points near
zone boundaries, outside the domain or with uncertainty crossing a boundary
remain UNKNOWN. No nearest-zone fallback or shared-edge priority is used.

The live detector currently supplies boxes, **not verified ground contacts**.
Thus ground-plane mode alone cannot automatically locate seated students in that
pipeline; person observations remain UNKNOWN until an independently reviewed
ground-contact source is provided. Seat-region mode is the implemented box-based
alternative. No pose/foot estimator, depth model or camera hardware was added.

## Runtime and file semantics

`src/calibration_geometry.py` contains convex geometry and homography math;
`src/calibration.py` validates versioned documents and locates people;
`src/calibration_preview.py` renders the two coordinate systems;
`src/calibrate_zones.py` provides the offline editor and CLI. Model preprocessing,
crop ROIs and occupancy geometry are independent. All input boxes must already
be normalized to the **full oriented frame**, including any crop reprojection.

`schema_version:2` files save the original reference hash/dimensions/kind, camera
ID and pose ID/flips, four physical floor polygons, optional image outlines,
seat-to-appliance ownership, row polylines, floor landmarks and verification flags,
exclusions, anchor/margin settings, revision and confirmation metadata. Homography
matrices are recomputed from those saved correspondences, not loaded as an
unreviewed independent transform. YAML and JSON round trips are tested. Each save
preserves previous bytes under `<filename>.backups/<sha256>.<extension>`. Backups
are recoverable documents; after a physical setup change, clear/review approval
before using restored geometry. Undo never restores a previous approval.

The assignment API returns `assigned`, `unknown` or a draft-only `preview`
candidate, with reason, optional zone/seat ID, image anchor and floor anchor.
Unconfirmed geometry and mismatched frames cannot provide occupancy counts.
An unresolved person is **not discarded as a valid zero**: the live integration
conservatively resets all four zones to UNKNOWN, clears counts/last observation,
and waits for reliable observations to reconfirm. This can reduce availability
when a false detection or person in an unmapped aisle appears; it avoids asserting
vacancy for an unlocatable person. Detector misses still require the separate
Phase 3A accuracy work. Existing freshness/expiry, debounce and bounded buffering
are preserved. Camera dimensions/flips are checked before runtime creation;
physical camera motion still requires manual revalidation.

`ZoneMap.load` dispatches version-2 files while preserving the legacy reader.
Offline inference can render version-2 overlays only for its exact hash-bound
reference; other photos are rejected rather than silently receiving that geometry.
The original model/weights, crop preprocessing, Pi requirements, camera code,
MQTT code and occupancy state machine are unchanged. The new unknown-observation
handling is in the application wiring. Nothing is automatically published or
copied into the active application config.

## Validation and remaining work

Software tests cover convex/invalid polygons, coordinate transforms, four and
six-point homographies, degeneracy and bad correspondences, clipping, floor
uncertainty, seat ownership and ambiguous boundaries, exclusions, serialization,
revisions/backups/undo, confirmation digests/checks, reference hash protection,
frame/flip mismatches, legacy safety and unknown occupancy integration.
The actual Tk editor was constructed/rendered **hidden** and exercised through
box-drag coordinates, preview export, seat remapping, undo and save/backup.
Interactive operator acceptance and physical calibration remain pending.

Required software validation results and the artifact hashes are recorded in
`outputs/phase3b_calibration/validation_evidence.json`. The commands are:

```powershell
.\.venv\Scripts\python.exe -m pytest
.\.venv\Scripts\python.exe -m ruff check .
.\.venv\Scripts\python.exe -m ruff format --check .
.\.venv\Scripts\python.exe scripts/check_environment.py --static
```

Results on this Windows software host: **224 passed, 3 deliberately skipped**;
Ruff check passed, all 37 Python files passed formatting, and the static
environment/model checks passed. The existing 158 lightweight tests still pass;
66 geometry/calibration cases were added. The source model, supplied photographs,
Pi requirements, camera/occupancy/MQTT modules and active YAML settings retain
their Phase 3A hashes.

The existing opt-in model inference tests are skipped in this lightweight
calibration run. No camera was accessed, inference/latency benchmark run, MQTT
connection made, model trained/replaced, ESP32 operated or appliance energized.
Software geometry validation is not evidence of camera, detection accuracy,
physical-zone accuracy, latency or hardware validation.
