"""Offline classroom geometry editor. Never starts camera, inference, MQTT or appliances."""

from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path

from .calibration import (
    CHECKS,
    CONFIRMATION_PHRASE,
    CalibrationSession,
    GroundPoint,
    PhysicalCalibration,
    file_hash,
    load_calibration,
    new_document,
)
from .calibration_preview import FLOOR_RECT, image_rect, inverse_view, render_preview, view_point
from .config import REPO_ROOT
from .images import load_rgb_image


def reference_record(
    path: Path, *, mounted=False, camera_id="", pose_id="", hflip=False, vflip=False
) -> dict:
    loaded = load_rgb_image(path)
    digest = file_hash(path)
    if mounted and any(file_hash(p) == digest for p in (REPO_ROOT / "sample_images").glob("*.jpg")):
        raise ValueError(
            "Supplied classroom photographs are illustrative, not mounted Pi references"
        )
    return {
        "file_name": path.name,
        "sha256": digest,
        "width": loaded.image.width,
        "height": loaded.image.height,
        "kind": "mounted_pi" if mounted else "illustrative",
        "camera_id": camera_id,
        "pose_id": pose_id,
        "hflip": hflip,
        "vflip": vflip,
    }


def example_document(path: Path) -> tuple[dict, list[tuple]]:
    data = new_document(reference_record(path))
    data["metadata"].update(
        title="Illustrative seat-to-appliance mapping",
        notes="Photo-specific UI illustration only. Regions and floor-plan markers "
        "are unmeasured drafts. Recreate after mounting the Pi camera.",
    )
    data["seating_rows"] = [
        {
            "id": "rear_row_demo",
            "image_points": [[0.36, 0.65], [0.71, 0.65]],
            "notes": "Illustrative rear bench row",
        },
        {
            "id": "near_row_demo",
            "image_points": [[0.06, 0.91], [0.98, 0.91]],
            "notes": "Illustrative near bench row",
        },
    ]
    shapes = {
        "front_left": [[0.09, 0.73], [0.40, 0.73], [0.43, 0.90], [0.03, 0.90]],
        "front_right": [[0.84, 0.72], [0.98, 0.72], [0.98, 0.90], [0.81, 0.90]],
        "back_left": [[0.39, 0.53], [0.49, 0.53], [0.49, 0.64], [0.37, 0.64]],
        "back_right": [[0.55, 0.53], [0.65, 0.53], [0.69, 0.64], [0.55, 0.64]],
    }
    for zone_id, vertices in shapes.items():
        front, left = zone_id.startswith("front"), zone_id.endswith("left")
        data["seat_regions"].append(
            {
                "id": f"{zone_id}_bench_demo",
                "row_id": "near_row_demo" if front else "rear_row_demo",
                "zone_id": zone_id,
                "polygon": vertices,
                "floor_point": [0.25 if left else 0.75, 0.25 if front else 0.75],
            }
        )
    data["excluded_regions"] = [
        {"id": "ceiling_demo", "polygon": [[0, 0], [1, 0], [1, 0.43], [0, 0.43]]}
    ]
    # Deliberate UI probes, not model detections or human ground-truth annotations.
    boxes = [(0.56, 0.44, 0.64, 0.48), (0.73, 0.84, 0.89, 0.94), (0.15, 0.20, 0.30, 0.30)]
    return data, boxes


def write_preview(
    data: dict, image_path: Path, output: Path, *, boxes=(), ground_points=(), calibration_path=None
) -> dict:
    if output.suffix.lower() != ".png":
        raise ValueError("Preview output must be a separate PNG file")
    destinations = {output.resolve(), output.with_suffix(".json").resolve()}
    if image_path.resolve() in destinations or (
        calibration_path is not None and calibration_path.resolve() in destinations
    ):
        raise ValueError("Preview files must not overwrite the reference or calibration")
    calibration = PhysicalCalibration(data)
    calibration.verify_reference(image_path)
    image, report = render_preview(
        calibration, load_rgb_image(image_path).image, boxes, tuple(ground_points)
    )
    output.parent.mkdir(parents=True, exist_ok=True)
    image.save(output, format="PNG")
    output.with_suffix(".json").write_text(
        json.dumps(report, indent=2, allow_nan=False) + "\n", encoding="utf-8"
    )
    return report


class CalibrationEditor:
    """Two linked canvases: reference image and normalized physical floor plan."""

    def __init__(self, root, image_path: Path, calibration_path: Path, preview_path: Path):
        import tkinter as tk
        from tkinter import messagebox, simpledialog, ttk

        from PIL import ImageTk

        self.tk, self.ttk = tk, ttk
        self.messagebox, self.simpledialog = messagebox, simpledialog
        self.ImageTk = ImageTk
        self.root, self.image_path, self.path, self.preview_path = (
            root,
            image_path,
            calibration_path,
            preview_path,
        )
        calibration = load_calibration(calibration_path)
        calibration.verify_reference(image_path)
        self.session = CalibrationSession(calibration.to_dict())
        self.reference = load_rgb_image(image_path).image
        self.pending = []
        self.pending_landmark = None
        self.probes = []
        self.ground_probes = []
        self.drag = None
        self.drag_data = None
        self.selection_keys = []
        self.photo = None
        self.mode = tk.StringVar(value="seat region")
        self.identifier = tk.StringVar(value="seat_01")
        self.row_id = tk.StringVar(value="row_01")
        self.zone_id = tk.StringVar(value="front_left")
        self.status = tk.StringVar()
        self.zoom = tk.DoubleVar(value=0.8)
        root.title("Physical classroom calibration - OFFLINE; control disabled")
        toolbar = ttk.Frame(root)
        toolbar.pack(fill="x")
        ttk.Combobox(
            toolbar,
            textvariable=self.mode,
            width=19,
            state="readonly",
            values=(
                "seat region",
                "seating row",
                "excluded region",
                "image zone outline",
                "floor zone",
                "floor landmark",
                "assignment box",
                "ground probe",
                "seat floor marker",
                "move vertex",
            ),
        ).pack(side="left")
        for text, variable, width in (("ID", self.identifier, 20), ("Row", self.row_id, 17)):
            ttk.Label(toolbar, text=text).pack(side="left")
            ttk.Entry(toolbar, textvariable=variable, width=width).pack(side="left")
        ttk.Combobox(
            toolbar,
            textvariable=self.zone_id,
            values=tuple(
                shapes_id for shapes_id in ("front_left", "front_right", "back_left", "back_right")
            ),
            state="readonly",
            width=15,
        ).pack(side="left")
        ttk.Label(
            root,
            text=(
                "Click vertices, then Finish. Rows need 2+ points. "
                "Landmark: click IMAGE, then matching FLOOR point. "
                "Assignment box: drag. Select a saved item + Move vertex to adjust it."
            ),
        ).pack(fill="x")
        body = ttk.Frame(root)
        body.pack(fill="both", expand=True)
        self.canvas = tk.Canvas(body, width=1160, height=720, background="#111923")
        vertical = ttk.Scrollbar(body, orient="vertical", command=self.canvas.yview)
        horizontal = ttk.Scrollbar(body, orient="horizontal", command=self.canvas.xview)
        self.canvas.configure(yscrollcommand=vertical.set, xscrollcommand=horizontal.set)
        self.canvas.grid(row=0, column=0, sticky="nsew")
        vertical.grid(row=0, column=1, sticky="ns")
        horizontal.grid(row=1, column=0, sticky="ew")
        body.rowconfigure(0, weight=1)
        body.columnconfigure(0, weight=1)
        self.listing = tk.Listbox(body, width=38, exportselection=False)
        self.listing.grid(row=0, column=2, sticky="ns")
        self.listing.bind("<<ListboxSelect>>", self.select)
        controls = ttk.Frame(root)
        controls.pack(fill="x")
        for text, callback in (
            ("Finish", self.finish),
            ("Clear points/probes", self.clear),
            ("Delete selected", self.delete),
            ("Map selected seat", self.map_seat),
            ("Undo", self.undo),
            ("Assignment settings", self.settings),
            ("Save + backup", self.save),
            ("Preview + export", self.preview),
            ("Manual confirmation", self.confirm),
        ):
            button = ttk.Button(controls, text=text, command=lambda call=callback: self.guard(call))
            button.pack(side="left")
            if (
                text == "Manual confirmation"
                and self.session.data["reference"]["kind"] == "illustrative"
            ):
                button.configure(state="disabled")
        ttk.Scale(
            controls, from_=0.4, to=1.2, variable=self.zoom, command=lambda _: self.draw()
        ).pack(side="left", fill="x", expand=True)
        ttk.Label(root, textvariable=self.status, wraplength=1400).pack(fill="x")
        self.canvas.bind("<ButtonPress-1>", self.press)
        self.canvas.bind("<B1-Motion>", self.motion)
        self.canvas.bind("<ButtonRelease-1>", self.release)
        self.mode.trace_add("write", lambda *_: self.clear())
        self.draw()
        root.protocol("WM_DELETE_WINDOW", self.close)

    def guard(self, call):
        try:
            call()
        except (ValueError, OSError, KeyError) as exc:
            self.messagebox.showerror("Calibration", str(exc))

    def draw(self):
        if not hasattr(self, "listing"):
            return
        selected = self.listing.curselection()
        selected_key = self.selection_keys[selected[0]] if selected else None
        calibration = PhysicalCalibration(self.session.data)
        image, _ = render_preview(
            calibration, self.reference, self.probes, tuple(self.ground_probes)
        )
        scale = self.zoom.get()
        image = image.resize((round(image.width * scale), round(image.height * scale)))
        self.photo = self.ImageTk.PhotoImage(image)
        self.canvas.delete("all")
        self.canvas.create_image(0, 0, anchor="nw", image=self.photo)
        self.canvas.configure(scrollregion=(0, 0, image.width, image.height))
        self.listing.delete(0, "end")
        self.selection_keys = []
        for group in (
            "appliance_zones",
            "seating_rows",
            "seat_regions",
            "excluded_regions",
            "floor_landmarks",
        ):
            for i, entry in enumerate(self.session.data[group]):
                self.selection_keys.append((group, i))
                self.listing.insert("end", f"{group}: {entry['id']}")
        if selected_key in self.selection_keys:
            self.listing.selection_set(self.selection_keys.index(selected_key))
        self.draw_pending()
        self.status.set(
            f"calibrated={calibration.calibrated}; "
            f"source={self.session.data['reference']['kind']}; "
            f"method={self.session.data['assignment']['method']}; "
            f"{calibration.homography_error or 'Homography computed'}; "
            "illustrative photos cannot be confirmed. "
            "Save writes a backup; edits/undo clear approval."
        )

    def draw_pending(self):
        self.canvas.delete("pending")
        floor = self.mode.get() == "floor zone"
        rect = FLOOR_RECT if floor else image_rect(self.reference.size)
        pixels = [view_point(p, rect, floor=floor) for p in self.pending]
        if self.pending_landmark:
            pixels.append(view_point(self.pending_landmark, image_rect(self.reference.size)))
        scale = self.zoom.get()
        for x, y in pixels:
            self.canvas.create_oval(
                (x - 4) * scale,
                (y - 4) * scale,
                (x + 4) * scale,
                (y + 4) * scale,
                fill="yellow",
                tags="pending",
            )
        if len(pixels) > 1:
            self.canvas.create_line(
                *(v * scale for p in pixels for v in p), fill="yellow", width=2, tags="pending"
            )

    def coordinates(self, event):
        p = (
            self.canvas.canvasx(event.x) / self.zoom.get(),
            self.canvas.canvasy(event.y) / self.zoom.get(),
        )
        return (
            p,
            inverse_view(p, image_rect(self.reference.size)),
            inverse_view(p, FLOOR_RECT, floor=True),
        )

    def press(self, event):
        self.guard(lambda: self._press(event))

    def _press(self, event):
        pixel, image_point, floor_point = self.coordinates(event)
        mode = self.mode.get()
        if mode == "move vertex":
            self.begin_vertex_drag(pixel)
            return
        if mode == "assignment box":
            self.drag = image_point
            return
        if mode == "ground probe" and image_point:
            self.ground_probes.append(GroundPoint(image_point, "manual_floor_contact"))
            self.draw()
            return
        if mode == "seat floor marker" and floor_point:
            selected = self.listing.curselection()
            if not selected or self.selection_keys[selected[0]][0] != "seat_regions":
                raise ValueError("Select a seat region before marking its floor-plan position")
            data = copy.deepcopy(self.session.data)
            seat = data["seat_regions"][self.selection_keys[selected[0]][1]]
            seat["floor_point"] = list(floor_point)
            self.session.replace(data)
            self.draw()
            return
        if mode == "floor landmark":
            if image_point:
                self.pending_landmark = image_point
            elif floor_point and self.pending_landmark:
                data = copy.deepcopy(self.session.data)
                on_floor = self.messagebox.askyesno(
                    "Floor landmark",
                    "Are BOTH points verified correspondences on the FLOOR plane?\n"
                    "Do not use a desk edge, bench top, wall or fan.",
                )
                data["floor_landmarks"].append(
                    {
                        "id": self.identifier.get(),
                        "image": list(self.pending_landmark),
                        "floor": list(floor_point),
                        "on_floor": on_floor,
                    }
                )
                self.session.replace(data)
                self.pending_landmark = None
                self.draw()
            self.draw_pending()
            return
        p = floor_point if mode == "floor zone" else image_point
        if p:
            self.pending.append(p)
            self.draw_pending()

    def begin_vertex_drag(self, pixel):
        selected = self.listing.curselection()
        if not selected:
            raise ValueError("Select a geometry item in the list first")
        group, index = self.selection_keys[selected[0]]
        item = self.session.data[group][index]
        floor = group == "appliance_zones"
        key = (
            "floor_polygon" if floor else ("image_points" if group == "seating_rows" else "polygon")
        )
        if group == "floor_landmarks":
            raise ValueError("Delete and recreate a landmark pair to change its correspondence")
        vertices = item[key]
        rect = FLOOR_RECT if floor else image_rect(self.reference.size)
        distances = [
            (
                sum(
                    (a - b) ** 2
                    for a, b in zip(view_point(p, rect, floor=floor), pixel, strict=True)
                ),
                i,
            )
            for i, p in enumerate(vertices)
        ]
        distance, vertex = min(distances)
        if distance <= 20**2:
            self.drag_data = copy.deepcopy(self.session.data)
            self.drag = (group, index, key, vertex, floor)

    def motion(self, event):
        if self.mode.get() == "move vertex" and self.drag is not None:
            _, image_point, floor_point = self.coordinates(event)
            group, index, key, vertex, floor = self.drag
            p = floor_point if floor else image_point
            if p:
                self.drag_data[group][index][key][vertex] = list(p)
                self.canvas.delete("moving")
                rect = FLOOR_RECT if floor else image_rect(self.reference.size)
                pixels = [
                    view_point(p, rect, floor=floor) for p in self.drag_data[group][index][key]
                ]
                self.canvas.create_line(
                    *(v * self.zoom.get() for p in pixels + pixels[:1] for v in p),
                    fill="yellow",
                    width=3,
                    tags="moving",
                )

    def release(self, event):
        self.guard(lambda: self._release(event))

    def _release(self, event):
        if self.drag is None:
            return
        if self.mode.get() == "move vertex":
            candidate = self.drag_data
            self.drag = self.drag_data = None
            self.canvas.delete("moving")
            self.session.replace(candidate)
            self.draw()
        elif self.mode.get() == "assignment box":
            _, end, _ = self.coordinates(event)
            start, self.drag = self.drag, None
            if end:
                x0, x1 = sorted((start[0], end[0]))
                y0, y1 = sorted((start[1], end[1]))
                if min(x1 - x0, y1 - y0) > 0.001:
                    self.probes.append((y0, x0, y1, x1))
                    self.draw()

    def finish(self):
        data, mode = copy.deepcopy(self.session.data), self.mode.get()
        identifier, points = self.identifier.get().strip(), [list(p) for p in self.pending]
        if mode == "seat region":
            data["seat_regions"].append(
                {
                    "id": identifier,
                    "row_id": self.row_id.get().strip(),
                    "zone_id": self.zone_id.get(),
                    "polygon": points,
                    "floor_point": None,
                }
            )
        elif mode == "seating row":
            data["seating_rows"].append(
                {"id": identifier, "image_points": points, "notes": "Marked on reference image"}
            )
        elif mode == "excluded region":
            data["excluded_regions"].append({"id": identifier, "polygon": points})
        elif mode in ("floor zone", "image zone outline"):
            zone = next(z for z in data["appliance_zones"] if z["id"] == self.zone_id.get())
            zone["floor_polygon" if mode == "floor zone" else "image_polygon"] = points
        else:
            raise ValueError(
                "This mode uses paired clicks or dragging; choose a polygon/row mode to Finish"
            )
        self.session.replace(data)
        self.pending = []
        self.draw()

    def select(self, _event=None):
        selected = self.listing.curselection()
        if selected:
            group, index = self.selection_keys[selected[0]]
            item = self.session.data[group][index]
            self.identifier.set(item["id"])
            if "zone_id" in item:
                self.zone_id.set(item["zone_id"])
                self.row_id.set(item["row_id"])
            elif group == "appliance_zones":
                self.zone_id.set(item["id"])

    def delete(self):
        if self.listing.curselection():
            group, index = self.selection_keys[self.listing.curselection()[0]]
            if group == "appliance_zones":
                raise ValueError("Keep all four appliance zones; redraw its floor boundary instead")
            data = copy.deepcopy(self.session.data)
            data[group].pop(index)
            self.session.replace(data)
            self.draw()

    def map_seat(self):
        selected = self.listing.curselection()
        if not selected or self.selection_keys[selected[0]][0] != "seat_regions":
            raise ValueError(
                "Select a seat region, choose its appliance zone/row, then Map selected seat"
            )
        data = copy.deepcopy(self.session.data)
        seat = data["seat_regions"][self.selection_keys[selected[0]][1]]
        if seat["zone_id"] != self.zone_id.get():
            seat["floor_point"] = None  # A new zone mapping needs a newly checked floor marker.
        seat.update(zone_id=self.zone_id.get(), row_id=self.row_id.get().strip())
        self.session.replace(data)
        self.draw()

    def clear(self):
        self.pending, self.pending_landmark = [], None
        self.probes, self.ground_probes = [], []
        self.drag = self.drag_data = None
        self.draw()

    def undo(self):
        self.session.undo()
        self.pending, self.pending_landmark = [], None
        self.draw()

    def settings(self):
        # One editable JSON dialog also supports bulk shared-boundary edits and seat floor markers.
        window = self.tk.Toplevel(self.root)
        window.title("Calibration settings / geometry (edits clear manual confirmation)")
        text = self.tk.Text(window, width=105, height=36)
        text.pack(fill="both", expand=True)
        text.insert("1.0", json.dumps(self.session.data, indent=2))
        self.ttk.Label(
            window,
            text="Assignment: seat_regions or ground_plane. "
            "anchor_fraction=[x,y] inside person box. "
            "Seat region zone_id maps to an appliance; floor_point is optional. "
            "Reference identity is fixed.",
        ).pack()

        def apply():
            candidate = json.loads(text.get("1.0", "end"))
            if candidate["reference"] != self.session.data["reference"]:
                raise ValueError(
                    "Create a new calibration for another reference/camera pose or flips"
                )
            self.session.replace(candidate)
            self.draw()
            window.destroy()

        self.ttk.Button(
            window, text="Apply validated draft", command=lambda: self.guard(apply)
        ).pack()

    def save(self):
        self.session.save(self.path)
        self.draw()
        self.status.set(
            f"Saved revision {self.session.data['revision']}: {self.path}. "
            "Previous content backed up."
        )

    def preview(self):
        write_preview(
            self.session.data,
            self.image_path,
            self.preview_path,
            boxes=self.probes,
            ground_points=self.ground_probes,
            calibration_path=self.path,
        )
        self.session.mark_previewed()
        self.status.set(
            f"Current geometry preview exported: {self.preview_path}. "
            "Check every zone/seat/anchor before confirmation."
        )

    def confirm(self):
        window = self.tk.Toplevel(self.root)
        window.title("Explicit on-site manual confirmation")
        self.ttk.Label(
            window,
            text="Only for the FINAL MOUNTED Pi Camera frame. "
            "This does not enable MQTT or appliances.",
        ).pack()
        labels = {
            "mounted_frame": "Final mounted camera, framing/flips and camera/pose IDs checked",
            "zone_ownership": "All four appliance-zone boundaries and ownership verified on site",
            "anchors": "Seated/partial-person anchors and unknown boundaries checked on site",
            "exclusions": "Ceiling, fans, windows, walls excluded from occupancy assignment",
            "seat_regions": "Seat/bench regions cover monitored seating in all four zones",
            "floor_landmarks": "Measured FLOOR correspondences; no desks/walls (ground mode)",
        }
        checks = {key: self.tk.BooleanVar(value=False) for key in CHECKS}
        for key, variable in checks.items():
            self.ttk.Checkbutton(window, text=labels[key], variable=variable).pack(anchor="w")
        self.ttk.Label(window, text="Reviewer name:").pack()
        reviewer = self.ttk.Entry(window, width=50)
        reviewer.pack()
        self.ttk.Label(window, text=f"Type: {CONFIRMATION_PHRASE}").pack()
        phrase = self.ttk.Entry(window, width=55)
        phrase.pack()

        def apply():
            self.session.confirm(
                reviewer.get(), phrase.get(), {key: var.get() for key, var in checks.items()}
            )
            self.save()
            window.destroy()

        self.ttk.Button(
            window, text="Confirm current preview and save", command=lambda: self.guard(apply)
        ).pack()

    def close(self):
        if self.messagebox.askyesno(
            "Close editor", "Save the current calibration draft before closing?"
        ):
            try:
                self.save()
            except (OSError, ValueError) as exc:
                self.messagebox.showerror("Save failed", str(exc))
                return
        self.root.destroy()


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("init", "edit", "preview", "example"):
        command = sub.add_parser(name)
        command.add_argument("--image", type=Path, required=True)
        if name == "example":
            command.add_argument(
                "--output", type=Path, required=True, help="New/empty example directory"
            )
        else:
            command.add_argument("--calibration", type=Path, required=True)
        if name in ("edit", "preview"):
            command.add_argument("--preview", type=Path)
        if name == "init":
            command.add_argument("--mounted-reference", action="store_true")
            command.add_argument("--camera-id", default="")
            command.add_argument("--pose-id", default="")
            command.add_argument("--hflip", action="store_true")
            command.add_argument("--vflip", action="store_true")
        if name == "preview":
            command.add_argument(
                "--box",
                type=float,
                nargs=4,
                action="append",
                default=[],
                metavar=("YMIN", "XMIN", "YMAX", "XMAX"),
            )
            command.add_argument(
                "--ground", type=float, nargs=2, action="append", default=[], metavar=("X", "Y")
            )
    args = parser.parse_args(argv)
    try:
        if args.command == "init":
            if args.calibration.exists():
                raise ValueError("Initialization preserves existing calibration; use edit")
            ref = reference_record(
                args.image,
                mounted=args.mounted_reference,
                camera_id=args.camera_id,
                pose_id=args.pose_id,
                hflip=args.hflip,
                vflip=args.vflip,
            )
            CalibrationSession(new_document(ref)).save(args.calibration)
            print(f"Created UNCALIBRATED {ref['kind']} draft: {args.calibration}")
        elif args.command == "example":
            if args.output.exists() and (not args.output.is_dir() or any(args.output.iterdir())):
                raise ValueError("Example output must be new or empty")
            args.output.mkdir(parents=True, exist_ok=True)
            # These illustrative coordinates are specific to the documented example frame.
            expected = REPO_ROOT / "sample_images/IMG_20261013_133640.jpg"
            if file_hash(args.image) != file_hash(expected):
                raise ValueError(
                    "Example geometry requires sample_images/IMG_20261013_133640.jpg; "
                    "use init for other frames"
                )
            data, probes = example_document(args.image)
            for suffix in ("yaml", "json"):
                CalibrationSession(data).save(args.output / f"calibration.example.{suffix}")
            write_preview(data, args.image, args.output / "calibration.preview.png", boxes=probes)
            print(
                f"Illustration saved; calibrated:false. "
                f"Example probes are not detections: {args.output}"
            )
        else:
            calibration = load_calibration(args.calibration)
            calibration.verify_reference(args.image)
            preview_path = args.preview or args.calibration.with_suffix(".preview.png")
            if args.command == "preview":
                report = write_preview(
                    calibration.to_dict(),
                    args.image,
                    preview_path,
                    boxes=args.box,
                    ground_points=[
                        GroundPoint(tuple(p), "manual_floor_contact") for p in args.ground
                    ],
                    calibration_path=args.calibration,
                )
                print(json.dumps(report, indent=2, allow_nan=False))
            else:
                import tkinter as tk

                root = tk.Tk()
                CalibrationEditor(root, args.image, args.calibration, preview_path)
                root.mainloop()
        return 0
    except (ValueError, OSError, ImportError) as exc:
        parser.exit(1, f"Calibration error: {exc}\n")


if __name__ == "__main__":
    raise SystemExit(main())
