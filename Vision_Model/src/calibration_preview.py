"""Reference-bound image/physical-plan preview, independent of detection and camera I/O."""

from __future__ import annotations

from dataclasses import asdict

from PIL import Image, ImageDraw, ImageFont

from .calibration import GroundPoint, PhysicalCalibration, geometry_digest
from .calibration_geometry import convex_clip, project
from .zones import ZONE_IDS

COLORS = dict(zip(ZONE_IDS, ("#4fc3f7", "#ffb74d", "#81c784", "#ce93d8"), strict=True))
FLOOR_RECT = (1215, 120, 1575, 790)


def image_rect(size: tuple[int, int]) -> tuple:
    scale = min(1140 / size[0], 740 / size[1])
    return 20, 90, 20 + round(size[0] * scale), 90 + round(size[1] * scale)


def view_point(p: tuple, rect: tuple, *, floor=False) -> tuple:
    return rect[0] + p[0] * (rect[2] - rect[0]), rect[1] + (1 - p[1] if floor else p[1]) * (
        rect[3] - rect[1]
    )


def inverse_view(p: tuple, rect: tuple, *, floor=False) -> tuple | None:
    x, y = (p[0] - rect[0]) / (rect[2] - rect[0]), (p[1] - rect[1]) / (rect[3] - rect[1])
    if not (0 <= x <= 1 and 0 <= y <= 1):
        return None
    return x, 1 - y if floor else y


def render_preview(
    calibration: PhysicalCalibration,
    reference: Image.Image,
    boxes=(),
    ground_points: tuple[GroundPoint, ...] = (),
) -> tuple[Image.Image, dict]:
    if reference.size != calibration.reference_size:
        raise ValueError("Preview dimensions differ from calibration reference")
    data = calibration.to_dict()
    canvas = Image.new("RGB", (1600, 1000), "#111923")
    rect = image_rect(reference.size)
    canvas.paste(reference.resize((rect[2] - rect[0], rect[3] - rect[1])), rect[:2])
    draw = ImageDraw.Draw(canvas, "RGBA")
    try:
        font = ImageFont.truetype("arial.ttf", 15)
        title_font = ImageFont.truetype("arial.ttf", 23)
    except OSError:
        font = title_font = ImageFont.load_default()

    def text(x, y, value, color="white", *, title=False, max_width=None):
        selected_font = title_font if title else font
        if max_width is not None:
            shortened = value
            while shortened and draw.textlength(shortened, font=selected_font) > max_width:
                shortened = shortened[:-1]
            value = shortened[:-3] + "..." if shortened != value else value
        width = draw.textlength(value, font=selected_font)
        x = max(5, min(x, canvas.width - width - 5))
        bounds = draw.textbbox((x, y), value, font=selected_font)
        draw.rectangle(
            (bounds[0] - 3, bounds[1] - 2, bounds[2] + 3, bounds[3] + 2), fill=(12, 19, 28, 225)
        )
        draw.text((x, y), value, fill=color, font=selected_font)

    def region(vertices, target, color, label, *, floor=False, fill=True):
        if len(vertices) < 3:
            return
        pixels = [view_point(p, target, floor=floor) for p in vertices]
        rgb = tuple(bytes.fromhex(color.lstrip("#")))
        if fill:
            draw.polygon(pixels, fill=(*rgb, 48))
        draw.line(pixels + pixels[:1], fill=(*rgb, 255), width=3)
        center = tuple(sum(p[i] for p in pixels) / len(pixels) for i in (0, 1))
        if floor:
            center = min(p[0] for p in pixels) + 8, min(p[1] for p in pixels) + 10
            text(*center, label, color, max_width=max(p[0] for p in pixels) - center[0] - 8)
        else:
            text(*center, label, color)

    status = "MANUALLY CONFIRMED" if calibration.calibrated else "DRAFT / UNCALIBRATED"
    text(20, 13, f"{status}: {data['metadata']['title']}", "#ffcf66", title=True)
    text(
        20,
        49,
        "Offline geometry preview | Camera / MQTT / appliances disabled | Full image coordinates",
    )
    text(1215, 90, "Physical floor plan (not image quadrants)", "#eeeeee")
    for zone in data["appliance_zones"]:
        color = COLORS[zone["id"]]
        region(tuple(map(tuple, zone["floor_polygon"])), FLOOR_RECT, color, zone["id"], floor=True)
        if zone["image_polygon"]:
            region(
                tuple(map(tuple, zone["image_polygon"])),
                rect,
                color,
                f"{zone['id']} manual outline",
                fill=False,
            )
        if calibration.homography:
            clipped = convex_clip(
                tuple(map(tuple, zone["floor_polygon"])), calibration.homography["floor_hull"]
            )
            projected = tuple(project(calibration.homography["inverse"], p) for p in clipped)
            region(projected, rect, color, f"{zone['id']} ground", fill=False)
    text(1215, 802, "Front (camera) / depth=0", "#dddddd")
    text(1215, 826, "Left/right: front facing the back", "#dddddd")
    text(1215, 850, "Back=depth 1; width left 0 -> right 1", "#dddddd")
    for excluded in data["excluded_regions"]:
        region(
            tuple(map(tuple, excluded["polygon"])), rect, "#ef5350", f"EXCLUDE: {excluded['id']}"
        )
    for row in data["seating_rows"]:
        pixels = [view_point(p, rect) for p in row["image_points"]]
        draw.line(pixels, fill=(255, 255, 255, 200), width=2)
        text(*pixels[0], row["id"], "#ffffff")
    for seat in data["seat_regions"]:
        region(tuple(map(tuple, seat["polygon"])), rect, COLORS[seat["zone_id"]], seat["id"])
        if seat["floor_point"] is not None:
            x, y = view_point(seat["floor_point"], FLOOR_RECT, floor=True)
            draw.ellipse((x - 4, y - 4, x + 4, y + 4), fill=COLORS[seat["zone_id"]])
            owner = next(z for z in data["appliance_zones"] if z["id"] == seat["zone_id"])
            owner_pixels = [view_point(p, FLOOR_RECT, floor=True) for p in owner["floor_polygon"]]
            label_x = min(p[0] for p in owner_pixels) + 8
            label_width = max(p[0] for p in owner_pixels) - label_x - 8
            text(label_x, y + 12, seat["id"], COLORS[seat["zone_id"]], max_width=label_width)
    for landmark in data["floor_landmarks"]:
        for p, target, floor in (
            (landmark["image"], rect, False),
            (landmark["floor"], FLOOR_RECT, True),
        ):
            x, y = view_point(p, target, floor=floor)
            draw.ellipse((x - 5, y - 5, x + 5, y + 5), outline="yellow", width=2)
            text(
                x + 7,
                y - 7,
                landmark["id"] + ("" if landmark["on_floor"] else " UNVERIFIED"),
                "yellow",
            )
    results = []
    for box in boxes:
        assignment = calibration.locate(box, frame_size=reference.size, preview=True)
        results.append(assignment)
        y0, x0, y1, x1 = box
        draw.rectangle(
            (*view_point((x0, y0), rect), *view_point((x1, y1), rect)), outline="white", width=2
        )
    for ground in ground_points:
        results.append(
            calibration.locate(ground_point=ground, frame_size=reference.size, preview=True)
        )
    for result in results:
        if result.image_anchor:
            x, y = view_point(result.image_anchor, rect)
            color = COLORS.get(result.zone_id, "#ff5555")
            draw.line((x - 8, y, x + 8, y), fill=color, width=3)
            draw.line((x, y - 8, x, y + 8), fill=color, width=3)
            text(
                x + 10, y + 10, f"{result.status.upper()}: {result.zone_id or result.reason}", color
            )
        if result.floor_anchor:
            x, y = view_point(result.floor_anchor, FLOOR_RECT, floor=True)
            draw.line((x - 8, y, x + 8, y), fill="white", width=3)
            draw.line((x, y - 8, x, y + 8), fill="white", width=3)
    y = max(rect[3] + 16, 865)
    text(
        20,
        y,
        "Filled colors: seat/bench upper-body anchor areas. White lines: seating rows.",
    )
    text(
        20,
        y + 24,
        "Crosses: configured assignment anchors. Red: excluded objects/areas or UNKNOWN location.",
    )
    text(
        20,
        y + 48,
        "Ground outlines require verified floor correspondences. No box-bottom projection.",
    )
    text(
        20,
        y + 72,
        f"Method: {data['assignment']['method']} | "
        f"Anchor fraction: {data['assignment']['anchor_fraction']} | "
        f"Source: {data['reference']['kind']} | Final mounted-frame calibration still required"
        if not calibration.calibrated
        else f"Method: {data['assignment']['method']} | Revision {data['revision']} | "
        "Recheck after any camera/seat change",
    )
    report = {
        "schema_version": 2,
        "calibrated": calibration.calibrated,
        "geometry_digest": geometry_digest(data),
        "reference": data["reference"],
        "assignments": [asdict(a) for a in results],
        "homography": {
            k: calibration.homography[k]
            for k in ("rms_error_px", "max_error_px", "reference_count")
        }
        if calibration.homography
        else None,
        "homography_status": calibration.homography_error
        or "computed; physical checks still required",
        "camera_used": False,
        "mqtt_used": False,
        "appliance_control_enabled": False,
    }
    return canvas, report
