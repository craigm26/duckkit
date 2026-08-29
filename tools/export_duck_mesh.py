#!/usr/bin/env python3
"""Build `duck-mesh.bin` — the Microduck's real shape, posable by DuckKinematics.

WHAT THIS SOLVES. `DuckKinematics` knows where every body is; it does not know
what any of them look like, because the MJCF it was generated from carries mass
and kinematics and no geometry at all. So the AR ghost was a stick figure of
spheres and bones — recognisably articulated, not recognisably a duck.

WHERE THE GEOMETRY COMES FROM, AND WHY THAT MATTERS. The meshes are the STLs in
`pollen-robotics/microduck_rl`, which is **Apache-2.0**. That is the whole
reason to use them rather than the visually identical set in the
`microduck-simulator` Hugging Face Space: the Space declares no licence, so
those files are usable by personal permission and NOT redistributable inside an
App Store binary. The two sets are not byte-identical (checked), so this is a
real substitution, not a relabelling.

THE TWO MODEL REVISIONS DO NOT AGREE, AND THAT IS HANDLED HERE. DuckKit's
kinematics come from the `robot_walk.xml` vendored in its fixtures; the meshes
come from `robot_allcollisions.xml` upstream. Both describe 15 bodies in the
same tree order, but three are renamed (`upper_leg_left` → `left_upper_leg`,
`upper_leg_right` → `right_upper_leg`, `jaw_soft` → `bottom_head_shell`) and one,
`ankle_right`, carries a genuinely different rotation — not a q/−q spelling of
the same one. Baking meshes against the wrong body frame puts the robot's right
foot on backwards, which is the kind of error that looks like a rendering bug
forever. So this computes a per-body correction from the two files and bakes it
in: where the revisions agree it is the identity, and where they do not it is
exactly the rotation that reconciles them.

Bodies are matched by TREE INDEX rather than by name, because the names are the
thing that changed.

Usage:  python3 tools/export_duck_mesh.py <model-dir> <output.bin>
    where <model-dir> holds robot_allcollisions.xml and assets/*.stl from
    pollen-robotics/microduck_rl.
"""
from __future__ import annotations

import json
import math
import os
import re
import struct
import sys

# Vertex clustering cell, metres. The robot is 250 mm tall, so 1.2 mm holds the
# silhouette — which is all a 25 cm object seen through a phone can show — while
# collapsing the interior detail that dominates a CAD export. 421,832 triangles
# of screw threads and PCB vias are not visible at any distance a person holds a
# phone from a duck.
CELL = 0.0012

KIT_MJCF = "Tests/DuckKitTests/Fixtures/duck/robot_walk.xml"

# The lower beak: the two parts that swing on the mouth servo. Hinge and
# orientation are DuckKinematics' `jaw` body, verbatim.
JAW_MESHES = {"jaw", "jaw_soft"}
JAW_HINGE = (0.003, 0.040, -0.018)
JAW_QUAT = (0.7071067811865476, -0.7071067811865476, 0.0, 0.0)

# The rollers overlay: the six bodies that differ, baked in their own frames
# straight from robot_allcollisions_rollers.xml — the kit's roller table is
# read from that same file, so no correction is needed.
ROLLER_BODIES = ["ankle_l_v1", "tire", "tire_2", "ankle_r_v1", "tire_3", "tire_4"]


def export_rollers(model_dir: str, out_path: str) -> int:
    upstream = open(os.path.join(model_dir, "robot_allcollisions_rollers.xml")).read()
    bodies = parse_bodies(upstream)
    materials = parse_materials(upstream)
    mesh_files = parse_mesh_files(upstream)
    buckets = visual_geoms_by_body(upstream, bodies)
    entries, positions_blob, normals_blob, index_blob = [], bytearray(), bytearray(), bytearray()
    for name in ROLLER_BODIES:
        triangles, colour = [], (0.8, 0.8, 0.8, 1.0)
        for geom in buckets.get(name, []):
            filename = mesh_files.get(geom["mesh"])
            if not filename:
                continue
            raw = read_stl(os.path.join(model_dir, "assets", filename))
            gq, gp = geom["quat"], geom["pos"]
            for tri in raw:
                triangles.append(tuple(
                    (lambda r: (r[0] + gp[0], r[1] + gp[1], r[2] + gp[2]))(q_rotate(gq, v))
                    for v in tri))
            if geom["material"] in materials:
                colour = materials[geom["material"]]
        if not triangles:
            print(f"  no visual geometry for {name}")
            return 1
        positions, faces = cluster(triangles)
        normals = normals_for(positions, faces)
        entries.append({
            "body": name,
            "vertexOffset": len(positions_blob) // 12, "vertexCount": len(positions),
            "indexOffset": len(index_blob) // 4, "indexCount": len(faces) * 3,
            "rgba": [round(c, 4) for c in colour],
        })
        for p in positions:
            positions_blob += struct.pack("<3f", *p)
        for n in normals:
            normals_blob += struct.pack("<3f", *n)
        for f in faces:
            index_blob += struct.pack("<3I", *f)
    header = json.dumps({
        "format": "duck-mesh-v1",
        "source": "pollen-robotics/microduck_rl (Apache-2.0), robot_allcollisions_rollers.xml + assets/*.stl",
        "cell": CELL, "bodies": entries,
    }, separators=(",", ":")).encode()
    header += b" " * ((-(len(header) + 8)) % 4)
    with open(out_path, "wb") as handle:
        handle.write(b"DKM1"); handle.write(struct.pack("<I", len(header)))
        handle.write(header); handle.write(positions_blob); handle.write(normals_blob)
        handle.write(index_blob)
    print(f"rollers: {len(entries)} bodies, {len(index_blob) // 12} triangles -> {out_path}")
    return 0


# ── quaternions (w, x, y, z) ──────────────────────────────────────────────

def q_mul(a, b):
    aw, ax, ay, az = a
    bw, bx, by, bz = b
    return (aw*bw - ax*bx - ay*by - az*bz,
            aw*bx + ax*bw + ay*bz - az*by,
            aw*by - ax*bz + ay*bw + az*bx,
            aw*bz + ax*by - ay*bx + az*bw)


def q_conj(q):
    return (q[0], -q[1], -q[2], -q[3])


def q_rotate(q, v):
    w, x, y, z = q
    vx, vy, vz = v
    # t = 2 * (q_vec x v); v' = v + w*t + q_vec x t
    tx = 2 * (y*vz - z*vy)
    ty = 2 * (z*vx - x*vz)
    tz = 2 * (x*vy - y*vx)
    return (vx + w*tx + (y*tz - z*ty),
            vy + w*ty + (z*tx - x*tz),
            vz + w*tz + (x*ty - y*tx))


def q_norm(q):
    n = math.sqrt(sum(c*c for c in q)) or 1.0
    return tuple(c / n for c in q)


# ── MJCF ──────────────────────────────────────────────────────────────────

def parse_attrs(text: str) -> dict:
    return dict(re.findall(r'(\w+)\s*=\s*"([^"]*)"', text))


def numbers(text: str, count: int, default):
    if not text:
        return default
    parts = [float(p) for p in text.split()]
    return tuple(parts[:count]) if len(parts) >= count else default


def parse_bodies(xml: str):
    """Bodies in document (tree) order, with their local pos and quat."""
    out = []
    for match in re.finditer(r'<body\b([^>]*)>', xml):
        a = parse_attrs(match.group(1))
        if "name" not in a:
            continue
        out.append({
            "name": a["name"],
            "pos": numbers(a.get("pos"), 3, (0.0, 0.0, 0.0)),
            "quat": q_norm(numbers(a.get("quat"), 4, (1.0, 0.0, 0.0, 0.0))),
            "start": match.end(),
        })
    return out


def visual_geoms_by_body(xml: str, bodies):
    """Assign each visual geom to the body whose element most recently opened.

    Cheap and correct for this file: MJCF nests bodies, and a geom belongs to
    the innermost body opened before it, which is the last `start` less than
    the geom's own offset.
    """
    buckets = {b["name"]: [] for b in bodies}
    starts = [(b["start"], b["name"]) for b in bodies]
    for match in re.finditer(r'<geom\b([^>]*)/?>', xml):
        a = parse_attrs(match.group(1))
        if a.get("class") != "visual" or "mesh" not in a:
            continue
        owner = None
        for start, name in starts:
            if start <= match.start():
                owner = name
            else:
                break
        if owner is None:
            continue
        buckets[owner].append({
            "mesh": a["mesh"],
            "pos": numbers(a.get("pos"), 3, (0.0, 0.0, 0.0)),
            "quat": q_norm(numbers(a.get("quat"), 4, (1.0, 0.0, 0.0, 0.0))),
            "material": a.get("material"),
        })
    return buckets


def parse_materials(xml: str):
    out = {}
    for match in re.finditer(r'<material\b([^>]*)/?>', xml):
        a = parse_attrs(match.group(1))
        if "name" in a:
            out[a["name"]] = numbers(a.get("rgba"), 4, (0.8, 0.8, 0.8, 1.0))
    return out


def parse_mesh_files(xml: str):
    """Mesh name to filename.

    MuJoCo lets `<mesh file="foot_left.stl"/>` go unnamed and derives the asset
    name from the filename STEM, which is what the geoms then reference as
    `mesh="foot_left"`. Keying by the full filename finds nothing and reports an
    empty model rather than an error.
    """
    out = {}
    for match in re.finditer(r'<mesh\b([^>]*)/?>', xml):
        a = parse_attrs(match.group(1))
        if "file" not in a:
            continue
        stem = a["file"].rsplit(".", 1)[0]
        out[a.get("name", stem)] = a["file"]
    return out


# ── STL ───────────────────────────────────────────────────────────────────

def read_stl(path):
    """Binary STL to a flat list of triangles [(v0, v1, v2), ...]."""
    with open(path, "rb") as handle:
        handle.seek(80)
        count = struct.unpack("<I", handle.read(4))[0]
        data = handle.read(count * 50)
    triangles = []
    for i in range(count):
        base = i * 50 + 12          # skip the per-facet normal; we recompute
        vals = struct.unpack_from("<9f", data, base)
        triangles.append((vals[0:3], vals[3:6], vals[6:9]))
    return triangles


# ── decimation ────────────────────────────────────────────────────────────

def cluster(triangles, cell=CELL):
    """Vertex clustering: snap to a grid, weld, drop degenerates.

    Chosen over quadric-error decimation because it is twenty lines, has no
    failure mode worse than a slightly faceted silhouette, and the target is a
    25 cm object on a phone screen. Quadric decimation would preserve sharp
    edges better and is not worth a mesh library in this pipeline.
    """
    index = {}
    positions = []
    faces = []
    for tri in triangles:
        ids = []
        for v in tri:
            key = (round(v[0] / cell), round(v[1] / cell), round(v[2] / cell))
            got = index.get(key)
            if got is None:
                got = len(positions)
                index[key] = got
                positions.append((key[0] * cell, key[1] * cell, key[2] * cell))
            ids.append(got)
        if ids[0] != ids[1] and ids[1] != ids[2] and ids[0] != ids[2]:
            faces.append(tuple(ids))

    # DROP THE ORPHANS. Collapsing a cluster can leave a vertex every one of
    # whose triangles degenerated, so it survives in the buffer with no face
    # touching it. Its accumulated normal is then exactly (0, 0, 0) — not a
    # short normal, a zero one — and a renderer lights that vertex as if it
    # faced nowhere. Compacting also shrinks the file, since these are pure
    # waste.
    used = sorted({i for face in faces for i in face})
    remap = {old: new for new, old in enumerate(used)}
    positions = [positions[i] for i in used]
    faces = [tuple(remap[i] for i in face) for face in faces]
    return positions, faces


def normals_for(positions, faces):
    """Area-weighted vertex normals, with a fallback that matters.

    A vertex whose adjacent faces point in exactly opposite directions sums to
    (0, 0, 0) — not a short normal, a zero one. Clustering creates these
    routinely by welding a thin feature into a back-to-back pair of triangles.
    Normalising that gives (0, 0, 0) again, and a renderer lights the vertex as
    though it faced nowhere: a black speck that looks like a texture bug. So
    each vertex also remembers one adjacent face normal, and falls back to it.
    """
    acc = [[0.0, 0.0, 0.0] for _ in positions]
    fallback = [None] * len(positions)
    for a, b, c in faces:
        pa, pb, pc = positions[a], positions[b], positions[c]
        ux, uy, uz = pb[0]-pa[0], pb[1]-pa[1], pb[2]-pa[2]
        vx, vy, vz = pc[0]-pa[0], pc[1]-pa[1], pc[2]-pa[2]
        nx, ny, nz = uy*vz - uz*vy, uz*vx - ux*vz, ux*vy - uy*vx
        face_len = math.sqrt(nx*nx + ny*ny + nz*nz)
        for i in (a, b, c):
            acc[i][0] += nx
            acc[i][1] += ny
            acc[i][2] += nz
            if fallback[i] is None and face_len > 0:
                fallback[i] = (nx/face_len, ny/face_len, nz/face_len)
    out = []
    for i, n in enumerate(acc):
        length = math.sqrt(n[0]*n[0] + n[1]*n[1] + n[2]*n[2])
        if length > 1e-12:
            out.append((n[0]/length, n[1]/length, n[2]/length))
        else:
            out.append(fallback[i] or (0.0, 0.0, 1.0))
    return out


# ── main ──────────────────────────────────────────────────────────────────

def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__.strip().splitlines()[-3])
        return 2
    if sys.argv[1] == "--rollers":
        return export_rollers(sys.argv[2], sys.argv[3])
    model_dir, out_path = sys.argv[1], sys.argv[2]
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

    upstream = open(os.path.join(model_dir, "robot_allcollisions.xml")).read()
    kit = open(os.path.join(repo, KIT_MJCF)).read()

    up_bodies = parse_bodies(upstream)
    kit_bodies = parse_bodies(kit)
    if len(up_bodies) != len(kit_bodies):
        print(f"body count differs: {len(up_bodies)} vs {len(kit_bodies)}")
        return 1

    materials = parse_materials(upstream)
    mesh_files = parse_mesh_files(upstream)
    buckets = visual_geoms_by_body(upstream, up_bodies)

    entries = []
    positions_blob = bytearray()
    normals_blob = bytearray()
    index_blob = bytearray()
    total_in = 0

    jaw_triangles = []
    for up, mine in zip(up_bodies, kit_bodies):
        geoms = buckets.get(up["name"], [])
        if not geoms:
            continue

        # The correction that reconciles the two revisions. Identity wherever
        # they agree; a real rotation for ankle_right, where they do not.
        delta = q_mul(q_conj(mine["quat"]), up["quat"])

        triangles = []
        colour = (0.8, 0.8, 0.8, 1.0)
        for geom in geoms:
            # THE JAW SPLIT. Upstream fuses the lower beak into the head body
            # ("a servo without an MJCF joint"); DuckKinematics hinges it on
            # the mouth servo's horn. So the two beak parts are baked in THAT
            # frame — head-frame vertex, minus the hinge, un-rotated by the
            # jaw body's orientation — and emitted as their own body.
            if up["name"] == "jaw_soft" and geom["mesh"] in JAW_MESHES:
                filename = mesh_files.get(geom["mesh"])
                raw = read_stl(os.path.join(model_dir, "assets", filename))
                total_in += len(raw)
                gq, gp = geom["quat"], geom["pos"]
                for tri in raw:
                    moved = []
                    for v in tri:
                        r = q_rotate(gq, v)
                        r = (r[0] + gp[0], r[1] + gp[1], r[2] + gp[2])
                        r = q_rotate(delta, r)
                        r = (r[0] - JAW_HINGE[0], r[1] - JAW_HINGE[1], r[2] - JAW_HINGE[2])
                        moved.append(q_rotate(q_conj(JAW_QUAT), r))
                    jaw_triangles.append(tuple(moved))
                continue
            filename = mesh_files.get(geom["mesh"])
            if not filename:
                continue
            path = os.path.join(model_dir, "assets", filename)
            if not os.path.exists(path):
                print(f"  missing {filename}")
                continue
            raw = read_stl(path)
            total_in += len(raw)
            gq, gp = geom["quat"], geom["pos"]
            for tri in raw:
                moved = []
                for v in tri:
                    r = q_rotate(gq, v)
                    r = (r[0] + gp[0], r[1] + gp[1], r[2] + gp[2])
                    moved.append(q_rotate(delta, r))
                triangles.append(tuple(moved))
            if geom["material"] in materials:
                colour = materials[geom["material"]]

        if not triangles:
            continue
        positions, faces = cluster(triangles)
        normals = normals_for(positions, faces)

        entries.append({
            "body": mine["name"],
            "vertexOffset": len(positions_blob) // 12,
            "vertexCount": len(positions),
            "indexOffset": len(index_blob) // 4,
            "indexCount": len(faces) * 3,
            "rgba": [round(c, 4) for c in colour],
        })
        for p in positions:
            positions_blob += struct.pack("<3f", *p)
        for n in normals:
            normals_blob += struct.pack("<3f", *n)
        for f in faces:
            index_blob += struct.pack("<3I", *f)

        if mine["name"] == "bottom_head_shell" and jaw_triangles:
            positions, faces = cluster(jaw_triangles)
            normals = normals_for(positions, faces)
            entries.append({
                "body": "jaw",
                "vertexOffset": len(positions_blob) // 12,
                "vertexCount": len(positions),
                "indexOffset": len(index_blob) // 4,
                "indexCount": len(faces) * 3,
                "rgba": [round(c, 4) for c in materials["jaw_material"]],
            })
            for p in positions:
                positions_blob += struct.pack("<3f", *p)
            for n in normals:
                normals_blob += struct.pack("<3f", *n)
            for f in faces:
                index_blob += struct.pack("<3I", *f)

    header = json.dumps({
        "format": "duck-mesh-v1",
        "source": "pollen-robotics/microduck_rl (Apache-2.0), robot_allcollisions.xml + assets/*.stl",
        "cell": CELL,
        "bodies": entries,
    }, separators=(",", ":")).encode()
    # Pad so the float arrays start 4-byte aligned: an unaligned Float32 read is
    # a crash on some platforms and silently wrong on others.
    pad = (-(len(header) + 8)) % 4
    header += b" " * pad

    with open(out_path, "wb") as handle:
        handle.write(b"DKM1")
        handle.write(struct.pack("<I", len(header)))
        handle.write(header)
        handle.write(positions_blob)
        handle.write(normals_blob)
        handle.write(index_blob)

    out_tris = sum(e["indexCount"] for e in entries) // 3
    size = os.path.getsize(out_path)
    print(f"{len(entries)} bodies, {total_in:,} triangles in, {out_tris:,} out "
          f"({100*out_tris/max(total_in,1):.1f}%), {size/1e6:.2f} MB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
