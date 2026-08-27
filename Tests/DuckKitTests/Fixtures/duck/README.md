# Microduck fixtures

`alpha_walking.onnx` and `robot_walk.xml` are vendored verbatim from
[pollen-robotics/microduck](https://github.com/pollen-robotics/microduck)
(Apache-2.0). `golden_policies.json` holds observation→action pairs computed by
onnxruntime 1.29.0 against the vendored policy (and `ball_kick_left.onnx`,
which is not vendored — those cases document the contract but only the
walking cases are executable here). `duck_chain.json` is the kinematic tree
extracted mechanically from `robot_walk.xml` — body positions, orientations,
joint axes and ranges, and site placements, unchanged in value.

The point of vendoring the real network rather than a synthetic one: the
Swift forward pass in `DuckPolicy.swift` must reproduce what the robot's own
runtime computes, and only the real weights can prove that.
