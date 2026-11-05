"""Desktop human person-box annotation. Tk is optional and never imported by Pi runtime."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from .image_inference import _write_json
from .images import load_rgb_image
from .person_labels import new_labels, validate_labels


def edit_labels(input_folder: Path, label_path: Path, labels: dict) -> None:
    # Tkinter is in standard Windows Python; no new Pi runtime dependency.
    import tkinter as tk
    from tkinter import messagebox, ttk

    from PIL import ImageTk

    root = tk.Tk()
    root.title("Classroom person labels - human annotation only")
    index = 0
    start = None
    preview = None
    photo = None
    source = None
    annotations = []
    image = labels["images"][0]
    name = tk.StringVar()
    status = tk.StringVar()
    zoom = tk.DoubleVar(value=0.4)
    flags = {key: tk.BooleanVar() for key in ("uncertain", "partial", "seated")}
    toolbar = ttk.Frame(root)
    toolbar.pack(fill="x")
    ttk.Label(toolbar, text="Reviewer:").pack(side="left")
    ttk.Entry(toolbar, textvariable=name, width=20).pack(side="left")
    for key, var in flags.items():
        ttk.Checkbutton(toolbar, text=key, variable=var).pack(side="left")
    ttk.Label(
        root,
        text=(
            "Drag a box around VISIBLE person pixels (including partial bodies). "
            "Do not infer hidden limbs. Mark unclear/heavily occluded people uncertain. "
            "Review every image, including empty ones."
        ),
    ).pack(fill="x")
    frame = ttk.Frame(root)
    frame.pack(fill="both", expand=True)
    canvas = tk.Canvas(frame, width=1100, height=650, background="#222222")
    horizontal = ttk.Scrollbar(frame, orient="horizontal", command=canvas.xview)
    vertical = ttk.Scrollbar(frame, orient="vertical", command=canvas.yview)
    canvas.configure(xscrollcommand=horizontal.set, yscrollcommand=vertical.set)
    canvas.grid(row=0, column=0, sticky="nsew")
    vertical.grid(row=0, column=1, sticky="ns")
    horizontal.grid(row=1, column=0, sticky="ew")
    frame.rowconfigure(0, weight=1)
    frame.columnconfigure(0, weight=1)
    listing = tk.Listbox(frame, width=34, exportselection=False)
    listing.grid(row=0, column=2, sticky="ns")
    controls = ttk.Frame(root)
    controls.pack(fill="x")
    ttk.Label(root, textvariable=status).pack(fill="x")

    def save():
        _write_json(label_path, labels)

    def dirty():
        image.update(reviewed=False, reviewed_by="")
        save()

    def draw():
        nonlocal photo
        scale = zoom.get()
        resized = source.resize(
            (max(1, round(source.width * scale)), max(1, round(source.height * scale)))
        )
        photo = ImageTk.PhotoImage(resized)
        canvas.delete("all")
        canvas.create_image(0, 0, image=photo, anchor="nw")
        canvas.configure(scrollregion=(0, 0, resized.width, resized.height))
        listing.delete(0, "end")
        for a in annotations:
            x, y, w, h = a["bbox"]
            color = "orange" if a["attributes"]["uncertain"] else "lime"
            canvas.create_rectangle(
                x * scale, y * scale, (x + w) * scale, (y + h) * scale, outline=color, width=2
            )
            canvas.create_text(
                x * scale + 3, y * scale + 3, text=str(a["id"]), fill=color, anchor="nw"
            )
            attrs = ",".join(k for k, v in a["attributes"].items() if v)
            listing.insert("end", f"{a['id']}: {attrs or 'person'}")
        status.set(
            f"{index + 1}/{len(labels['images'])}  {image['file_name']}  "
            f"boxes={len(annotations)}  reviewed={image['reviewed']}  "
            "Autosaved; edits clear review status. Use zoom + scroll for back rows."
        )

    def load():
        nonlocal image, source, annotations
        image = labels["images"][index]
        source = load_rgb_image(input_folder / image["file_name"]).image
        annotations = [a for a in labels["annotations"] if a["image_id"] == image["id"]]
        draw()
        canvas.xview_moveto(0)
        canvas.yview_moveto(0)

    def navigate(offset):
        nonlocal index
        index = max(0, min(len(labels["images"]) - 1, index + offset))
        load()

    def point(event):
        return (
            max(0, min(image["width"], canvas.canvasx(event.x) / zoom.get())),
            max(0, min(image["height"], canvas.canvasy(event.y) / zoom.get())),
        )

    def press(event):
        nonlocal start, preview
        start = point(event)
        preview = canvas.create_rectangle(
            *(v * zoom.get() for v in (*start, *start)), outline="cyan", width=2
        )

    def move(event):
        if start is not None:
            canvas.coords(preview, *(v * zoom.get() for v in (*start, *point(event))))

    def release(event):
        nonlocal start
        if start is None:
            return
        end = point(event)
        x, y = min(start[0], end[0]), min(start[1], end[1])
        w, h = abs(end[0] - start[0]), abs(end[1] - start[1])
        start = None
        if min(w, h) >= 2:
            annotation = {
                "id": max((a["id"] for a in labels["annotations"]), default=0) + 1,
                "image_id": image["id"],
                "category_id": 1,
                "bbox": [x, y, w, h],
                "area": w * h,
                "iscrowd": 0,
                "attributes": {k: v.get() for k, v in flags.items()},
            }
            labels["annotations"].append(annotation)
            annotations.append(annotation)
            dirty()
        draw()

    def selected(_event=None):
        if listing.curselection():
            a = annotations[listing.curselection()[0]]
            for key, var in flags.items():
                var.set(a["attributes"][key])

    def update():
        if listing.curselection():
            a = annotations[listing.curselection()[0]]
            a["attributes"] = {k: v.get() for k, v in flags.items()}
            dirty()
            draw()

    def delete():
        if listing.curselection():
            a = annotations.pop(listing.curselection()[0])
            labels["annotations"].remove(a)
            dirty()
            draw()

    def review():
        if not name.get().strip():
            messagebox.showerror("Reviewer required", "Enter the human reviewer's name first.")
            return
        image.update(reviewed=True, reviewed_by=name.get().strip())
        save()
        draw()

    canvas.bind("<ButtonPress-1>", press)
    canvas.bind("<B1-Motion>", move)
    canvas.bind("<ButtonRelease-1>", release)
    listing.bind("<<ListboxSelect>>", selected)
    for text, command in (
        ("Previous", lambda: navigate(-1)),
        ("Next", lambda: navigate(1)),
        ("Apply flags to selected", update),
        ("Delete selected", delete),
        ("Mark image reviewed", review),
    ):
        ttk.Button(controls, text=text, command=command).pack(side="left")
    ttk.Label(controls, text="Zoom:").pack(side="left")
    ttk.Scale(controls, from_=0.15, to=1.5, variable=zoom, command=lambda _value: draw()).pack(
        side="left", fill="x", expand=True
    )
    load()
    root.mainloop()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--labels", type=Path, required=True)
    parser.add_argument("--init-only", action="store_true")
    args = parser.parse_args(argv)
    try:
        inventory = new_labels(args.input)
        if args.labels.exists():
            labels = json.loads(args.labels.read_text(encoding="utf-8"))
            validate_labels(labels, inventory["images"])
        else:
            labels = inventory
            args.labels.parent.mkdir(parents=True, exist_ok=True)
            _write_json(args.labels, labels)
        if not args.init_only:
            edit_labels(args.input, args.labels, labels)
        print(
            f"Human labels: {args.labels}; reviewed "
            f"{sum(i['reviewed'] for i in labels['images'])}/{len(labels['images'])}"
        )
        return 0
    except (OSError, ValueError, ImportError) as exc:
        parser.exit(1, f"Annotation error: {exc}\n")


if __name__ == "__main__":
    raise SystemExit(main())
