#!/usr/bin/env python3
"""Generate Aitvaras's original, multi-part dragon avatar as a GLB.

The model is intentionally authored from custom meshes rather than SceneKit
primitives.  Named nodes (head, eyes, jaw, wings and flame) remain separate so
the application can animate them without a skeletal rig.
"""

from __future__ import annotations

import argparse
import math
from pathlib import Path
from typing import Iterable, Sequence

import numpy as np
import trimesh
from trimesh.visual.material import PBRMaterial


def signed_power(value: float, exponent: float) -> float:
    return math.copysign(abs(value) ** exponent, value)


def color(hex_color: str, alpha: int = 255) -> np.ndarray:
    value = hex_color.removeprefix("#")
    return np.array(
        [int(value[0:2], 16), int(value[2:4], 16), int(value[4:6], 16), alpha],
        dtype=np.uint8,
    )


def pbr(
    name: str,
    hex_color: str,
    *,
    roughness: float,
    metallic: float = 0.0,
    emissive: str | None = None,
    alpha: int = 255,
    double_sided: bool = False,
) -> PBRMaterial:
    emission = None
    if emissive is not None:
        rgba = color(emissive)
        emission = rgba[:3].astype(float) / 255.0
    return PBRMaterial(
        name=name,
        baseColorFactor=color(hex_color, alpha),
        metallicFactor=metallic,
        roughnessFactor=roughness,
        emissiveFactor=emission,
        doubleSided=double_sided,
        alphaMode="BLEND" if alpha < 255 else "OPAQUE",
    )


MATERIALS = {
    "skin": pbr("Ink blue scales", "101F3C", roughness=0.55),
    "skin_light": pbr("Raised blue scales", "28517D", roughness=0.44),
    "skin_deep": pbr("Deep blue recesses", "080F1D", roughness=0.58),
    "red": pbr(
        "Crimson armour", "861126", roughness=0.30,
        emissive="0D0103", double_sided=True),
    "red_bright": pbr(
        "Fire red edges", "D62F26", roughness=0.27,
        emissive="150202", double_sided=True),
    "orange": pbr(
        "Flame orange", "F16A25", roughness=0.32,
        emissive="190501", double_sided=True),
    "belly": pbr("Burnt orange belly", "A94F27", roughness=0.48),
    "gold": pbr("Horn gold", "F3BE52", roughness=0.36, metallic=0.08),
    "sclera": pbr("Warm eye white", "FFF4E2", roughness=0.18),
    "iris": pbr("Ember iris", "D94520", roughness=0.16, metallic=0.04),
    "pupil": pbr("Pupil", "08070A", roughness=0.20),
    "mouth": pbr("Mouth", "260A10", roughness=0.62),
    "tongue": pbr("Tongue", "E66568", roughness=0.44),
    "cheek": pbr("Cheek ember", "E94C35", roughness=0.36),
    "flame": pbr(
        "Flame shell", "F34A13", roughness=0.20, emissive="FF4B13", alpha=220
    ),
    "flame_core": pbr(
        "Flame core", "FFD45A", roughness=0.14, emissive="FFD45A", alpha=235
    ),
}


def clean(mesh: trimesh.Trimesh, name: str) -> trimesh.Trimesh:
    mesh.metadata["name"] = name
    mesh.remove_unreferenced_vertices()
    mesh.fix_normals()
    if mesh.is_volume and mesh.volume < 0:
        mesh.invert()
    return mesh


def superquadric(
    scale: Sequence[float],
    *,
    vertical_exponent: float = 0.64,
    radial_exponent: float = 0.72,
    rings: int = 22,
    sections: int = 36,
    name: str = "superquadric",
) -> trimesh.Trimesh:
    """Rounded, planar-sided volume with one vertex at each pole."""
    sx, sy, sz = scale
    vertices: list[list[float]] = [[0.0, -sy, 0.0]]
    faces: list[list[int]] = []

    for ring in range(1, rings):
        eta = -math.pi / 2 + math.pi * ring / rings
        ce = signed_power(math.cos(eta), vertical_exponent)
        se = signed_power(math.sin(eta), vertical_exponent)
        for section in range(sections):
            omega = 2 * math.pi * section / sections
            vertices.append(
                [
                    sx * ce * signed_power(math.cos(omega), radial_exponent),
                    sy * se,
                    sz * ce * signed_power(math.sin(omega), radial_exponent),
                ]
            )

    top = len(vertices)
    vertices.append([0.0, sy, 0.0])

    first_ring = 1
    for section in range(sections):
        current = first_ring + section
        nxt = first_ring + (section + 1) % sections
        faces.append([0, nxt, current])

    for ring in range(rings - 2):
        start = first_ring + ring * sections
        next_start = start + sections
        for section in range(sections):
            a = start + section
            b = start + (section + 1) % sections
            c = next_start + (section + 1) % sections
            d = next_start + section
            faces.extend(([a, b, c], [a, c, d]))

    last_ring = first_ring + (rings - 2) * sections
    for section in range(sections):
        current = last_ring + section
        nxt = last_ring + (section + 1) % sections
        faces.append([current, nxt, top])

    return clean(
        trimesh.Trimesh(vertices=np.asarray(vertices), faces=np.asarray(faces), process=False),
        name,
    )


def loft_y(
    profiles: Sequence[tuple[float, float, float, float, float]],
    *,
    sections: int = 24,
    exponent: float = 2.8,
    name: str = "loft-y",
) -> trimesh.Trimesh:
    """Loft rounded polygonal x/z profiles along the y axis.

    Each profile is (y, centre_x, centre_z, radius_x, radius_z).
    """
    vertices: list[list[float]] = []
    faces: list[list[int]] = []
    power = 2.0 / exponent
    for y, cx, cz, rx, rz in profiles:
        for section in range(sections):
            angle = 2 * math.pi * section / sections
            vertices.append(
                [
                    cx + rx * signed_power(math.cos(angle), power),
                    y,
                    cz + rz * signed_power(math.sin(angle), power),
                ]
            )

    for ring in range(len(profiles) - 1):
        start = ring * sections
        next_start = start + sections
        for section in range(sections):
            a = start + section
            b = start + (section + 1) % sections
            c = next_start + (section + 1) % sections
            d = next_start + section
            faces.extend(([a, b, c], [a, c, d]))

    bottom = len(vertices)
    vertices.append(
        [profiles[0][1], profiles[0][0], profiles[0][2]]
    )
    top = len(vertices)
    vertices.append(
        [profiles[-1][1], profiles[-1][0], profiles[-1][2]]
    )
    for section in range(sections):
        nxt = (section + 1) % sections
        faces.append([bottom, nxt, section])
        base = (len(profiles) - 1) * sections
        faces.append([top, base + section, base + nxt])

    return clean(
        trimesh.Trimesh(vertices=np.asarray(vertices), faces=np.asarray(faces), process=False),
        name,
    )


def loft_z(
    profiles: Sequence[tuple[float, float, float, float, float]],
    *,
    sections: int = 20,
    exponent: float = 3.4,
    name: str = "loft-z",
) -> trimesh.Trimesh:
    """Loft rounded x/y profiles along z.

    Each profile is (z, centre_x, centre_y, radius_x, radius_y).
    """
    vertices: list[list[float]] = []
    faces: list[list[int]] = []
    power = 2.0 / exponent
    for z, cx, cy, rx, ry in profiles:
        for section in range(sections):
            angle = 2 * math.pi * section / sections
            vertices.append(
                [
                    cx + rx * signed_power(math.cos(angle), power),
                    cy + ry * signed_power(math.sin(angle), power),
                    z,
                ]
            )

    for ring in range(len(profiles) - 1):
        start = ring * sections
        next_start = start + sections
        for section in range(sections):
            a = start + section
            b = start + (section + 1) % sections
            c = next_start + (section + 1) % sections
            d = next_start + section
            faces.extend(([a, b, c], [a, c, d]))

    back = len(vertices)
    vertices.append([profiles[0][1], profiles[0][2], profiles[0][0]])
    front = len(vertices)
    vertices.append([profiles[-1][1], profiles[-1][2], profiles[-1][0]])
    for section in range(sections):
        nxt = (section + 1) % sections
        faces.append([back, section, nxt])
        base = (len(profiles) - 1) * sections
        faces.append([front, base + nxt, base + section])

    return clean(
        trimesh.Trimesh(vertices=np.asarray(vertices), faces=np.asarray(faces), process=False),
        name,
    )


def catmull_rom(
    control_points: Sequence[Sequence[float]],
    radii: Sequence[float],
    samples_per_segment: int = 5,
) -> tuple[np.ndarray, np.ndarray]:
    points = np.asarray(control_points, dtype=float)
    radius_values = np.asarray(radii, dtype=float)
    padded = np.vstack((points[0], points, points[-1]))
    padded_radii = np.concatenate(([radius_values[0]], radius_values, [radius_values[-1]]))
    output: list[np.ndarray] = []
    output_radii: list[float] = []

    for index in range(1, len(padded) - 2):
        p0, p1, p2, p3 = padded[index - 1 : index + 3]
        r1, r2 = padded_radii[index], padded_radii[index + 1]
        for sample in range(samples_per_segment):
            t = sample / samples_per_segment
            t2, t3 = t * t, t * t * t
            point = 0.5 * (
                2 * p1
                + (-p0 + p2) * t
                + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2
                + (-p0 + 3 * p1 - 3 * p2 + p3) * t3
            )
            output.append(point)
            output_radii.append(float(r1 + (r2 - r1) * t))

    output.append(points[-1])
    output_radii.append(float(radius_values[-1]))
    return np.asarray(output), np.asarray(output_radii)


def tube(
    control_points: Sequence[Sequence[float]],
    radii: Sequence[float],
    *,
    sections: int = 14,
    samples_per_segment: int = 5,
    flatten: float = 1.0,
    name: str = "tube",
) -> trimesh.Trimesh:
    points, radius_values = catmull_rom(
        control_points, radii, samples_per_segment=samples_per_segment
    )
    vertices: list[np.ndarray] = []
    faces: list[list[int]] = []
    previous_normal: np.ndarray | None = None

    for index, point in enumerate(points):
        if index == 0:
            tangent = points[1] - point
        elif index == len(points) - 1:
            tangent = point - points[index - 1]
        else:
            tangent = points[index + 1] - points[index - 1]
        tangent /= np.linalg.norm(tangent)
        reference = np.array([0.0, 1.0, 0.0])
        if abs(float(np.dot(tangent, reference))) > 0.88:
            reference = np.array([1.0, 0.0, 0.0])
        normal = np.cross(tangent, reference)
        normal /= np.linalg.norm(normal)
        if previous_normal is not None and np.dot(normal, previous_normal) < 0:
            normal *= -1
        binormal = np.cross(tangent, normal)
        binormal /= np.linalg.norm(binormal)
        previous_normal = normal

        radius = radius_values[index]
        for section in range(sections):
            angle = 2 * math.pi * section / sections
            offset = (
                normal * math.cos(angle) * radius
                + binormal * math.sin(angle) * radius * flatten
            )
            vertices.append(point + offset)

    for ring in range(len(points) - 1):
        start = ring * sections
        next_start = start + sections
        for section in range(sections):
            a = start + section
            b = start + (section + 1) % sections
            c = next_start + (section + 1) % sections
            d = next_start + section
            faces.extend(([a, b, c], [a, c, d]))

    start_cap = len(vertices)
    vertices.append(points[0])
    end_cap = len(vertices)
    vertices.append(points[-1])
    for section in range(sections):
        nxt = (section + 1) % sections
        faces.append([start_cap, nxt, section])
        base = (len(points) - 1) * sections
        faces.append([end_cap, base + section, base + nxt])

    return clean(
        trimesh.Trimesh(vertices=np.asarray(vertices), faces=np.asarray(faces), process=False),
        name,
    )


def scale_plate(
    width: float,
    height: float,
    depth: float,
    *,
    name: str = "scale",
) -> trimesh.Trimesh:
    """Domed six-sided scale ending in a sharp lower point."""
    outline = np.array(
        [
            [-0.28 * width, 0.50 * height],
            [0.28 * width, 0.50 * height],
            [0.52 * width, 0.12 * height],
            [0.0, -0.58 * height],
            [-0.52 * width, 0.12 * height],
        ]
    )
    vertices: list[list[float]] = []
    for x, y in outline:
        vertices.append([x, y, -depth * 0.50])
    for x, y in outline:
        vertices.append([x, y, depth * 0.22])
    front_center = len(vertices)
    vertices.append([0.0, 0.04 * height, depth * 0.72])
    back_center = len(vertices)
    vertices.append([0.0, 0.04 * height, -depth * 0.50])

    faces: list[list[int]] = []
    count = len(outline)
    for index in range(count):
        nxt = (index + 1) % count
        faces.append([front_center, count + index, count + nxt])
        faces.append([back_center, nxt, index])
        faces.extend(
            ([index, nxt, count + nxt], [index, count + nxt, count + index])
        )
    return clean(
        trimesh.Trimesh(vertices=np.asarray(vertices), faces=np.asarray(faces), process=False),
        name,
    )


def belly_plate(
    width: float,
    height: float,
    depth: float,
    *,
    name: str = "belly-plate",
) -> trimesh.Trimesh:
    """Broad domed hexagonal plate for the overlapping chest armour."""
    outline = np.array(
        [
            [-0.42 * width, 0.50 * height],
            [0.42 * width, 0.50 * height],
            [0.52 * width, 0.12 * height],
            [0.42 * width, -0.50 * height],
            [-0.42 * width, -0.50 * height],
            [-0.52 * width, 0.12 * height],
        ]
    )
    vertices: list[list[float]] = []
    for x, y in outline:
        vertices.append([x, y, -depth * 0.45])
    for x, y in outline:
        vertices.append([x, y, depth * 0.20])
    front_center = len(vertices)
    vertices.append([0.0, 0.02 * height, depth * 0.75])
    back_center = len(vertices)
    vertices.append([0.0, 0.0, -depth * 0.45])
    faces: list[list[int]] = []
    count = len(outline)
    for index in range(count):
        nxt = (index + 1) % count
        faces.append([front_center, count + index, count + nxt])
        faces.append([back_center, nxt, index])
        faces.extend(
            ([index, nxt, count + nxt], [index, count + nxt, count + index])
        )
    return clean(
        trimesh.Trimesh(vertices=np.asarray(vertices), faces=np.asarray(faces), process=False),
        name,
    )


def fin(width: float, height: float, depth: float, *, name: str = "fin") -> trimesh.Trimesh:
    x = width / 2
    z = depth / 2
    vertices = np.array(
        [
            [-x, 0, -z],
            [x, 0, -z],
            [0, height, -z],
            [-x, 0, z],
            [x, 0, z],
            [0, height, z],
        ]
    )
    faces = np.array(
        [
            [0, 1, 2],
            [5, 4, 3],
            [0, 3, 4],
            [0, 4, 1],
            [1, 4, 5],
            [1, 5, 2],
            [2, 5, 3],
            [2, 3, 0],
        ]
    )
    return clean(trimesh.Trimesh(vertices=vertices, faces=faces, process=False), name)


def transform(
    mesh: trimesh.Trimesh,
    *,
    translate: Sequence[float] = (0, 0, 0),
    rotate: Sequence[float] = (0, 0, 0),
    scale: Sequence[float] = (1, 1, 1),
) -> trimesh.Trimesh:
    result = mesh.copy()
    result.apply_scale(np.asarray(scale, dtype=float))
    matrix = trimesh.transformations.euler_matrix(*rotate, axes="sxyz")
    matrix[:3, 3] = np.asarray(translate, dtype=float)
    result.apply_transform(matrix)
    return result


def batch(
    base: trimesh.Trimesh,
    placements: Iterable[
        tuple[Sequence[float], Sequence[float], Sequence[float]]
    ],
    *,
    name: str,
) -> trimesh.Trimesh:
    copies = [
        transform(base, translate=translation, rotate=rotation, scale=scaling)
        for translation, rotation, scaling in placements
    ]
    return clean(trimesh.util.concatenate(copies), name)


def wing_membrane(side: float, *, name: str) -> trimesh.Trimesh:
    points = np.array(
        [
            [0.00, 0.00, 0.000],
            [0.15 * side, 0.16, -0.015],
            [0.34 * side, 0.37, -0.025],
            [0.39 * side, 0.17, -0.005],
            [0.42 * side, -0.02, 0.010],
            [0.31 * side, -0.17, 0.020],
            [0.11 * side, -0.14, 0.012],
        ]
    )
    thickness = 0.006
    front = points.copy()
    front[:, 2] += thickness
    back = points.copy()
    back[:, 2] -= thickness
    vertices = np.vstack((front, back))
    panel_faces = [[0, 1, 2], [0, 2, 3], [0, 3, 4], [0, 4, 5], [0, 5, 6]]
    # The elbow/tip outline is deliberately concave, so a simple fan can
    # alternate winding. Normalize every front panel toward +Z; the back
    # surface below receives the exact inverse winding.
    for index, face in enumerate(panel_faces):
        a, b, c = (points[vertex] for vertex in face)
        if np.cross(b - a, c - a)[2] < 0:
            panel_faces[index] = [face[0], face[2], face[1]]
    faces = list(panel_faces)
    offset = len(points)
    faces.extend([[a + offset, c + offset, b + offset] for a, b, c in panel_faces])
    boundary = list(range(len(points)))
    for index, current in enumerate(boundary):
        nxt = boundary[(index + 1) % len(boundary)]
        faces.extend(
            ([current, nxt, offset + nxt], [current, offset + nxt, offset + current])
        )
    mesh = trimesh.Trimesh(vertices=vertices, faces=np.asarray(faces), process=False)
    # Keep the hand-authored front/back orientation. A global winding repair
    # treats the concave wing as a solid and can flip only its first panel.
    for index in range(len(panel_faces)):
        if mesh.face_normals[index][2] < 0:
            mesh.faces[index] = mesh.faces[index][::-1]
    back_start = len(panel_faces)
    for index in range(back_start, back_start + len(panel_faces)):
        if mesh.face_normals[index][2] > 0:
            mesh.faces[index] = mesh.faces[index][::-1]
    mesh._cache.clear()
    mesh.metadata["name"] = name
    return mesh


class DragonBuilder:
    def __init__(self) -> None:
        self.scene = trimesh.Scene(base_frame="AitvarasDragonScene")
        self.scene.graph.update("DragonRoot", translation=[0, 0, 0])

    def add(
        self,
        mesh: trimesh.Trimesh,
        name: str,
        material: str,
        *,
        parent: str = "DragonRoot",
        node_transform: np.ndarray | None = None,
    ) -> None:
        mesh = mesh.copy()
        mesh.visual = trimesh.visual.TextureVisuals(material=MATERIALS[material])
        self.scene.add_geometry(
            mesh,
            geom_name=f"{name}.geometry",
            node_name=name,
            parent_node_name=parent,
            transform=np.eye(4) if node_transform is None else node_transform,
        )

    def empty(
        self,
        name: str,
        *,
        parent: str = "DragonRoot",
        translation: Sequence[float] = (0, 0, 0),
    ) -> None:
        self.scene.graph.update(
            name, frame_from=parent, translation=np.asarray(translation, dtype=float)
        )

    def build_body(self) -> None:
        torso = loft_y(
            [
                (0.18, 0.00, -0.015, 0.17, 0.15),
                (0.28, 0.00, -0.005, 0.235, 0.195),
                (0.44, 0.00, 0.000, 0.275, 0.215),
                (0.63, 0.00, 0.004, 0.265, 0.205),
                (0.79, 0.00, 0.000, 0.225, 0.175),
                (0.94, 0.00, -0.005, 0.205, 0.155),
                (1.02, 0.00, -0.012, 0.17, 0.135),
            ],
            sections=28,
            exponent=3.2,
            name="TorsoMesh",
        )
        self.add(torso, "Torso", "skin")

        shoulder_shell = superquadric(
            (0.245, 0.13, 0.16),
            vertical_exponent=0.55,
            radial_exponent=0.58,
            name="ShoulderShellMesh",
        )
        shoulder_shell = transform(
            shoulder_shell, translate=(0, 0.90, 0.015), rotate=(0.05, 0, 0)
        )
        self.add(shoulder_shell, "ShoulderShell", "skin_light")

        belly_base = belly_plate(0.28, 0.13, 0.038, name="BellyPlateTemplate")
        widths = [0.18, 0.22, 0.26, 0.28, 0.265, 0.23]
        placements = []
        for index, width in enumerate(widths):
            y = 0.30 + index * 0.092
            placements.append(
                ((0, y, 0.208 - abs(index - 2.5) * 0.004), (0.05, 0, 0), (width / 0.28, 1, 1))
            )
        self.add(
            batch(belly_base, placements, name="BellyArmourMesh"),
            "BellyArmour",
            "belly",
        )

        scale_template = scale_plate(0.066, 0.076, 0.023, name="BodyScaleTemplate")
        placements = []
        for row, y in enumerate(np.linspace(0.34, 0.84, 6)):
            half_width = 0.235 - row * 0.010
            for side in (-1.0, 1.0):
                for column in range(2):
                    x = side * (0.14 + column * 0.055)
                    z = 0.15 - column * 0.035
                    placements.append(
                        (
                            (x, float(y), z),
                            (0.0, side * (0.36 + column * 0.18), side * 0.05),
                            (1.0 - row * 0.03, 1.0 - row * 0.025, 1.0),
                        )
                    )
            _ = half_width
        self.add(
            batch(scale_template, placements, name="TorsoScaleFieldMesh"),
            "TorsoScaleField",
            "skin_light",
        )

        guard_template = scale_plate(0.15, 0.18, 0.045, name="ShoulderGuardTemplate")
        guards = []
        for side in (-1.0, 1.0):
            guards.append(
                ((side * 0.235, 0.88, 0.045), (0.02, side * 0.58, -side * 0.42), (1, 1, 1))
            )
        self.add(
            batch(guard_template, guards, name="ShoulderGuardsMesh"),
            "ShoulderGuards",
            "red",
        )

        dorsal = fin(0.085, 0.13, 0.045, name="DorsalFinTemplate")
        placements = [
            ((0, 0.84 - index * 0.13, -0.19), (-0.18, 0, 0), (1 - index * 0.08, 1 - index * 0.08, 1))
            for index in range(5)
        ]
        self.add(
            batch(dorsal, placements, name="DorsalFinsMesh"),
            "DorsalFins",
            "red",
        )

    def build_head(self) -> None:
        self.empty("DragonHead", translation=(0, 1.12, 0.015))

        skull = superquadric(
            (0.31, 0.245, 0.225),
            vertical_exponent=0.70,
            radial_exponent=0.74,
            rings=24,
            sections=40,
            name="SkullMesh",
        )
        skull = transform(skull, translate=(0, 0.105, -0.005), rotate=(-0.035, 0, 0))
        self.add(skull, "Skull", "skin", parent="DragonHead")

        snout = loft_z(
            [
                (0.145, 0.0, -0.005, 0.19, 0.083),
                (0.225, 0.0, -0.020, 0.176, 0.074),
                (0.315, 0.0, -0.036, 0.145, 0.060),
            ],
            sections=24,
            exponent=4.0,
            name="SnoutMesh",
        )
        self.add(snout, "Snout", "skin_light", parent="DragonHead")

        forehead = scale_plate(0.115, 0.285, 0.042, name="ForeheadArmourMesh")
        forehead = transform(
            forehead, translate=(0, 0.17, 0.226), rotate=(-0.08, 0, 0)
        )
        self.add(forehead, "ForeheadArmour", "red", parent="DragonHead")

        brow_template = scale_plate(0.15, 0.062, 0.030, name="BrowTemplate")
        brows = []
        for side in (-1.0, 1.0):
            brows.append(
                ((side * 0.115, 0.225, 0.218), (-0.06, side * 0.12, -side * 0.16), (1, 1, 1))
            )
        self.add(
            batch(brow_template, brows, name="BrowArmourMesh"),
            "BrowArmour",
            "red_bright",
            parent="DragonHead",
        )

        mask_template = scale_plate(0.070, 0.165, 0.018, name="FaceMaskTemplate")
        masks = []
        for side in (-1.0, 1.0):
            masks.append(
                (
                    (side * 0.192, 0.105, 0.216),
                    (-0.02, side * 0.34, -side * 0.14),
                    (1, 1, 1),
                )
            )
        self.add(
            batch(mask_template, masks, name="FaceMaskMesh"),
            "FaceMask",
            "red",
            parent="DragonHead",
        )

        head_scale = scale_plate(0.048, 0.057, 0.020, name="HeadScaleTemplate")
        placements = []
        for side in (-1.0, 1.0):
            for row in range(3):
                for column in range(3):
                    placements.append(
                        (
                            (
                                side * (0.19 + column * 0.038),
                                0.145 - row * 0.058,
                                0.165 - column * 0.025,
                            ),
                            (0, side * (0.40 + column * 0.18), -side * 0.08),
                            (1 - row * 0.05, 1 - row * 0.05, 1),
                        )
                    )
        self.add(
            batch(head_scale, placements, name="CheekScaleFieldMesh"),
            "CheekScaleField",
            "skin_light",
            parent="DragonHead",
        )

        forehead_scales = []
        for side in (-1.0, 1.0):
            for row in range(2):
                for column in range(2):
                    forehead_scales.append(
                        (
                            (
                                side * (0.072 + column * 0.060),
                                0.275 - row * 0.055,
                                0.205 + row * 0.010,
                            ),
                            (-0.05, side * 0.18, -side * 0.04),
                            (0.78, 0.78, 0.72),
                        )
                    )
        self.add(
            batch(head_scale, forehead_scales, name="ForeheadScaleFieldMesh"),
            "ForeheadScaleField",
            "skin_light",
            parent="DragonHead",
        )

        for side, label in ((-1.0, "L"), (1.0, "R")):
            eye_group = f"Eye.{label}"
            self.empty(eye_group, parent="DragonHead", translation=(side * 0.112, 0.135, 0.215))

            eye = trimesh.creation.icosphere(subdivisions=3, radius=1.0)
            eye = transform(eye, scale=(0.092, 0.112, 0.052))
            self.add(eye, f"Sclera.{label}", "sclera", parent=eye_group)

            iris = trimesh.creation.icosphere(subdivisions=3, radius=1.0)
            iris = transform(iris, translate=(0, 0, 0.047), scale=(0.058, 0.071, 0.014))
            self.add(iris, f"Iris.{label}", "iris", parent=eye_group)

            pupil = superquadric(
                (0.018, 0.052, 0.010),
                vertical_exponent=0.70,
                radial_exponent=0.78,
                rings=16,
                sections=24,
                name=f"PupilMesh.{label}",
            )
            pupil = transform(pupil, translate=(0, 0, 0.060))
            self.add(pupil, f"Pupil.{label}", "pupil", parent=eye_group)

            highlight = trimesh.creation.icosphere(subdivisions=2, radius=0.018)
            highlight = transform(
                highlight, translate=(-side * 0.025, 0.038, 0.070), scale=(1, 1, 0.55)
            )
            self.add(highlight, f"EyeHighlight.{label}", "sclera", parent=eye_group)

            cheek = scale_plate(0.060, 0.035, 0.014, name=f"CheekMesh.{label}")
            cheek = transform(
                cheek,
                translate=(side * 0.188, -0.005, 0.243),
                rotate=(0, side * 0.22, -side * 0.08),
            )
            self.add(cheek, f"Cheek.{label}", "cheek", parent="DragonHead")

        nostril_template = superquadric(
            (0.017, 0.010, 0.007),
            vertical_exponent=0.75,
            radial_exponent=0.80,
            rings=12,
            sections=18,
            name="NostrilTemplate",
        )
        nostrils = [
            ((side * 0.048, -0.008, 0.321), (0, 0, 0), (1, 1, 1))
            for side in (-1.0, 1.0)
        ]
        self.add(
            batch(nostril_template, nostrils, name="NostrilsMesh"),
            "Nostrils",
            "pupil",
            parent="DragonHead",
        )

        mouth = loft_z(
            [
                (0.276, 0, -0.075, 0.13, 0.024),
                (0.323, 0, -0.078, 0.105, 0.018),
            ],
            sections=18,
            exponent=4.0,
            name="MouthInteriorMesh",
        )
        self.add(mouth, "MouthInterior", "mouth", parent="DragonHead")

        self.empty("Jaw", parent="DragonHead", translation=(0, -0.055, 0.145))
        jaw = loft_z(
            [
                (0.00, 0, -0.010, 0.155, 0.052),
                (0.11, 0, -0.030, 0.145, 0.047),
                (0.18, 0, -0.036, 0.112, 0.038),
            ],
            sections=22,
            exponent=4.0,
            name="JawMesh",
        )
        self.add(jaw, "JawShell", "skin", parent="Jaw")

        tongue = loft_z(
            [
                (0.075, 0, -0.015, 0.065, 0.017),
                (0.165, 0, -0.020, 0.048, 0.014),
            ],
            sections=16,
            exponent=3.0,
            name="TongueMesh",
        )
        self.add(tongue, "Tongue", "tongue", parent="Jaw")

        smile_points = [
            (-0.105, -0.045, 0.328),
            (-0.065, -0.070, 0.333),
            (0.0, -0.082, 0.336),
            (0.065, -0.070, 0.333),
            (0.105, -0.045, 0.328),
        ]
        smile = tube(
            smile_points,
            [0.006] * len(smile_points),
            sections=10,
            samples_per_segment=4,
            flatten=0.55,
            name="SmileMesh",
        )
        self.add(smile, "Smile", "mouth", parent="DragonHead")

        for side, label in ((-1.0, "L"), (1.0, "R")):
            horn = tube(
                [
                    (side * 0.17, 0.26, -0.06),
                    (side * 0.215, 0.34, -0.105),
                    (side * 0.205, 0.43, -0.155),
                    (side * 0.175, 0.49, -0.19),
                ],
                [0.036, 0.029, 0.017, 0.0015],
                sections=14,
                samples_per_segment=5,
                name=f"HornMesh.{label}",
            )
            self.add(horn, f"Horn.{label}", "gold", parent="DragonHead")

            ear_outer = fin(0.13, 0.21, 0.034, name=f"EarOuterMesh.{label}")
            ear_outer = transform(
                ear_outer,
                translate=(side * 0.245, 0.14, -0.06),
                rotate=(-0.22, side * 0.20, -side * 0.82),
            )
            self.add(ear_outer, f"EarOuter.{label}", "skin_light", parent="DragonHead")
            ear_inner = fin(0.075, 0.145, 0.038, name=f"EarInnerMesh.{label}")
            ear_inner = transform(
                ear_inner,
                translate=(side * 0.245, 0.145, -0.047),
                rotate=(-0.22, side * 0.20, -side * 0.82),
            )
            self.add(ear_inner, f"EarInner.{label}", "red", parent="DragonHead")

        crest_template = fin(0.12, 0.30, 0.060, name="CrownFinTemplate")
        crest_placements = [
            ((0, 0.29, 0.10), (0.20, 0, 0), (0.72, 0.78, 1)),
            ((0, 0.31, 0.025), (0.02, 0, 0), (0.86, 1.00, 1)),
            ((0, 0.29, -0.055), (-0.18, 0, 0), (0.78, 0.94, 1)),
            ((0, 0.25, -0.125), (-0.36, 0, 0), (0.68, 0.80, 1)),
        ]
        self.add(
            batch(crest_template, crest_placements, name="CrownCrestMesh"),
            "CrownCrest",
            "red_bright",
            parent="DragonHead",
        )

    def build_limbs(self) -> None:
        for side, label in ((-1.0, "L"), (1.0, "R")):
            leg = tube(
                [
                    (side * 0.17, 0.49, -0.015),
                    (side * 0.285, 0.35, 0.025),
                    (side * 0.345, 0.23, 0.115),
                    (side * 0.315, 0.15, 0.19),
                ],
                [0.115, 0.108, 0.088, 0.068],
                sections=18,
                samples_per_segment=6,
                flatten=0.88,
                name=f"LegMesh.{label}",
            )
            self.add(leg, f"Leg.{label}", "skin")

            knee_armour = scale_plate(
                0.14, 0.15, 0.034, name=f"KneeArmourMesh.{label}")
            knee_armour = transform(
                knee_armour,
                translate=(side * 0.34, 0.27, 0.165),
                rotate=(-0.28, side * 0.34, -side * 0.08),
            )
            self.add(knee_armour, f"KneeArmour.{label}", "skin_light")

            paw = loft_z(
                [
                    (-0.03, 0, 0.0, 0.095, 0.070),
                    (0.10, 0, -0.010, 0.115, 0.060),
                    (0.245, 0, -0.018, 0.135, 0.048),
                ],
                sections=22,
                exponent=4.2,
                name=f"PawMesh.{label}",
            )
            paw = transform(paw, translate=(side * 0.315, 0.105, 0.105))
            self.add(paw, f"Paw.{label}", "skin_light")

            paw_armour = scale_plate(0.16, 0.105, 0.025, name=f"PawArmourMesh.{label}")
            paw_armour = transform(
                paw_armour,
                translate=(side * 0.315, 0.155, 0.330),
                rotate=(-0.62, 0, 0),
            )
            self.add(paw_armour, f"PawArmour.{label}", "skin")

            for toe in range(3):
                x = side * 0.315 + (toe - 1) * 0.052
                claw = tube(
                    [(x, 0.115, 0.33), (x, 0.105, 0.382), (x, 0.095, 0.405)],
                    [0.018, 0.012, 0.0015],
                    sections=12,
                    samples_per_segment=4,
                    name=f"ToeClawMesh.{label}.{toe}",
                )
                self.add(claw, f"ToeClaw.{label}.{toe}", "gold")

            arm = tube(
                [
                    (side * 0.22, 0.87, 0.07),
                    (side * 0.30, 0.69, 0.15),
                    (side * 0.22, 0.56, 0.275),
                    (side * 0.115, 0.51, 0.31),
                ],
                [0.065, 0.058, 0.047, 0.040],
                sections=16,
                samples_per_segment=5,
                flatten=0.88,
                name=f"ArmMesh.{label}",
            )
            self.add(arm, f"Arm.{label}", "skin")

            forearm_armour = scale_plate(
                0.09, 0.125, 0.028, name=f"ForearmArmourMesh.{label}")
            forearm_armour = transform(
                forearm_armour,
                translate=(side * 0.245, 0.625, 0.235),
                rotate=(-0.18, side * 0.40, -side * 0.28),
            )
            self.add(forearm_armour, f"ForearmArmour.{label}", "skin_light")

            hand = loft_z(
                [
                    (-0.025, 0, 0, 0.066, 0.046),
                    (0.070, 0, -0.004, 0.072, 0.040),
                    (0.13, 0, -0.010, 0.060, 0.034),
                ],
                sections=18,
                exponent=3.8,
                name=f"HandMesh.{label}",
            )
            hand = transform(hand, translate=(side * 0.105, 0.50, 0.29))
            self.add(hand, f"Hand.{label}", "skin_light")

            for finger in range(3):
                x = side * 0.105 + (finger - 1) * 0.032
                claw = tube(
                    [(x, 0.49, 0.405), (x, 0.486, 0.438)],
                    [0.010, 0.001],
                    sections=10,
                    samples_per_segment=4,
                    name=f"FingerClawMesh.{label}.{finger}",
                )
                self.add(claw, f"FingerClaw.{label}.{finger}", "gold")

            limb_scale = scale_plate(
                0.050, 0.060, 0.014, name=f"LimbScaleTemplate.{label}")
            limb_scales = []
            leg_rows = [
                (side * 0.235, 0.405, 0.105),
                (side * 0.278, 0.350, 0.135),
                (side * 0.315, 0.300, 0.155),
            ]
            arm_rows = [
                (side * 0.235, 0.790, 0.125),
                (side * 0.270, 0.730, 0.165),
                (side * 0.275, 0.675, 0.205),
            ]
            for index, position in enumerate(leg_rows + arm_rows):
                limb_scales.append(
                    (
                        position,
                        (-0.12, side * (0.28 + index * 0.025), -side * 0.05),
                        (1, 1, 1),
                    )
                )
            self.add(
                batch(limb_scale, limb_scales, name=f"LimbScaleFieldMesh.{label}"),
                f"LimbScaleField.{label}",
                "skin_light",
            )

    def build_wings(self) -> None:
        for side, label in ((-1.0, "L"), (1.0, "R")):
            group = f"Wing.{label}"
            self.empty(group, translation=(side * 0.16, 0.94, -0.075))
            membrane = wing_membrane(side, name=f"WingMembraneMesh.{label}")
            self.add(membrane, f"WingMembrane.{label}", "red", parent=group)

            orange_panel_points = np.array(
                [
                    [0.15 * side, 0.16, -0.007],
                    [0.34 * side, 0.37, -0.015],
                    [0.39 * side, 0.17, 0.003],
                    [0.42 * side, -0.02, 0.018],
                ]
            )
            panel_faces = np.array([[0, 1, 2], [0, 2, 3]])
            for index, face in enumerate(panel_faces):
                a, b, c = (orange_panel_points[vertex] for vertex in face)
                if np.cross(b - a, c - a)[2] < 0:
                    panel_faces[index] = face[::-1]
            panel = clean(
                trimesh.Trimesh(
                    vertices=orange_panel_points,
                    faces=np.vstack((panel_faces, panel_faces[:, ::-1])),
                    process=False,
                ),
                f"WingEdgePanelMesh.{label}",
            )
            self.add(panel, f"WingEdgePanel.{label}", "orange", parent=group)

            roots = [
                [(0, 0, 0.018), (0.15 * side, 0.16, 0.005), (0.34 * side, 0.37, -0.010)],
                [(0, 0, 0.020), (0.22 * side, 0.10, 0.012), (0.39 * side, 0.17, 0.006)],
                [(0, 0, 0.022), (0.26 * side, 0.02, 0.019), (0.42 * side, -0.02, 0.021)],
                [(0, 0, 0.024), (0.20 * side, -0.08, 0.024), (0.31 * side, -0.17, 0.024)],
            ]
            bone_meshes = []
            for index, points in enumerate(roots):
                bone_meshes.append(
                    tube(
                        points,
                        [0.018, 0.013, 0.007],
                        sections=12,
                        samples_per_segment=5,
                        name=f"WingBoneMesh.{label}.{index}",
                    )
                )
            self.add(
                clean(trimesh.util.concatenate(bone_meshes), f"WingBonesMesh.{label}"),
                f"WingBones.{label}",
                "skin_deep",
                parent=group,
            )

    def build_tail(self) -> None:
        controls = [
            (0.09, 0.34, -0.13),
            (0.30, 0.26, -0.15),
            (0.50, 0.18, -0.01),
            (0.58, 0.14, 0.20),
            (0.55, 0.15, 0.43),
            (0.44, 0.21, 0.61),
        ]
        tail = tube(
            controls,
            [0.115, 0.10, 0.078, 0.058, 0.038, 0.018],
            sections=18,
            samples_per_segment=7,
            flatten=0.90,
            name="TailMesh",
        )
        self.add(tail, "Tail", "skin")

        ridge_controls = [
            (x, y + radius * 0.58, z + radius * 0.12)
            for (x, y, z), radius in zip(
                controls, [0.115, 0.10, 0.078, 0.058, 0.038, 0.018]
            )
        ]
        tail_ridge = tube(
            ridge_controls,
            [0.025, 0.022, 0.018, 0.014, 0.010, 0.004],
            sections=12,
            samples_per_segment=6,
            flatten=0.70,
            name="TailRidgeMesh",
        )
        self.add(tail_ridge, "TailRidge", "red")

        tail_fin_template = fin(0.050, 0.085, 0.025, name="TailFinTemplate")
        fin_placements = [
            ((0.30, 0.31, -0.16), (-0.10, 0, -0.45), (1, 1, 1)),
            ((0.42, 0.25, -0.09), (-0.05, 0, -0.70), (0.90, 0.90, 0.90)),
            ((0.53, 0.21, 0.05), (0.0, 0, -0.90), (0.80, 0.80, 0.80)),
            ((0.57, 0.20, 0.22), (0.10, 0, -1.20), (0.70, 0.70, 0.70)),
        ]
        self.add(
            batch(tail_fin_template, fin_placements, name="TailFinsMesh"),
            "TailFins",
            "red",
        )

        tip = np.array(controls[-1])
        self.empty("TailFlame", translation=tip)
        flame_shell = loft_y(
            [
                (0.00, 0, 0, 0.045, 0.034),
                (0.045, -0.008, 0, 0.052, 0.038),
                (0.11, 0.005, 0, 0.035, 0.026),
                (0.19, -0.012, 0, 0.020, 0.015),
                (0.26, 0.012, 0, 0.001, 0.001),
            ],
            sections=16,
            exponent=2.2,
            name="FlameShellMesh",
        )
        flame_shell = transform(flame_shell, rotate=(0.08, 0, -0.26))
        self.add(flame_shell, "FlameShell", "flame", parent="TailFlame")

        flame_core = loft_y(
            [
                (0.00, 0, 0.015, 0.023, 0.018),
                (0.05, 0.004, 0.015, 0.027, 0.020),
                (0.11, -0.003, 0.015, 0.014, 0.011),
                (0.16, 0.006, 0.015, 0.001, 0.001),
            ],
            sections=14,
            exponent=2.0,
            name="FlameCoreMesh",
        )
        flame_core = transform(flame_core, rotate=(0.08, 0, -0.20))
        self.add(flame_core, "FlameCore", "flame_core", parent="TailFlame")

    def export(self, output: Path) -> None:
        output.parent.mkdir(parents=True, exist_ok=True)
        glb = trimesh.exchange.gltf.export_glb(
            self.scene, include_normals=True, unitize_normals=True)
        output.write_bytes(glb)
        triangles = sum(len(mesh.faces) for mesh in self.scene.geometry.values())
        vertices = sum(len(mesh.vertices) for mesh in self.scene.geometry.values())
        print(
            f"Wrote {output} ({len(glb) / 1024:.1f} KiB, "
            f"{vertices:,} vertices, {triangles:,} triangles, "
            f"{len(self.scene.geometry)} mesh parts)"
        )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "output",
        nargs="?",
        type=Path,
        default=Path("App/Resources/AitvarasDragon.glb"),
    )
    args = parser.parse_args()

    builder = DragonBuilder()
    builder.build_body()
    builder.build_head()
    builder.build_limbs()
    builder.build_wings()
    builder.build_tail()
    builder.export(args.output)


if __name__ == "__main__":
    main()
