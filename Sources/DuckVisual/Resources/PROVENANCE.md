# duck-mesh.bin

Built by `tools/export_duck_mesh.py` from **pollen-robotics/microduck_rl**,
`src/mjlab_microduck/robot/microduck/` — `robot_allcollisions.xml` and its 38
STL assets. That repository is **Apache-2.0**, the same licence as this one.

The visually identical meshes in the `pollen-robotics/microduck-simulator`
Hugging Face Space are NOT the source, deliberately. That Space declares no
licence; its files are usable by permission granted to this project's operator
and are not redistributable inside a binary that goes to other people. The two
sets are not byte-identical, so this is a real substitution rather than a
relabelling of the same bytes.

The robot, its design, its meshes and its trained policies are Pollen Robotics'
work. This file only rearranges their geometry into a form an app can draw.

796,792 triangles in, 107,194 out — vertex-clustered at 1.2 mm, which holds the
silhouette of a 250 mm robot while dropping the interior CAD detail (screw
threads, PCB vias) that nothing can see at the distance a phone is held from a
duck.

## The jaw

Upstream fuses the lower beak into the head body — Pollen's own bake script
calls `mouth` "a servo without an MJCF joint (the jaw is a fixed geom)". Here
the two beak parts (`jaw.stl`, `jaw_soft.stl`) are split out as a `jaw` body
baked about the hinge that `DuckKinematics` derives from the mouth servo's
placement in that same file. The geometry is unchanged; only which body owns
it and the frame it is expressed in.

## duck-mesh-rollers.bin

The six bodies that differ when the robot wears Pollen's roller blades —
`ankle_l_v1`, `ankle_r_v1` and four `tire` bodies — from
`robot_allcollisions_rollers.xml` and its assets in the same repository,
baked in their own frames. Overlaid on the walker's file by
`DuckMesh.bundled(variant: .rollers)`.

Both files built from `microduck_rl` `develop` @ d424a0c (2026-08-29).
