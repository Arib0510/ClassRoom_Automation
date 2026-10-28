"""Small convex geometry and normalized DLT; NumPy only, no vision runtime."""

from __future__ import annotations

import math

import numpy as np

from .zones import EPSILON, Zone, _cross


def point(value, name: str = "point") -> tuple[float, float]:
    if (
        not isinstance(value, (list, tuple))
        or len(value) != 2
        or any(
            isinstance(v, bool)
            or not isinstance(v, (int, float))
            or not math.isfinite(v)
            or not 0 <= v <= 1
            for v in value
        )
    ):
        raise ValueError(f"{name} requires normalized finite [x,y] in [0,1]")
    return tuple(map(float, value))


def polygon(value, name: str, *, optional: bool = False) -> tuple:
    if optional and value == []:
        return ()
    if not isinstance(value, (list, tuple)) or not 3 <= len(value) <= 12:
        raise ValueError(f"{name} needs 3-12 convex ordered vertices")
    vertices = tuple(point(v, name) for v in value)
    turns = [
        _cross(vertices[i], vertices[(i + 1) % len(vertices)], vertices[(i + 2) % len(vertices)])
        for i in range(len(vertices))
    ]
    if not (all(t > EPSILON for t in turns) or all(t < -EPSILON for t in turns)):
        raise ValueError(f"{name} must be strictly convex with unique ordered vertices")
    for i, vertex in enumerate(vertices):
        sides = [_cross(vertex, vertices[(i + 1) % len(vertices)], p) for p in vertices]
        if any(s > EPSILON for s in sides) and any(s < -EPSILON for s in sides):
            raise ValueError(f"{name} is self-intersecting")
    return vertices


def hull(points) -> tuple:
    unique = sorted(set(map(tuple, points)))
    if len(unique) < 3:
        raise ValueError("At least three non-collinear points are required for a hull")
    lower, upper = [], []
    for sequence, chain in ((unique, lower), (unique[::-1], upper)):
        for p in sequence:
            while len(chain) >= 2 and _cross(chain[-2], chain[-1], p) <= EPSILON:
                chain.pop()
            chain.append(p)
    result = tuple(lower[:-1] + upper[:-1])
    if len(result) < 3:
        raise ValueError("Collinear reference points")
    return result


def inside_margin(p: tuple, vertices: tuple, margin: float = 0, size=(1, 1)) -> bool:
    """Convex containment plus distance to every edge, in the specified coordinate units."""
    if not Zone("region", vertices).contains(p):
        return False
    px, py = p[0] * size[0], p[1] * size[1]
    for a, b in zip(vertices, vertices[1:] + vertices[:1], strict=True):
        ax, ay, bx, by = a[0] * size[0], a[1] * size[1], b[0] * size[0], b[1] * size[1]
        distance = abs((bx - ax) * (py - ay) - (by - ay) * (px - ax)) / math.hypot(bx - ax, by - ay)
        if distance <= margin + EPSILON:
            return False
    return True


def project(matrix: np.ndarray, p: tuple) -> tuple[float, float]:
    projected = matrix @ np.array([p[0], p[1], 1.0])
    if not np.all(np.isfinite(projected)) or abs(projected[2]) < 1e-10:
        raise ValueError("Point projects to the homography horizon")
    return tuple(map(float, projected[:2] / projected[2]))


def convex_clip(subject: tuple, clip: tuple) -> tuple:
    """Clip a convex polygon to another convex polygon, allowing either winding."""
    output = list(subject)
    winding = 1 if _cross(clip[0], clip[1], clip[2]) > 0 else -1
    for a, b in zip(clip, clip[1:] + clip[:1], strict=True):
        vertices, output = output, []
        if not vertices:
            break
        for previous, current in zip(vertices[-1:] + vertices[:-1], vertices, strict=True):
            d0, d1 = winding * _cross(a, b, previous), winding * _cross(a, b, current)
            if (d0 >= 0) != (d1 >= 0):
                fraction = d0 / (d0 - d1)
                output.append(
                    tuple(previous[i] + fraction * (current[i] - previous[i]) for i in (0, 1))
                )
            if d1 >= 0:
                output.append(current)
    return tuple(output)


def fit_homography(image_points, floor_points, image_size=(1, 1), max_error_px=3.0) -> dict:
    """Image normalized xy -> normalized floor xy, with rank and reprojection checks.

    Exactly four points can fit perfectly without validating physical correctness.
    More independently measured points are strongly preferred. No lens model is fitted.
    """
    if len(image_points) != len(floor_points) or len(image_points) < 4:
        raise ValueError("Homography requires at least four corresponding floor landmarks")
    image = np.array([point(p) for p in image_points], dtype=np.float64)
    floor = np.array([point(p) for p in floor_points], dtype=np.float64)
    if len(set(map(tuple, image))) != len(image) or len(set(map(tuple, floor))) != len(floor):
        raise ValueError("Repeated homography landmark")
    image_hull, floor_hull = hull(image), hull(floor)

    def normalize(values):
        center = values.mean(axis=0)
        distance = np.linalg.norm(values - center, axis=1).mean()
        if distance < 1e-10:
            raise ValueError("Degenerate homography landmarks")
        scale = math.sqrt(2) / distance
        transform = np.array(
            [[scale, 0, -scale * center[0]], [0, scale, -scale * center[1]], [0, 0, 1]]
        )
        return (values - center) * scale, transform

    a, ta = normalize(image)
    b, tb = normalize(floor)
    rows = []
    for (x, y), (u, v) in zip(a, b, strict=True):
        rows.extend(
            [[-x, -y, -1, 0, 0, 0, u * x, u * y, u], [0, 0, 0, -x, -y, -1, v * x, v * y, v]]
        )
    design = np.array(rows)
    _, singular, vh = np.linalg.svd(design, full_matrices=design.shape[0] < design.shape[1])
    if np.linalg.matrix_rank(design, tol=singular[0] * 1e-10) < 8:
        raise ValueError("Degenerate/non-general-position floor correspondences")
    constrained = singular[-1] if design.shape[0] == 8 else singular[-2]
    if singular[0] / constrained > 1e8:
        raise ValueError("Ill-conditioned homography landmarks")
    matrix = np.linalg.inv(tb) @ vh[-1].reshape(3, 3) @ ta
    matrix /= np.linalg.norm(matrix)
    if abs(np.linalg.det(matrix)) < 1e-12:
        raise ValueError("Noninvertible homography")
    inverse = np.linalg.inv(matrix)
    for transform, domain in ((matrix, image_hull), (inverse, floor_hull)):
        denominators = [float((transform @ [*p, 1])[2]) for p in domain]
        if min(denominators) <= 1e-10 and max(denominators) >= -1e-10:
            raise ValueError("Homography horizon crosses reference domain")
    errors = [
        math.hypot(
            (project(inverse, q)[0] - p[0]) * image_size[0],
            (project(inverse, q)[1] - p[1]) * image_size[1],
        )
        for p, q in zip(image, floor, strict=True)
    ]
    if not math.isfinite(max_error_px) or max_error_px <= 0 or max(errors) > max_error_px:
        raise ValueError("Homography reprojection error exceeds configured pixel limit")
    return {
        "matrix": matrix,
        "inverse": inverse,
        "image_hull": image_hull,
        "floor_hull": floor_hull,
        "rms_error_px": float(np.sqrt(np.mean(np.square(errors)))),
        "max_error_px": max(errors),
        "reference_count": len(image),
    }
