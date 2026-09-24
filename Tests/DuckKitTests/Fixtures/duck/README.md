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

`duckbatch_128x128.onnx` is a 26,254-parameter student (61→128→128→14) distilled
from Pollen's `velstand.onnx` by
[craigm26/duckbatch](https://github.com/craigm26/duckbatch) (Apache-2.0), batch
`b002-student-size-longer`, arm `a02`; the same file is published as
[craigm26/microduck-duckbatch-b002-128x128](https://huggingface.co/craigm26/microduck-duckbatch-b002-128x128).
It is here to prove the loader runs a network that is not the alpha shape.
`golden_student.json` holds its onnxruntime 1.30.0 actions on the four
observations of `golden_policies.json`, unchanged. Simulation-trained only; it
has never driven a robot.
