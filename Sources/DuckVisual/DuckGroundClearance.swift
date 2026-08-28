import Foundation
import DuckKit

/// How far the robot is off the ground, as drawn.
///
/// WHY A RENDERER SHOULD BE ABLE TO ANSWER THIS. Duck Studio shipped a build in
/// which every recorded motion played with the robot floating 116 mm above the
/// floor, and it took a person looking at a screenshot to notice. The bug was
/// invisible to the tests because they all asked about POSES, and a pose is
/// correct in whichever frame you assume. The question nobody could ask in code
/// was the one the eye asks immediately: is it standing on the floor?
///
/// So this answers it, cheaply enough to run every frame. A stage that prints
/// the number cannot ship that bug again, because the number would have read
/// +116 mm on a robot that was supposed to be standing.
///
/// SAMPLED, AND THE ERROR IS MEASURED RATHER THAN ASSUMED. The robot is 45,348
/// vertices and transforming all of them at 50 Hz is not free, so this keeps a
/// fixed subset per body. Which subset matters: a uniform stride can miss the
/// one vertex at the bottom of a foot, so the sample is a stride UNION the
/// vertices that are already extreme in the body's own frame — the ones that
/// can become the lowest under some rotation. `DuckGroundClearanceTests`
/// compares this against the exact minimum over every vertex of every frame in
/// the corpus and asserts the gap.
public struct DuckGroundClearance: Sendable {

    /// One body's contact candidates, in its own frame.
    private struct Sample: Sendable {
        let name: String
        let points: [DuckVector]
    }

    private let samples: [Sample]

    /// How many uniformly-spaced points to keep per body, before the support
    /// points are added.
    public static let strideTarget = 400

    /// How many extreme vertices to keep per direction.
    public static let supportPerDirection = 16

    /// The directions to take support points in.
    ///
    /// TWENTY-SIX, NOT SIX, AND THE REASON IS THE ROTATION. The lowest point of
    /// a rotated body is its support point in whatever direction world-down
    /// maps to, and world-down is an arbitrary direction in the body's frame
    /// once the robot rolls. Six axis directions leave the corners uncovered:
    /// with only those, `climb` came out 3.1 mm high, and even at a much denser
    /// stride it was still 1.65 mm — a visible error on a number whose job is
    /// to say "on the floor". These are the axes, the edge diagonals and the
    /// corner diagonals of a cube, which is the cheapest set that covers the
    /// sphere reasonably evenly.
    static let directions: [DuckVector] = {
        var out: [DuckVector] = []
        for x in [-1.0, 0, 1.0] {
            for y in [-1.0, 0, 1.0] {
                for z in [-1.0, 0, 1.0] {
                    guard x != 0 || y != 0 || z != 0 else { continue }
                    out.append(DuckVector(x, y, z))
                }
            }
        }
        return out
    }()

    public init(bodies: [DuckMesh.Body]) {
        samples = bodies.map { body in
            var chosen = Set<Int>()
            let count = body.vertexCount
            guard count > 0 else { return Sample(name: body.name, points: []) }

            let step = max(count / Self.strideTarget, 1)
            for index in Swift.stride(from: 0, to: count, by: step) { chosen.insert(index) }

            // The support points in each direction, found by one linear pass
            // each rather than by sorting the whole body twenty-six times.
            for direction in Self.directions {
                var best: [(index: Int, score: Double)] = []
                best.reserveCapacity(Self.supportPerDirection + 1)
                for index in 0..<count {
                    let score = Double(body.positions[index * 3]) * direction.x
                              + Double(body.positions[index * 3 + 1]) * direction.y
                              + Double(body.positions[index * 3 + 2]) * direction.z
                    if best.count < Self.supportPerDirection {
                        best.append((index, score))
                        if best.count == Self.supportPerDirection {
                            best.sort { $0.score > $1.score }
                        }
                        continue
                    }
                    guard score > best[best.count - 1].score else { continue }
                    best[best.count - 1] = (index, score)
                    var at = best.count - 1
                    while at > 0, best[at].score > best[at - 1].score {
                        best.swapAt(at, at - 1)
                        at -= 1
                    }
                }
                for candidate in best { chosen.insert(candidate.index) }
            }

            let points = chosen.sorted().map { index in
                DuckVector(Double(body.positions[index * 3]),
                           Double(body.positions[index * 3 + 1]),
                           Double(body.positions[index * 3 + 2]))
            }
            return Sample(name: body.name, points: points)
        }
    }

    /// Load once. Decoding the meshes is a few megabytes and choosing the
    /// samples sorts every body three times; neither belongs on a frame.
    public static func bundled() throws -> DuckGroundClearance {
        DuckGroundClearance(bodies: try DuckMesh.bundled())
    }

    /// The height of the robot's lowest drawn point above z = 0, in metres,
    /// with the trunk placed on `root`.
    ///
    /// Positive means floating. Negative is normal and can be tens of
    /// millimetres, for a reason worth stating exactly because a first draft of
    /// this comment got it wrong twice.
    ///
    /// It is NOT that MuJoCo contacts simplified primitives inside these
    /// shells. Every one of the model's eleven collision geoms is a MESH, at
    /// the same pose as the visual sole it shadows — the footpads differ by
    /// about half a millimetre, inside the mesh exporter's own clustering. The
    /// real cause is that SEVEN OF THE FIFTEEN DRAWN BODIES CARRY NO COLLISION
    /// GEOMETRY AT ALL: `yaw2roll`, both upper legs, `neck`, `neck_pitch`,
    /// `yaw_roll_motion` and `bearing_roll`. Those parts are drawn and cannot
    /// touch anything, so a duck on its side rests on the shells that do
    /// collide while a thigh or the neck passes straight through the floor.
    /// Measured: the drawn shell reaches −33.5 mm on `step_up` where MuJoCo's
    /// own contact is at −2.7 mm.
    ///
    /// So this reports WHERE THE DRAWN DUCK IS, which is the question a
    /// renderer has to answer, and it is not a contact depth. Anything driven
    /// off it — a shadow, say — should clamp at zero and expect a 30 mm swing.
    public func clearance(jointAngles: [Double], root: DuckIntentClip.Root) -> Double {
        let quaternion = DuckQuaternion(w: root.quaternion.0, x: root.quaternion.1,
                                        y: root.quaternion.2, z: root.quaternion.3)
        let placement = DuckKinematics.placement(
            forRoot: DuckVector(root.x, root.y, root.z), orientation: quaternion)
        let poses = DuckKinematics.bodyPoses(jointAngles: jointAngles)

        var lowest = Double.greatestFiniteMagnitude
        for sample in samples {
            guard let pose = poses[sample.name] else { continue }
            for local in sample.points {
                let inModel = pose.position + pose.orientation.rotate(local)
                let world = placement.position + placement.orientation.rotate(inModel)
                lowest = Swift.min(lowest, world.z)
            }
        }
        return lowest == .greatestFiniteMagnitude ? 0 : lowest
    }

    /// The sentence to put on screen beside the number.
    ///
    /// A bare "+116 mm" invites the reader to assume the robot is meant to be
    /// up there. Saying what zero means is what makes the number a check.
    ///
    /// ONLY FLOATING IS A PROBLEM. Dipping below the floor is expected — seven
    /// of the fifteen drawn bodies have no collision geometry, so a duck lying
    /// down rests on the parts that collide while a thigh or the neck passes
    /// through — and colouring it as a fault taught the reader that a correct
    /// render was broken. The first version of this string also blamed
    /// "simplified collision shapes", which was wrong: every collision geom in
    /// the model is a mesh sitting on its visual counterpart.
    public static func summary(clearanceMetres: Double) -> String {
        let mm = clearanceMetres * 1000
        if mm > 5 {
            return String(format: "%.0f mm off the ground — nothing should be floating.", mm)
        }
        if mm < -5 {
            return String(format: "%.0f mm through the floor, which is normal here: seven of the "
                        + "fifteen drawn parts have no collision shape, so they are drawn and "
                        + "cannot touch anything.", -mm)
        }
        return String(format: "%+.0f mm — on the floor.", mm)
    }

    /// Whether the number is reporting something WRONG, as opposed to merely
    /// not zero. Floating is wrong; sinking is the meshes.
    public static func isWrong(clearanceMetres: Double) -> Bool {
        clearanceMetres > 0.005
    }
}
